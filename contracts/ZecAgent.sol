// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
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
///
/// Key differences from BTC staking:
/// - No locktime: uses OP_RETURN to declare stake duration (soft constraint)
/// - Three states: Fixed-term (定期), Demand (活期), Expired (已到期)
/// - Early UTXO spend → downgrade from fixed-term to demand rate
/// - Cannot claim rewards before stake duration expires (for fixed-term)
/// - Mandatory DAO fee output in every staking transaction
/// - Uses ZecLightClient for proof verification
contract ZecAgent is IAgent, IZecAgent, System, IParamSubscriber, ReentrancyGuard {

  using BitcoinHelper for bytes;
  using BitcoinHelper for bytes29;
  using TypedMemView for bytes;
  using TypedMemView for bytes29;

  // ZEC decimal: 1 ZEC = 1e8 zatoshi
  uint256 public constant ZEC_DECIMAL = 1e8;
  uint256 public constant DENOMINATOR = 10000;

  // Stake status
  uint8 public constant STATUS_FIXED = 0;    // 定期 - fixed-term, within duration
  uint8 public constant STATUS_DEMAND = 1;   // 活期 - demand, UTXO spent early
  uint8 public constant STATUS_EXPIRED = 2;  // 已到期 - duration completed

  // OP_RETURN magic for ZEC staking
  uint32 public constant ZEC_STAKE_MAGIC = 0x5A45432b; // "ZEC+"

  // Confirmation blocks for ZEC (24 blocks ≈ 30 minutes)
  uint32 public constant ZEC_CONFIRM_BLOCK = 24;

  // Default parameters
  uint256 public constant INIT_MIN_DELEGATE = 1e6;  // 0.01 ZEC minimum
  uint256 public constant INIT_DAO_FEE = 200;       // 200 zatoshi
  uint256 public constant INIT_FIXED_RATE_PERCENTAGE = 10000;  // 100% of base reward
  uint256 public constant INIT_DEMAND_RATE_PERCENTAGE = 2000;  // 20% of base reward

  /// @dev ZEC transaction record for staking
  struct ZecTx {
    uint64 amount;           // ZEC amount in zatoshi
    uint32 outputIndex;      // UTXO output index
    uint64 blockTimestamp;   // Zcash block timestamp
    uint32 stakeDuration;    // Declared stake duration in seconds (from OP_RETURN)
    uint32 usedHeight;       // Height at which UTXO was spent (0 = unspent)
    uint8  status;           // 0=fixed, 1=demand, 2=expired
  }

  /// @dev Deposit receipt linking txid to candidate/delegator
  struct DepositReceipt {
    address candidate;       // Validator candidate
    address delegator;       // Delegator EVM address
    uint256 round;           // Round when deposit was recorded
    uint256 dualStakeAmount; // Native Token amount for dual staking (0 = no dual stake)
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

  /// @dev Reward record per delegator
  struct Reward {
    uint256 reward;
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

  // Per-delegator reward vault
  mapping(address => Reward) public rewardMap;

  // DAO fee parameters
  address public daoAddress;
  uint64  public daoFee;

  // Staking parameters
  uint256 public minDelegate;
  uint256 public fixedRatePercentage;   // reward percentage for fixed-term stakes
  uint256 public demandRatePercentage;  // reward percentage for demand stakes (after early spend)

  // Dual staking weight grades
  // multiplier based on nativeToken / zecAmount ratio
  struct DualStakingGrade {
    uint256 ratio;        // nativeToken / zecAmount threshold (scaled by 1e18)
    uint256 multiplier;   // weight multiplier (DENOMINATOR = 10000 = 1.0x)
  }
  DualStakingGrade[] public dualStakingGrades;

  /*********************** events **************************/
  event delegated(bytes32 indexed txid, address indexed candidate, address indexed delegator, uint64 amount, uint32 stakeDuration);
  event spentReported(bytes32 indexed txid, uint8 newStatus);
  event rewardCollected(bytes32 indexed txid, address indexed delegator, uint256 reward, bool expired, uint256 ratePercentage);
  event claimedReward(address indexed delegator, uint256 amount);
  event dualStaked(bytes32 indexed txid, address indexed delegator, uint256 nativeAmount);
  event dualUnstaked(bytes32 indexed txid, address indexed delegator, uint256 nativeAmount);

  /*********************** Init **************************/
  function init() external onlyNotInit {
    minDelegate = INIT_MIN_DELEGATE;
    daoFee = uint64(INIT_DAO_FEE);
    fixedRatePercentage = INIT_FIXED_RATE_PERCENTAGE;
    demandRatePercentage = INIT_DEMAND_RATE_PERCENTAGE;
    roundTag = 1;

    // Default dual staking grades (ratio threshold, multiplier)
    // ratio = nativeToken * 1e18 / zecAmount
    // No dual stake: 1.0x (DENOMINATOR)
    dualStakingGrades.push(DualStakingGrade(0, 10000));       // 0: 1.0x base
    dualStakingGrades.push(DualStakingGrade(1e17, 11000));    // 0.1: 1.1x
    dualStakingGrades.push(DualStakingGrade(2e17, 13000));    // 0.2: 1.3x
    dualStakingGrades.push(DualStakingGrade(5e17, 15000));    // 0.5: 1.5x

    alreadyInit = true;
  }

  /*********************** Delegation **************************/

  /// Delegate ZEC to Z Protocol
  /// Expected transaction structure:
  ///   output[0]: stake amount → stake address
  ///   output[1]: OP_RETURN <magic><version><candidate><delegator><stake_duration>
  ///   output[2]: daoFee → daoAddress
  ///
  /// @param zecTx the ZEC transaction data
  /// @param blockHeight block height of the transaction
  /// @param nodes Merkle proof nodes
  /// @param index index of the tx in Merkle tree
  function delegate(
    bytes calldata zecTx,
    uint32 blockHeight,
    bytes32[] memory nodes,
    uint256 index
  ) external override nonReentrant {
    bytes32 txid = zecTx.calculateTxId();
    require(zecTxMap[txid].amount == 0, "already delegated");

    // Verify transaction is confirmed on Zcash chain
    (bool txChecked, uint64 blockTimestamp) = ILightClient(ZEC_LIGHT_CLIENT_ADDR)
      .checkTxProofAndGetTime(txid, blockHeight, ZEC_CONFIRM_BLOCK, nodes, index);
    require(txChecked, "zec tx not confirmed");

    // Parse transaction outputs
    (uint32 _version, , bytes29 _voutView, ) = zecTx.extractTx();
    _voutView.assertType(uint40(BitcoinHelper.BTCTypes.Vout));

    // Parse OP_RETURN from output[1] to get staking info
    (address candidate, address delegator, uint32 stakeDuration) = _parseOpReturn(_voutView);
    require(ICandidateHub(CANDIDATE_HUB_ADDR).canDelegate(candidate), "inactive candidate");

    // Parse stake amount from output[0]
    uint64 zecAmount = BitcoinHelper.parseOutputValue(_voutView, 0);
    require(zecAmount >= minDelegate, "stake amount too small");

    // Validate DAO fee output[2]
    if (daoAddress != address(0) && daoFee > 0) {
      uint64 feeAmount = BitcoinHelper.parseOutputValue(_voutView, 2);
      require(feeAmount >= daoFee, "insufficient DAO fee");
    }

    // Calculate expiry round
    uint256 endRound = (blockTimestamp + stakeDuration) / SatoshiPlusHelper.ROUND_INTERVAL;
    require(endRound > roundTag + 1, "stake duration too short");

    // Store ZEC tx
    zecTxMap[txid] = ZecTx({
      amount: zecAmount,
      outputIndex: 0,
      blockTimestamp: blockTimestamp,
      stakeDuration: stakeDuration,
      usedHeight: 0,
      status: STATUS_FIXED
    });

    // Store receipt
    receiptMap[txid] = DepositReceipt({
      candidate: candidate,
      delegator: delegator,
      round: roundTag,
      dualStakeAmount: 0
    });

    // Update delegator and candidate state
    delegatorTxids[delegator].push(txid);
    candidateMap[candidate].realtimeAmount += zecAmount;

    // Track expiration
    _addExpire(candidate, endRound, zecAmount);

    // Notify StakeHub
    IStakeHub(STAKE_HUB_ADDR).onStakeChange(delegator);

    emit delegated(txid, candidate, delegator, zecAmount, stakeDuration);
  }

  /// Report that a staked UTXO has been spent on Zcash chain
  /// If spent before stakeDuration expires, downgrade to demand rate
  function reportSpent(
    bytes calldata zecTx,
    uint32 blockHeight,
    bytes32[] memory nodes,
    uint256 index
  ) external override nonReentrant {
    bytes32 spendTxid = zecTx.calculateTxId();

    // Verify spending transaction is confirmed
    bool txChecked = ILightClient(ZEC_LIGHT_CLIENT_ADDR)
      .checkTxProof(spendTxid, blockHeight, ZEC_CONFIRM_BLOCK, nodes, index);
    require(txChecked, "spend tx not confirmed");

    // Parse inputs to find which staked UTXOs are being spent
    (, bytes29 _vinView, , ) = zecTx.extractTx();
    _vinView.assertType(uint40(BitcoinHelper.BTCTypes.Vin));

    uint256 _numberOfInputs = uint256(_vinView.indexCompactInt(0));
    uint256 count;

    for (uint256 i = 0; i < _numberOfInputs; ++i) {
      bytes29 _input = _vinView.indexVin(i);
      bytes32 prevTxid = _input.outpoint().txidLE();
      uint32 prevIndex = _input.outpoint().outpointIdx();

      ZecTx storage ztx = zecTxMap[prevTxid];
      if (ztx.amount == 0 || ztx.usedHeight != 0) continue;
      if (ztx.outputIndex != prevIndex) continue;

      // Mark as spent
      ztx.usedHeight = blockHeight;

      // Check if spent before duration expires
      uint64 expireTimestamp = ztx.blockTimestamp + ztx.stakeDuration;
      uint256 currentTimestamp = block.timestamp;

      if (currentTimestamp < expireTimestamp && ztx.status == STATUS_FIXED) {
        // Early spend → downgrade to demand rate
        ztx.status = STATUS_DEMAND;
      } else if (ztx.status == STATUS_FIXED) {
        // Normal expiry
        ztx.status = STATUS_EXPIRED;
      }

      count++;
      emit spentReported(prevTxid, ztx.status);
    }
    require(count > 0, "no staked UTXO found in inputs");
  }

  /*********************** Dual Staking **************************/

  /// Add dual stake: lock Native Tokens paired with an existing ZEC stake
  /// The Native Token amount is recorded in the DepositReceipt
  /// @param txid The ZEC staking transaction ID to pair with
  function dualStake(bytes32 txid) external payable nonReentrant {
    require(msg.value > 0, "zero dual stake amount");
    DepositReceipt storage dr = receiptMap[txid];
    require(dr.delegator != address(0), "receipt not found");
    require(dr.delegator == msg.sender, "not the delegator");
    require(dr.dualStakeAmount == 0, "already dual staked");

    ZecTx storage ztx = zecTxMap[txid];
    require(ztx.amount > 0, "zec tx not found");
    require(ztx.status == STATUS_FIXED, "only fixed-term stakes can dual stake");

    dr.dualStakeAmount = msg.value;

    emit dualStaked(txid, msg.sender, msg.value);
  }

  /// Remove dual stake: unlock Native Tokens from a ZEC stake
  /// Can be called at any time; the Native Tokens are returned to the delegator
  /// @param txid The ZEC staking transaction ID to unpair
  function dualUnstake(bytes32 txid) external nonReentrant {
    DepositReceipt storage dr = receiptMap[txid];
    require(dr.delegator != address(0), "receipt not found");
    require(dr.delegator == msg.sender, "not the delegator");
    require(dr.dualStakeAmount > 0, "no dual stake");

    uint256 amount = dr.dualStakeAmount;
    dr.dualStakeAmount = 0;

    Address.sendValue(payable(msg.sender), amount);

    emit dualUnstaked(txid, msg.sender, amount);
  }

  /*********************** IAgent Implementation **************************/

  /// Get stake amounts for each candidate
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
    return (amounts, totalAmount);
  }

  /// Snapshot staked amounts for the new round
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

  /// Distribute rewards for the round
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

      // Calculate accrued reward per ZEC for this round
      uint256 historyReward;
      uint256 len = cs.continuousRewardEndRounds.length;
      if (len > 0) {
        historyReward = accruedRewardPerZECMap[validators[i]][cs.continuousRewardEndRounds[len - 1]];
      }
      uint256 perZecReward = historyReward + rewardList[i] * ZEC_DECIMAL / cs.stakedAmount;
      accruedRewardPerZECMap[validators[i]][round] = perZecReward;

      // Track continuous reward rounds
      if (len > 0 && cs.continuousRewardEndRounds[len - 1] == round - 1) {
        cs.continuousRewardEndRounds[len - 1] = round;
      } else {
        cs.continuousRewardEndRounds.push(round);
      }
    }
  }

  /// Claim reward for a delegator
  function claimReward(
    address delegator,
    uint256,
    uint256 settleRound,
    bool claim
  ) external override onlyStakeHub returns (uint256 reward, int256 floatReward) {
    uint256 totalReward = _processRewards(delegator, settleRound);

    if (totalReward > 0) {
      if (claim) {
        reward = totalReward;
        emit claimedReward(delegator, reward);
      } else {
        rewardMap[delegator].reward += totalReward;
      }
    }

    // floatReward = 0 (no external subsidy in weight model)
    return (reward, 0);
  }

  function _processRewards(address delegator, uint256 settleRound) internal returns (uint256 totalReward) {
    bytes32[] storage txids = delegatorTxids[delegator];

    for (uint256 i = txids.length; i > 0; --i) {
      bytes32 txid = txids[i - 1];
      ZecTx storage ztx = zecTxMap[txid];

      if (ztx.amount == 0) continue;

      // Check if stake has expired by duration
      _checkAndUpdateExpiry(ztx);

      // Fixed-term stakes cannot claim until expired
      if (ztx.status == STATUS_FIXED) continue;

      // Calculate reward
      DepositReceipt storage dr = receiptMap[txid];
      (uint256 txReward, bool expired) = _collectReward(
        txid, dr.candidate, dr.round, settleRound, ztx, dr.dualStakeAmount
      );
      totalReward += txReward;

      // Clean up fully expired and claimed stakes
      if (expired && ztx.usedHeight != 0) {
        // Refund dual stake if exists
        if (dr.dualStakeAmount > 0) {
          uint256 refund = dr.dualStakeAmount;
          dr.dualStakeAmount = 0;
          Address.sendValue(payable(dr.delegator), refund);
          emit dualUnstaked(txid, dr.delegator, refund);
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
      uint256 amount = expireInfo.amountMap[candidate];
      if (amount > 0 && candidateMap[candidate].realtimeAmount >= amount) {
        candidateMap[candidate].realtimeAmount -= amount;
      }
      delete expireInfo.amountMap[candidate];
    }
    delete expireInfo.candidateList;
  }

  /*********************** Internal Functions **************************/

  /// Parse OP_RETURN data from output[1]
  /// Format: OP_RETURN <magic:4> <version:1> <candidate:20> <delegator:20> <stakeDuration:4>
  function _parseOpReturn(bytes29 _voutView) internal pure returns (
    address candidate, address delegator, uint32 stakeDuration
  ) {
    bytes29 output1 = _voutView.indexVout(1);
    bytes29 scriptPubkey = output1.scriptPubkey();
    bytes29 payload = scriptPubkey.opReturnPayload();
    require(payload.len() >= 49, "invalid OP_RETURN length");  // 4+1+20+20+4 = 49

    uint32 magic = uint32(payload.indexUint(0, 4));
    require(magic == ZEC_STAKE_MAGIC, "invalid magic");

    // Skip version byte (offset 4)
    candidate = payload.indexAddress(5);
    delegator = payload.indexAddress(25);
    stakeDuration = uint32(payload.indexUint(45, 4));
    require(stakeDuration > 0, "zero stake duration");
  }

  /// Track stake expiration
  function _addExpire(address candidate, uint256 endRound, uint256 amount) internal {
    ExpireInfo storage expireInfo = round2expireInfoMap[endRound];
    if (expireInfo.amountMap[candidate] == 0) {
      expireInfo.candidateList.push(candidate);
    }
    expireInfo.amountMap[candidate] += amount;
  }

  /// Check and update expiry status based on time
  function _checkAndUpdateExpiry(ZecTx storage ztx) internal {
    if (ztx.status != STATUS_FIXED) return;
    uint64 expireTimestamp = ztx.blockTimestamp + ztx.stakeDuration;
    if (block.timestamp >= expireTimestamp) {
      ztx.status = STATUS_EXPIRED;
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
    uint256 expireRound = (uint256(ztx.blockTimestamp) + uint256(ztx.stakeDuration)) / SatoshiPlusHelper.ROUND_INTERVAL;
    expired = (expireRound <= settleRound);
    uint256 calculateRound = expired ? (expireRound > 0 ? expireRound - 1 : 0) : settleRound;

    if (calculateRound <= drRound) return (0, expired);

    reward = _calcBaseReward(candidate, drRound, calculateRound, ztx);
    if (reward == 0) return (0, expired);

    // Apply dual staking multiplier
    reward = reward * _getDualStakingMultiplier(dualStakeAmount, ztx.amount) / DENOMINATOR;

    emit rewardCollected(txid, receiptMap[txid].delegator, reward, expired,
      ztx.status == STATUS_DEMAND ? demandRatePercentage : fixedRatePercentage);
  }

  function _calcBaseReward(
    address candidate,
    uint256 drRound,
    uint256 calculateRound,
    ZecTx storage ztx
  ) internal view returns (uint256) {
    uint256 accruedAtSettle = _getAccruedReward(candidate, calculateRound);
    uint256 accruedAtStart = _getAccruedReward(candidate, drRound);
    if (accruedAtSettle <= accruedAtStart) return 0;

    uint256 baseReward = (accruedAtSettle - accruedAtStart) * ztx.amount / ZEC_DECIMAL;
    uint256 ratePercentage = ztx.status == STATUS_DEMAND ? demandRatePercentage : fixedRatePercentage;
    return baseReward * ratePercentage / DENOMINATOR;
  }

  /// Get dual staking weight multiplier based on nativeToken/ZEC ratio
  function _getDualStakingMultiplier(uint256 nativeAmount, uint64 zecAmount) internal view returns (uint256) {
    if (nativeAmount == 0 || zecAmount == 0) return DENOMINATOR;

    uint256 ratio = nativeAmount * 1e18 / zecAmount;
    uint256 multiplier = DENOMINATOR; // default 1.0x

    for (uint256 i = dualStakingGrades.length; i > 0; --i) {
      if (ratio >= dualStakingGrades[i - 1].ratio) {
        multiplier = dualStakingGrades[i - 1].multiplier;
        break;
      }
    }
    return multiplier;
  }

  /// Get accrued reward for a candidate at a given round
  /// Handles gaps in continuous reward rounds
  function _getAccruedReward(address candidate, uint256 round) internal view returns (uint256) {
    uint256 value = accruedRewardPerZECMap[candidate][round];
    if (value != 0) return value;

    // Search continuous reward end rounds
    CandidateState storage cs = candidateMap[candidate];
    uint256 len = cs.continuousRewardEndRounds.length;
    for (uint256 i = len; i > 0; --i) {
      uint256 endRound = cs.continuousRewardEndRounds[i - 1];
      if (endRound >= round) {
        // This continuous range covers our target round
        // Find the start of this range
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
    if (Memory.compareStrings(key, "minDelegate")) {
      uint256 newMinDelegate = BytesToTypes.bytesToUint256(32, value);
      require(newMinDelegate > 0, "minDelegate must be positive");
      minDelegate = newMinDelegate;
    } else if (Memory.compareStrings(key, "daoFee")) {
      uint256 newDaoFee = BytesToTypes.bytesToUint256(32, value);
      require(newDaoFee <= 1e8, "daoFee too large");
      daoFee = uint64(newDaoFee);
    } else if (Memory.compareStrings(key, "daoAddress")) {
      address newDaoAddress = BytesToTypes.bytesToAddress(32, value);
      daoAddress = newDaoAddress;
    } else if (Memory.compareStrings(key, "fixedRatePercentage")) {
      uint256 newRate = BytesToTypes.bytesToUint256(32, value);
      require(newRate > 0 && newRate <= DENOMINATOR, "fixedRatePercentage out of range");
      fixedRatePercentage = newRate;
    } else if (Memory.compareStrings(key, "demandRatePercentage")) {
      uint256 newRate = BytesToTypes.bytesToUint256(32, value);
      require(newRate <= DENOMINATOR, "demandRatePercentage out of range");
      demandRatePercentage = newRate;
    } else {
      revert UnsupportedGovParam(key);
    }
    emit paramChange(key, value);
  }

  /*********************** View Functions **************************/

  /// Get delegator's staked transaction IDs
  function getDelegatorTxids(address delegator) external view returns (bytes32[] memory) {
    return delegatorTxids[delegator];
  }

  /// Get candidate's continuous reward end rounds
  function getContinuousRewardEndRounds(address candidate) external view returns (uint256[] memory) {
    return candidateMap[candidate].continuousRewardEndRounds;
  }

  /// Get dual staking grades
  function getDualStakingGrades() external view returns (DualStakingGrade[] memory) {
    return dualStakingGrades;
  }

  /// Get dual staking multiplier for a given nativeToken/zecAmount
  function getDualStakingMultiplier(uint256 nativeAmount, uint64 zecAmount) external view returns (uint256) {
    return _getDualStakingMultiplier(nativeAmount, zecAmount);
  }
}
