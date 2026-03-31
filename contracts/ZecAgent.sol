// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./lib/Memory.sol";
import "./lib/BytesToTypes.sol";
import "./lib/BitcoinHelper.sol";
import "./lib/SatoshiPlusHelper.sol";
import "./interface/IAgent.sol";
import "./interface/IZecAgent.sol";
import "./interface/ILightClient.sol";
import "./interface/ICandidateHub.sol";
import "./interface/IStakeHub.sol";
import "./interface/IParamSubscriber.sol";
import "./lib/Address.sol";
import "./System.sol";

/// ZecAgent — ZEC staking + orchestration contract (combined BitcoinAgent + BitcoinStake)
/// Uses CLTV locked outputs for staking, same as BitcoinStake.
/// Supports dual staking with Native Token weight multiplier.
contract ZecAgent is IAgent, IZecAgent, System, IParamSubscriber {

  using BitcoinHelper for bytes;
  using BitcoinHelper for bytes29;
  using TypedMemView for bytes;
  using TypedMemView for bytes29;
  using TypedMemView for uint256;

  // ZEC decimal: 1 ZEC = 1e8 zatoshi
  uint256 public constant ZEC_DECIMAL = 1e8;
  uint256 public constant DENOMINATOR = 10000;

  // OP_RETURN magic for ZEC staking
  uint32 public constant ZEC_STAKE_MAGIC = 0x5A45432b; // "ZEC+"

  // Confirmation blocks for ZEC (24 blocks ≈ 30 minutes)
  uint32 public constant ZEC_CONFIRM_BLOCK = 24;

  // Default parameters

  /// @dev ZEC transaction record for staking
  struct ZecTx {
    uint64 amount;           // ZEC amount in zatoshi
    uint32 outputIndex;      // UTXO output index
    uint64 blockTimestamp;   // Zcash block timestamp
    uint32 lockTime;         // CLTV locktime (absolute time)
    uint32 usedHeight;       // Height at which UTXO was spent (0 = unspent)
  }

  /// @dev Deposit receipt linking txid to candidate/delegator
  struct DepositReceipt {
    address candidate;       // Validator candidate
    address delegator;       // Delegator EVM address
    uint256 round;           // Round when deposit was recorded
    uint256 dualStakeAmount; // Native Token amount for dual staking (0 = no dual stake)
    uint256 reward;          // Settled but unclaimed reward (from dualStake multiplier change)
  }

  /// @dev Per-candidate staking state
  struct CandidateState {
    uint256 stakedAmount;    // Snapshotted amount for current round
    uint256 realtimeAmount;  // Current realtime staked amount
    uint256[] continuousRewardEndRounds;
  }

  /// @dev Expiration tracking per round
  struct ExpireInfo {
    address[] candidateList;
    mapping(address => uint256) amountMap;
  }


  // Dual staking weight grades
  struct DualStakingGrade {
    uint256 ratio;        // nativeToken / zecAmount threshold (scaled by 1e18)
    uint256 multiplier;   // weight multiplier (DENOMINATOR = 10000 = 1.0x)
  }

  // Round tag
  uint256 public roundTag;

  // Staking data
  mapping(bytes32 => ZecTx) public zecTxMap;
  mapping(bytes32 => DepositReceipt) public receiptMap;
  mapping(address => bytes32[]) public delegatorTxids;
  mapping(address => CandidateState) public candidateMap;

  // Reward tracking: candidate => round => accrued reward per ZEC
  mapping(address => mapping(uint256 => uint256)) public accruedRewardPerZECMap;

  // Expiration tracking
  mapping(uint256 => ExpireInfo) round2expireInfoMap;

  // Dual staking grades
  DualStakingGrade[] public dualStakingGrades;

  /*********************** events **************************/
  event delegated(bytes32 indexed txid, address indexed candidate, address indexed delegator, bytes script, uint32 outputIndex, uint64 amount);
  event rewardCollected(bytes32 indexed txid, address indexed delegator, uint256 reward, bool expired);
  event claimedReward(address indexed delegator, uint256 amount);
  event dualStaked(bytes32 indexed txid, address indexed delegator, uint256 nativeAmount, uint256 totalDualStakeAmount);

  /*********************** Init **************************/
  function init() external onlyNotInit {
    roundTag = 1;

    // Default dual staking grades (ratio threshold, multiplier)
    dualStakingGrades.push(DualStakingGrade(0, 10000));       // 0: 1.0x base
    dualStakingGrades.push(DualStakingGrade(1e17, 11000));    // 0.1: 1.1x
    dualStakingGrades.push(DualStakingGrade(2e17, 13000));    // 0.2: 1.3x
    dualStakingGrades.push(DualStakingGrade(5e17, 15000));    // 0.5: 1.5x

    alreadyInit = true;
  }

  /*********************** Delegation **************************/

  /// Delegate ZEC to Z Protocol using CLTV locked output
  /// Redeem script format (same as BitcoinStake):
  ///   <abstract locktime> OP_CLTV OP_DROP OP_DUP OP_HASH160 <pubKey Hash> OP_EQUALVERIFY OP_CHECKSIG
  function delegate(
    bytes calldata zecTx,
    uint32 blockHeight,
    bytes32[] memory nodes,
    uint256 index,
    bytes memory script
  ) external override {
    require(script[0] == bytes1(uint8(0x04)) && script[5] == bytes1(uint8(0xb1)), "not a valid redeem script");
    bytes32 txid = zecTx.calculateTxId();
    require(zecTxMap[txid].amount == 0, "already delegated");

    uint32 lockTime = _parseLockTime(script);
    uint64 blockTimestamp;
    {
      bool txChecked;
      (txChecked, blockTimestamp) = ILightClient(ZEC_LIGHT_CLIENT_ADDR)
        .checkTxProofAndGetTime(txid, blockHeight, ZEC_CONFIRM_BLOCK, nodes, index);
      require(txChecked, "zec tx not confirmed");
      uint256 endRound = lockTime / SatoshiPlusHelper.ROUND_INTERVAL;
      require(endRound > roundTag + 1, "insufficient locking rounds");
    }

    address delegator;
    address candidate;
    uint64 zecAmount;
    uint32 outputIndex;
    {
      (,,bytes29 _voutView,) = zecTx.extractTx();
      (zecAmount, outputIndex, delegator, candidate) = _parseVout(_voutView, script);
      require(zecAmount != 0, "staked value is zero");
      require(ICandidateHub(CANDIDATE_HUB_ADDR).canDelegate(candidate), "inactive candidate");
      require(IRelayerHub(RELAYER_HUB_ADDR).isRelayer(msg.sender), "only relayer can submit");
      IStakeHub(STAKE_HUB_ADDR).onStakeChange(delegator);

      zecTxMap[txid] = ZecTx({
        amount: zecAmount,
        outputIndex: outputIndex,
        blockTimestamp: blockTimestamp,
        lockTime: lockTime,
        usedHeight: 0
      });

      emit delegated(txid, candidate, delegator, script, outputIndex, zecAmount);
    }

    receiptMap[txid] = DepositReceipt({
      candidate: candidate,
      delegator: delegator,
      round: roundTag,
      dualStakeAmount: 0,
      reward: 0
    });

    delegatorTxids[delegator].push(txid);
    candidateMap[candidate].realtimeAmount += zecAmount;
    _addExpire(candidate, lockTime, zecAmount);
  }

  /*********************** Dual Staking **************************/

  /// Add or increase dual stake: lock Native Tokens paired with an existing ZEC stake
  /// When increasing, historical rewards are settled first with the old multiplier.
  function dualStake(bytes32 txid) external payable {
    require(msg.value > 0, "zero dual stake amount");
    DepositReceipt storage dr = receiptMap[txid];
    require(dr.delegator != address(0), "receipt not found");
    require(dr.delegator == msg.sender, "not the delegator");

    ZecTx storage ztx = zecTxMap[txid];
    require(ztx.amount > 0, "zec tx not found");

    // Settle historical rewards with old multiplier before changing dualStakeAmount
    if (dr.dualStakeAmount > 0) {
      uint256 settleRound = roundTag - 1;
      (uint256 settled, ) = _collectReward(
        txid, dr.candidate, dr.round, settleRound, ztx, dr.dualStakeAmount
      );
      if (settled > 0) {
        dr.reward += settled;
      }
      dr.round = settleRound;
    }

    dr.dualStakeAmount += msg.value;
    emit dualStaked(txid, msg.sender, msg.value, dr.dualStakeAmount);
  }

  /*********************** IAgent Implementation **************************/

  function getStakeAmounts(
    address[] calldata candidates,
    uint256 round
  ) external override onlyStakeHub returns (uint256[] memory amounts, uint256 totalAmount) {
    uint256 count = candidates.length;
    amounts = new uint256[](count);
    for (uint256 i = 0; i < count; ++i) {
      amounts[i] = candidateMap[candidates[i]].realtimeAmount;
      totalAmount += amounts[i];
    }
  }

  function setNewRound(
    address[] calldata validators,
    uint256 round
  ) external override onlyStakeHub {
    roundTag = round;
    for (uint256 i = 0; i < validators.length; ++i) {
      CandidateState storage cs = candidateMap[validators[i]];
      cs.stakedAmount = cs.realtimeAmount;
    }
  }

  function distributeReward(
    address[] calldata validators,
    uint256[] calldata rewardList,
    uint256 round
  ) external override onlyStakeHub returns (uint256 undistributed) {
    for (uint256 i = 0; i < validators.length; ++i) {
      if (rewardList[i] == 0) continue;
      CandidateState storage cs = candidateMap[validators[i]];
      if (cs.stakedAmount == 0) {
        undistributed += rewardList[i];
        continue;
      }

      uint256 historyReward;
      uint256 len = cs.continuousRewardEndRounds.length;
      if (len > 0) {
        historyReward = accruedRewardPerZECMap[validators[i]][cs.continuousRewardEndRounds[len - 1]];
      }
      uint256 perZecReward = historyReward + rewardList[i] * ZEC_DECIMAL / cs.stakedAmount;
      accruedRewardPerZECMap[validators[i]][round] = perZecReward;

      if (len > 0 && cs.continuousRewardEndRounds[len - 1] == round - 1) {
        cs.continuousRewardEndRounds[len - 1] = round;
      } else {
        cs.continuousRewardEndRounds.push(round);
      }
    }
  }

  function claimReward(
    address delegator,
    bool claim
  ) external override onlyStakeHub returns (uint256 reward) {
    reward = _processRewards(delegator, roundTag - 1, claim);
    if (reward > 0 && claim) {
      emit claimedReward(delegator, reward);
    }
  }

  function _processRewards(address delegator, uint256 settleRound, bool claim) internal returns (uint256 totalReward) {
    bytes32[] storage txids = delegatorTxids[delegator];

    for (uint256 i = txids.length; i > 0; --i) {
      bytes32 txid = txids[i - 1];
      ZecTx storage ztx = zecTxMap[txid];
      if (ztx.amount == 0) continue;

      DepositReceipt storage dr = receiptMap[txid];
      (uint256 txReward, bool expired) = _collectReward(
        txid, dr.candidate, dr.round, settleRound, ztx, dr.dualStakeAmount
      );

      // Include previously settled reward (from dualStake multiplier change)
      txReward += dr.reward;

      if (txReward > 0) {
        if (claim) {
          dr.reward = 0;
          totalReward += txReward;
        } else {
          dr.reward = txReward;
        }
      }

      // Clean up expired stakes
      if (expired) {
        // Refund dual stake if exists
        if (dr.dualStakeAmount > 0) {
          uint256 refund = dr.dualStakeAmount;
          dr.dualStakeAmount = 0;
          Address.sendValue(payable(dr.delegator), refund);
        }
        if (claim && dr.reward == 0) {
          delete receiptMap[txid];
          txids[i - 1] = txids[txids.length - 1];
          txids.pop();
        }
      }
    }
  }

  /*********************** Expiration Management **************************/

  /// Prepare for new round — remove expired stakes from realtime amounts
  function prepare(uint256 round) external override {
    require(msg.sender == STAKE_HUB_ADDR || msg.sender == CANDIDATE_HUB_ADDR, "not authorized");
    ExpireInfo storage expireInfo = round2expireInfoMap[round];
    for (uint256 i = 0; i < expireInfo.candidateList.length; ++i) {
      address candidate = expireInfo.candidateList[i];
      uint256 amount = expireInfo.amountMap[candidate];
      if (amount > 0 && candidateMap[candidate].realtimeAmount >= amount) {
        candidateMap[candidate].realtimeAmount -= amount;
      }
      delete expireInfo.amountMap[candidate];
    }
    delete expireInfo.candidateList;
  }

  /*********************** Internal Functions **************************/

  /// Parse locktime from CLTV redeem script
  function _parseLockTime(bytes memory script) internal pure returns (uint32) {
    uint256 t;
    assembly {
      let loc := add(script, 0x21)
      t := mload(loc)
    }
    return uint32(t.reverseUint256() & 0xFFFFFFFF);
  }

  /// Parse vout: find the CLTV-locked output and the OP_RETURN binding info
  function _parseVout(
    bytes29 _voutView,
    bytes memory _script
  ) internal pure returns (uint64 zecAmount, uint32 outputIndex, address delegator, address candidate) {
    _voutView.assertType(uint40(BitcoinHelper.BTCTypes.Vout));
    uint256 _numberOfOutputs = uint256(_voutView.indexCompactInt(0));
    bool opreturn;

    for (uint256 idx = 0; idx < _numberOfOutputs; idx++) {
      bytes29 _outputView = _voutView.indexVout(idx);
      bytes29 _scriptPubkeyView = _outputView.scriptPubkey();
      bytes29 _scriptPubkeyWithLength = _outputView.scriptPubkeyWithLength();
      bytes29 _arbitraryData = _scriptPubkeyWithLength.opReturnPayload();

      if (_arbitraryData == TypedMemView.NULL) {
        if (
          (_scriptPubkeyView.len() == 23 &&
          _scriptPubkeyView.indexUint(0, 1) == 0xa9 &&
          _scriptPubkeyView.indexUint(1, 1) == 0x14 &&
          _scriptPubkeyView.indexUint(22, 1) == 0x87 &&
          bytes20(_scriptPubkeyView.indexAddress(2)) == ripemd160(abi.encode(sha256(_script)))) ||
          (_scriptPubkeyView.len() == 34 &&
          _scriptPubkeyView.indexUint(0, 1) == 0 &&
          _scriptPubkeyView.indexUint(1, 1) == 32 &&
          _scriptPubkeyView.index(2, 32) == sha256(_script))
        ) {
          zecAmount = _outputView.value();
          outputIndex = uint32(idx);
        }
      } else {
        (delegator, candidate) = _parsePayload(_arbitraryData);
        opreturn = true;
      }
    }
    require(zecAmount != 0, "staked value is zero");
    require(opreturn, "no opreturn");
  }

  /// Parse OP_RETURN payload: <magic:4> <version:1> <delegator:20> <candidate:20>
  function _parsePayload(bytes29 payload) internal pure returns (address delegator, address candidate) {
    require(payload.len() >= 45, "payload too small");
    require(payload.indexUint(0, 4) == ZEC_STAKE_MAGIC, "wrong magic");
    delegator = payload.indexAddress(5);
    candidate = payload.indexAddress(25);
  }

  /// Track stake expiration by lockTime
  function _addExpire(address candidate, uint32 lockTime, uint256 amount) internal {
    uint256 endRound = uint256(lockTime) / SatoshiPlusHelper.ROUND_INTERVAL;
    ExpireInfo storage expireInfo = round2expireInfoMap[endRound];
    if (expireInfo.amountMap[candidate] == 0) {
      expireInfo.candidateList.push(candidate);
    }
    expireInfo.amountMap[candidate] += amount;
  }

  /// Determine the reward calculation round and expiry (same logic as BitcoinStake)
  function _getCalculateRound(bytes32 txid, uint256 settleRound) internal view returns (uint256 calculateRound, bool expired) {
    ZecTx storage ztx = zecTxMap[txid];
    calculateRound = uint256(ztx.lockTime) / SatoshiPlusHelper.ROUND_INTERVAL - 1;
    expired = calculateRound <= settleRound;
    if (!expired) {
      calculateRound = settleRound;
    }
  }

  /// Calculate reward for a single ZEC stake
  function _collectReward(
    bytes32 txid,
    address candidate,
    uint256 drRound,
    uint256 settleRound,
    ZecTx storage ztx,
    uint256 dualStakeAmount
  ) internal returns (uint256 reward, bool expired) {
    (uint256 calculateRound, bool exp) = _getCalculateRound(txid, settleRound);
    expired = exp;

    if (calculateRound <= drRound) return (0, expired);

    // Base reward
    uint256 accruedAtSettle = _getAccruedReward(candidate, calculateRound);
    uint256 accruedAtStart = _getAccruedReward(candidate, drRound);
    if (accruedAtSettle <= accruedAtStart) return (0, expired);

    reward = (accruedAtSettle - accruedAtStart) * ztx.amount / ZEC_DECIMAL;

    // Apply dual staking multiplier
    if (dualStakeAmount > 0) {
      reward = reward * _getDualStakingMultiplier(dualStakeAmount, ztx.amount) / DENOMINATOR;
    }

    // Update receipt round
    receiptMap[txid].round = calculateRound;

    emit rewardCollected(txid, receiptMap[txid].delegator, reward, expired);
  }

  /// Get dual staking weight multiplier based on nativeToken/ZEC ratio
  function _getDualStakingMultiplier(uint256 nativeAmount, uint64 zecAmount) internal view returns (uint256) {
    if (nativeAmount == 0 || zecAmount == 0) return DENOMINATOR;
    uint256 ratio = nativeAmount * 1e18 / zecAmount;
    uint256 multiplier = DENOMINATOR;
    for (uint256 i = dualStakingGrades.length; i > 0; --i) {
      if (ratio >= dualStakingGrades[i - 1].ratio) {
        multiplier = dualStakingGrades[i - 1].multiplier;
        break;
      }
    }
    return multiplier;
  }

  /// Get accrued reward for a candidate at a given round
  function _getAccruedReward(address candidate, uint256 round) internal view returns (uint256) {
    uint256 value = accruedRewardPerZECMap[candidate][round];
    if (value != 0) return value;

    CandidateState storage cs = candidateMap[candidate];
    uint256 len = cs.continuousRewardEndRounds.length;
    for (uint256 i = len; i > 0; --i) {
      uint256 endRound = cs.continuousRewardEndRounds[i - 1];
      if (endRound >= round) {
        uint256 startRound = (i >= 2) ? cs.continuousRewardEndRounds[i - 2] + 1 : 1;
        if (round >= startRound) {
          return accruedRewardPerZECMap[candidate][endRound];
        }
      }
    }
    return 0;
  }

  /*********************** Governance **************************/

  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov {
    if (value.length != 32) {
      revert MismatchParamLength(key);
    }
    revert UnsupportedGovParam(key);
    emit paramChange(key, value);
  }

  /*********************** View Functions **************************/

  function getDelegatorTxids(address delegator) external view returns (bytes32[] memory) {
    return delegatorTxids[delegator];
  }

  function getContinuousRewardEndRounds(address candidate) external view returns (uint256[] memory) {
    return candidateMap[candidate].continuousRewardEndRounds;
  }

  function getDualStakingGrades() external view returns (DualStakingGrade[] memory) {
    return dualStakingGrades;
  }

  function getDualStakingMultiplier(uint256 nativeAmount, uint64 zecAmount) external view returns (uint256) {
    return _getDualStakingMultiplier(nativeAmount, zecAmount);
  }
}
