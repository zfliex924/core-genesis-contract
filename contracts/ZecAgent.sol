// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./lib/Memory.sol";
import "./lib/BytesToTypes.sol";
import "./lib/BitcoinHelper.sol";
import "./lib/SatoshiPlusHelper.sol";
import "./interface/IAgent.sol";
import "./interface/IZecAgent.sol";
import "./interface/ILightClient.sol";
import "./interface/IStakeHub.sol";
import "./interface/IChannel.sol";
import "./interface/IGradeManager.sol";
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



  // Confirmation blocks for ZEC (24 blocks ≈ 30 minutes)
  uint32 public constant ZEC_CONFIRM_BLOCK = 24;

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
    uint256 lockMultiplier;  // Time-based multiplier fixed at delegate time
    uint256 dualMultiplier;  // Dual staking multiplier from GradeManager (updated on dualStake)
    uint256 dualStakeAmount; // Native Token amount for dual staking (0 = no dual stake)
    uint256 reward;          // Settled but unclaimed reward (from dualStake multiplier change)
  }

  /// @dev Per-candidate staking state
  struct CandidateState {
    uint256 stakedAmount;           // snapshot for current round
    uint256 realtimeAmount;         // current realtime staked amount
    uint256 stakedWeightedAmount;   // snapshot: Σ(amount * multiplier)
    uint256 realtimeWeightedAmount; // realtime: Σ(amount * multiplier)
    uint256[] rewardEndRounds;
  }

  struct ExpireAmount {
    uint256 amount;
    uint256 weightedAmount;
  }

  /// @dev Expiration tracking per round
  struct ExpireInfo {
    address[] candidateList;
    mapping(address => ExpireAmount) amountMap;
  }


  // Round tag
  uint256 public roundTag;

  // Dual staking conversion rate: zecEquivalent = dualStakeAmount / dualConversionRate
  // Combines precision alignment (1e10) + value discount factor
  // e.g. 1e10 means 1:1 value, 2e10 means native token worth 0.5x ZEC
  uint256 public dualConversionRate;

  // Staking data
  mapping(bytes32 => ZecTx) public zecTxMap;
  mapping(bytes32 => DepositReceipt) public receiptMap;
  mapping(address => bytes32[]) public delegatorTxids;
  mapping(address => CandidateState) public candidateMap;

  // Reward tracking: candidate => round => accrued reward per ZEC
  mapping(address => mapping(uint256 => uint256)) public accruedRewardPerZECMap;

  // Expiration tracking
  mapping(uint256 => ExpireInfo) round2expireInfoMap;


  /*********************** events **************************/
  event delegated(bytes32 indexed txid, address indexed candidate, address indexed delegator, bytes script, uint32 outputIndex, uint64 amount);
  event rewardCollected(bytes32 indexed txid, address indexed delegator, uint256 reward, bool expired);
  event transferredZec(bytes32 indexed txid, address indexed sourceCandidate, address indexed targetCandidate, address delegator);
  event claimedReward(address indexed delegator, uint256 amount);
  event dualStaked(bytes32 indexed txid, address indexed delegator, uint256 nativeAmount, uint256 totalDualStakeAmount);

  /*********************** Init **************************/
  function init() external onlyNotInit {
    roundTag = 1;
    dualConversionRate = 1e10; // 1:1 value after precision alignment (1e18/1e8)
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

      uint256 expireRound = uint256(lockTime) / SatoshiPlusHelper.ROUND_INTERVAL;
      require(expireRound > roundTag + 1, "insufficient locking rounds");
    }

    address delegator;
    address candidate;
    uint64 zecAmount;
    {
      (,,bytes29 _voutView,) = zecTx.extractTx();
      uint32 outputIndex;
      uint32 candidateId;
      uint32 partnerId;
      uint32 version;
      (zecAmount, outputIndex, delegator, candidateId, partnerId, version) = _parseVout(_voutView, script);
      require(zecAmount != 0, "staked value is zero");
      require(IRelayerHub(RELAYER_HUB_ADDR).isRelayer(msg.sender), "only relayer can submit");

      candidate = _resolveCandidate(candidateId);

      zecTxMap[txid] = ZecTx(zecAmount, outputIndex, blockTimestamp, lockTime, 0);

      if (version == SatoshiPlusHelper.SATOSHI_STAKE_CHANNEL_VERSION) {
        IChannel(CHANNEL_ADDR).onZecStake(delegator, txid, partnerId);
        delegator = CHANNEL_ADDR;
      }

      emit delegated(txid, candidate, delegator, script, outputIndex, zecAmount);
    }

    // Compute time-based multiplier from lock duration in days (fixed at delegate time)
    uint256 lockDays = (lockTime - blockTimestamp) / 1 days;
    uint256 lockMul = IGradeManager(GRADE_MANAGER_ADDR).getMultiplier(lockDays);

    receiptMap[txid] = DepositReceipt({
      candidate: candidate,
      delegator: delegator,
      round: roundTag,
      lockMultiplier: lockMul,
      dualMultiplier: SatoshiPlusHelper.DENOMINATOR,
      dualStakeAmount: 0,
      reward: 0
    });

    delegatorTxids[delegator].push(txid);
    CandidateState storage cs = candidateMap[candidate];
    cs.realtimeAmount += zecAmount;
    // initial: dualMul = DENOMINATOR, dualStakeAmount = 0 → weighted = amount * lockMul
    uint256 weighted = _calcWeighted(zecAmount, lockMul, SatoshiPlusHelper.DENOMINATOR, 0);
    cs.realtimeWeightedAmount += weighted;
    _addExpire(candidate, lockTime, zecAmount, weighted);
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

    uint256 expireRound = uint256(ztx.lockTime) / SatoshiPlusHelper.ROUND_INTERVAL;
    require(expireRound > roundTag + 1, "insufficient locking rounds");

    // Settle historical rewards with old multiplier before changing dualStakeAmount
    if (dr.dualStakeAmount > 0) {
      uint256 settleRound = roundTag - 1;
      (uint256 settled, ) = _collectReward(
        txid, dr.candidate, dr.round, settleRound, ztx
      );
      if (settled > 0) {
        dr.reward += settled;
      }
      dr.round = settleRound;
    }

    // Calculate old weighted before changes
    uint256 oldWeighted = _calcWeighted(ztx.amount, dr.lockMultiplier, dr.dualMultiplier, dr.dualStakeAmount);

    dr.dualStakeAmount += msg.value;
    // ratio = nativeAmount / zecAmount after precision alignment
    uint256 ratio = dr.dualStakeAmount / ztx.amount / 1e10;
    dr.dualMultiplier = IGradeManager(GRADE_MANAGER_ADDR).getDualMultiplier(ratio);

    // Update weighted
    uint256 newWeighted = _calcWeighted(ztx.amount, dr.lockMultiplier, dr.dualMultiplier, dr.dualStakeAmount);
    CandidateState storage cs = candidateMap[dr.candidate];
    cs.realtimeWeightedAmount = cs.realtimeWeightedAmount - oldWeighted + newWeighted;

    emit dualStaked(txid, msg.sender, msg.value, dr.dualStakeAmount);
  }

  /// Transfer a ZEC stake to a different candidate
  /// @param txid The ZEC staking transaction ID
  /// @param targetCandidate The target validator candidate
  function transferZec(bytes32 txid, address targetCandidate) external override {
    DepositReceipt storage dr = receiptMap[txid];
    require(dr.delegator == msg.sender, "not the delegator");
    require(dr.candidate != targetCandidate, "same candidate");

    ZecTx storage ztx = zecTxMap[txid];
    require(ztx.amount > 0, "zec tx not found");

    uint256 expireRound = uint256(ztx.lockTime) / SatoshiPlusHelper.ROUND_INTERVAL;
    require(expireRound > roundTag + 1, "insufficient locking rounds");

    // Settle reward from old candidate
    (uint256 settled, ) = _collectReward(txid, dr.candidate, dr.round, roundTag - 1, ztx);
    dr.reward += settled;
    dr.round = roundTag;

    // Move weighted amount
    uint256 weighted = _calcWeighted(ztx.amount, dr.lockMultiplier, dr.dualMultiplier, dr.dualStakeAmount);
    CandidateState storage oldCs = candidateMap[dr.candidate];
    oldCs.realtimeAmount -= ztx.amount;
    oldCs.realtimeWeightedAmount -= weighted;

    CandidateState storage newCs = candidateMap[targetCandidate];
    newCs.realtimeAmount += ztx.amount;
    newCs.realtimeWeightedAmount += weighted;

    // Migrate expiry info to the new candidate
    address sourceCandidate = dr.candidate;
    _removeExpire(sourceCandidate, ztx.lockTime, ztx.amount, weighted);
    _addExpire(targetCandidate, ztx.lockTime, ztx.amount, weighted);

    dr.candidate = targetCandidate;

    emit transferredZec(txid, sourceCandidate, targetCandidate, msg.sender);
  }

  /*********************** IAgent Implementation **************************/

  function getStakeAmounts(
    address[] calldata candidates,
    uint256 round
  ) external override onlyStakeHub returns (uint256[] memory amounts, uint256 totalAmount) {
    uint256 count = candidates.length;
    amounts = new uint256[](count);
    for (uint256 i = 0; i < count; ++i) {
      amounts[i] = candidateMap[candidates[i]].realtimeWeightedAmount;
      totalAmount += amounts[i];
    }
  }

  function getRealtimeAmounts(
    address[] calldata candidates
  ) external override view returns (uint256[] memory amounts, uint256 totalAmount) {
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
      cs.stakedWeightedAmount = cs.realtimeWeightedAmount;
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
      if (cs.stakedWeightedAmount == 0) {
        undistributed += rewardList[i];
        continue;
      }

      uint256 historyReward;
      uint256 len = cs.rewardEndRounds.length;
      if (len > 0) {
        historyReward = accruedRewardPerZECMap[validators[i]][cs.rewardEndRounds[len - 1]];
      }
      uint256 perZecReward = historyReward + rewardList[i] * SatoshiPlusHelper.ZEC_DECIMAL / cs.stakedWeightedAmount;
      accruedRewardPerZECMap[validators[i]][round] = perZecReward;

      if (len > 0 && cs.rewardEndRounds[len - 1] == round - 1) {
        cs.rewardEndRounds[len - 1] = round;
      } else {
        cs.rewardEndRounds.push(round);
      }
    }
  }

  function claimReward(
    address delegator
  ) external override onlyStakeHub returns (uint256 reward) {
    reward = _processRewards(delegator, roundTag - 1);
    if (reward > 0) {
      emit claimedReward(delegator, reward);
    }
  }

  function _processRewards(address delegator, uint256 settleRound) internal returns (uint256 totalReward) {
    bytes32[] storage txids = delegatorTxids[delegator];

    for (uint256 i = txids.length; i > 0; --i) {
      bytes32 txid = txids[i - 1];
      ZecTx storage ztx = zecTxMap[txid];
      if (ztx.amount == 0) continue;

      DepositReceipt storage dr = receiptMap[txid];
      (uint256 txReward, bool expired) = _collectReward(
        txid, dr.candidate, dr.round, settleRound, ztx
      );

      // Include previously settled reward (from dualStake multiplier change)
      txReward += dr.reward;
      dr.reward = 0;
      totalReward += txReward;

      // Clean up expired stakes
      if (expired) {
        if (dr.dualStakeAmount > 0) {
          uint256 refund = dr.dualStakeAmount;
          dr.dualStakeAmount = 0;
          Address.sendValue(payable(dr.delegator), refund);
        }
        delete receiptMap[txid];
        txids[i - 1] = txids[txids.length - 1];
        txids.pop();
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
      ExpireAmount storage ea = expireInfo.amountMap[candidate];
      CandidateState storage cs = candidateMap[candidate];
      if (ea.amount > 0 && cs.realtimeAmount >= ea.amount) {
        cs.realtimeAmount -= ea.amount;
      }
      if (ea.weightedAmount > 0 && cs.realtimeWeightedAmount >= ea.weightedAmount) {
        cs.realtimeWeightedAmount -= ea.weightedAmount;
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
  ) internal pure returns (uint64 zecAmount, uint32 outputIndex, address delegator, uint32 candidateId, uint32 partnerId, uint32 version) {
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
        (delegator, candidateId, partnerId, version) = _parsePayload(_arbitraryData);
        opreturn = true;
      }
    }
    require(zecAmount != 0, "staked value is zero");
    require(opreturn, "no opreturn");
  }

  /// Parse OP_RETURN payload: <magic:4> <version:1> <delegator:20> <candidateId:4> <partnerId:4>
  function _parsePayload(bytes29 payload) internal pure returns (address delegator, uint32 candidateId, uint32 partnerId, uint32 version) {
    require(payload.len() >= 33, "payload too small");
    require(payload.indexUint(0, 4) == SatoshiPlusHelper.SATOSHI_MAGIC, "wrong magic");
    version = uint32(payload.indexUint(4, 1));
    delegator = payload.indexAddress(5);
    candidateId = uint32(payload.indexUint(25, 4));
    partnerId = uint32(payload.indexUint(29, 4));
  }

  /// Resolve candidateId to operator address via CandidateHub.idMap
  function _resolveCandidate(uint32 candidateId) internal view returns (address candidate) {
    (bool ok, bytes memory data) = CANDIDATE_HUB_ADDR.staticcall(abi.encodeWithSignature("idMap(uint32)", candidateId));
    require(ok && data.length == 32, "idMap call failed");
    candidate = abi.decode(data, (address));
  }

  /// Track stake expiration by lockTime
  function _addExpire(address candidate, uint32 lockTime, uint256 amount, uint256 weightedAmount) internal {
    uint256 expireRound = uint256(lockTime) / SatoshiPlusHelper.ROUND_INTERVAL;
    ExpireInfo storage expireInfo = round2expireInfoMap[expireRound];
    if (expireInfo.amountMap[candidate].amount == 0) {
      expireInfo.candidateList.push(candidate);
    }
    expireInfo.amountMap[candidate].amount += amount;
    expireInfo.amountMap[candidate].weightedAmount += weightedAmount;
  }

  /// Remove stake expiration record (counterpart of _addExpire)
  function _removeExpire(address candidate, uint32 lockTime, uint256 amount, uint256 weightedAmount) internal {
    uint256 expireRound = uint256(lockTime) / SatoshiPlusHelper.ROUND_INTERVAL;
    ExpireInfo storage expireInfo = round2expireInfoMap[expireRound];
    if (expireInfo.amountMap[candidate].amount >= amount) {
      expireInfo.amountMap[candidate].amount -= amount;
    }

    if (expireInfo.amountMap[candidate].weightedAmount >= weightedAmount) {
      expireInfo.amountMap[candidate].weightedAmount -= weightedAmount;
    }
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
    ZecTx storage ztx
  ) internal returns (uint256 reward, bool expired) {
    (uint256 calculateRound, bool exp) = _getCalculateRound(txid, settleRound);
    expired = exp;

    if (calculateRound <= drRound) return (0, expired);

    // Base reward
    uint256 accruedAtSettle = _getAccruedReward(candidate, calculateRound);
    uint256 accruedAtStart = _getAccruedReward(candidate, drRound);
    if (accruedAtSettle <= accruedAtStart) return (0, expired);

    // reward share = accruedDiff × weighted / ZEC_DECIMAL
    DepositReceipt storage dr = receiptMap[txid];
    uint256 weighted = _calcWeighted(ztx.amount, dr.lockMultiplier, dr.dualMultiplier, dr.dualStakeAmount);
    reward = (accruedAtSettle - accruedAtStart) * weighted / SatoshiPlusHelper.ZEC_DECIMAL;

    // Update receipt round
    receiptMap[txid].round = calculateRound;

    emit rewardCollected(txid, receiptMap[txid].delegator, reward, expired);
  }

  /// Calculate weighted amount for a stake
  /// weighted = zecAmount × lockMul × dualMul / DENOMINATOR + dualStakeAmount × DENOMINATOR / dualConversionRate
  function _calcWeighted(uint256 zecAmount, uint256 lockMul, uint256 dualMul, uint256 dualAmount) internal view returns (uint256) {
    uint256 zecPart = zecAmount * lockMul * dualMul / SatoshiPlusHelper.DENOMINATOR;
    uint256 dualPart = dualConversionRate > 0 ? dualAmount * SatoshiPlusHelper.DENOMINATOR / dualConversionRate : 0;
    return zecPart + dualPart;
  }

  /// Get accrued reward for a candidate at a given round
  function _getAccruedReward(address candidate, uint256 round) internal view returns (uint256) {
    uint256 value = accruedRewardPerZECMap[candidate][round];
    if (value != 0) return value;

    CandidateState storage cs = candidateMap[candidate];
    uint256 len = cs.rewardEndRounds.length;
    for (uint256 i = len; i > 0; --i) {
      if (cs.rewardEndRounds[i - 1] <= round) {
        return accruedRewardPerZECMap[candidate][cs.rewardEndRounds[i - 1]];
      }
    }
    return 0;
  }

  /*********************** Governance **************************/

  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov {
    if (value.length != 32) {
      revert MismatchParamLength(key);
    }
    if (Memory.compareStrings(key, "dualConversionRate")) {
      uint256 newRate = BytesToTypes.bytesToUint256(32, value);
      require(newRate > 0, "zero conversion rate");
      dualConversionRate = newRate;
    } else {
      revert UnsupportedGovParam(key);
    }
    emit paramChange(key, value);
  }

  /*********************** View Functions **************************/

  function getDelegatorTxids(address delegator) external view returns (bytes32[] memory) {
    return delegatorTxids[delegator];
  }

  function getContinuousRewardEndRounds(address candidate) external view returns (uint256[] memory) {
    return candidateMap[candidate].rewardEndRounds;
  }

}
