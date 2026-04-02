// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./interface/INativeAgent.sol";
import "./interface/IParamSubscriber.sol";
import "./interface/IGradeManager.sol";
import "./interface/ICandidateHub.sol";
import "./lib/Address.sol";
import "./lib/Memory.sol";
import "./lib/BytesToTypes.sol";
import "./lib/SatoshiPlusHelper.sol";
import "./System.sol";

/// NativeAgent handles native token staking using per-stake records (StakeTx).
/// Each delegation creates an individual StakeTx identified by a unique stakeId.
/// Rewards are tracked via accrued-reward-per-unit on each candidate.
contract NativeAgent is INativeAgent, System, IParamSubscriber {

  uint256 public constant INIT_REQUIRED_COIN_DEPOSIT = 1e18;
  uint256 public constant UNDELEGATE_DELAY = 72 hours;

  uint256 public requiredCoinDeposit;
  uint256 public roundTag;

  /// @dev Individual stake record
  struct StakeTx {
    address candidate;       // validator candidate
    address delegator;       // stake owner
    uint256 amount;          // staked amount
    uint256 round;           // round when staked (for reward calculation start)
    uint256 lockUntilRound;  // locked until this round (0 = no lock)
    uint256 multiplier;              // reward multiplier fixed at delegate time (DENOMINATOR = 10000 = 1.0x)
    uint256 reward;                  // accumulated unclaimed reward (from transfer settlement)
    uint256 undelegateRequestTime;   // block.timestamp when undelegate was requested (0 = not requested)
  }


  /// @dev Per-candidate staking state
  struct Candidate {
    uint256 stakedAmount;           // snapshot for current round
    uint256 realtimeAmount;         // current realtime staked amount
    uint256 stakedWeightedAmount;   // snapshot: Σ(amount * multiplier)
    uint256 realtimeWeightedAmount; // realtime: Σ(amount * multiplier)
    uint256[] rewardEndRounds;
  }

  // Auto-increment nonce for generating unique stake IDs
  uint256 public stakeIdCounter;

  // Primary storage
  mapping(bytes32 => StakeTx) public stakeTxMap;
  mapping(address => Candidate) public candidateMap;
  mapping(address => bytes32[]) public delegatorStakeIds;

  // Reward tracking: candidate => round => accrued reward per unit
  mapping(address => mapping(uint256 => uint256)) public accruedRewardMap;

  /*********************** events **************************/
  event delegatedCoin(bytes32 indexed stakeId, address indexed candidate, address indexed delegator, uint256 amount);
  event undelegateRequested(bytes32 indexed stakeId, address indexed delegator, uint256 requestRound);
  event undelegatedCoin(bytes32 indexed stakeId, address indexed candidate, address indexed delegator, uint256 amount);
  event transferredCoin(bytes32 indexed stakeId, address indexed targetCandidate, address indexed delegator, uint256 amount);
  event claimedReward(address indexed delegator, uint256 reward);

  /*********************** Init ********************************/
  function init() external onlyNotInit {
    requiredCoinDeposit = INIT_REQUIRED_COIN_DEPOSIT;
    roundTag = block.timestamp / SatoshiPlusHelper.ROUND_INTERVAL;
    stakeIdCounter = 1;
    alreadyInit = true;
  }

  /*********************** IAgent implementations ***************************/

  function distributeReward(
    address[] calldata validators,
    uint256[] calldata rewardList,
    uint256 round
  ) external override onlyStakeHub returns (uint256 undistributed) {
    uint256 validateSize = validators.length;
    require(validateSize == rewardList.length, "the length of validators and rewardList should be equal");

    for (uint256 i = 0; i < validateSize; i++) {
      if (rewardList[i] == 0) continue;
      Candidate storage c = candidateMap[validators[i]];
      if (c.stakedWeightedAmount == 0) {
        undistributed += rewardList[i];
        continue;
      }

      uint256 historyReward;
      uint256 l = c.rewardEndRounds.length;
      uint256 lastRewardRound;
      if (l != 0) {
        lastRewardRound = c.rewardEndRounds[l - 1];
        historyReward = accruedRewardMap[validators[i]][lastRewardRound];
      }
      accruedRewardMap[validators[i]][round] = historyReward + rewardList[i] * SatoshiPlusHelper.CORE_STAKE_DECIMAL / c.stakedWeightedAmount;
      if (lastRewardRound + 1 == round) {
        c.rewardEndRounds[l - 1] = round;
      } else {
        c.rewardEndRounds.push(round);
      }
    }
  }

  function getStakeAmounts(
    address[] calldata candidates,
    uint256
  ) external override view returns (uint256[] memory amounts, uint256 totalAmount) {
    uint256 candidateSize = candidates.length;
    amounts = new uint256[](candidateSize);
    for (uint256 i = 0; i < candidateSize; ++i) {
      amounts[i] = candidateMap[candidates[i]].realtimeWeightedAmount;
      totalAmount += amounts[i];
    }
  }

  function setNewRound(
    address[] calldata validators,
    uint256 round
  ) external override onlyStakeHub {
    for (uint256 i = 0; i < validators.length; ++i) {
      Candidate storage a = candidateMap[validators[i]];
      a.stakedAmount = a.realtimeAmount;
      a.stakedWeightedAmount = a.realtimeWeightedAmount;
    }
    roundTag = round;
  }

  function claimReward(address delegator) external override onlyStakeHub returns (uint256 reward) {
    bytes32[] storage stakeIds = delegatorStakeIds[delegator];
    uint256 settleRound = roundTag - 1;

    for (uint256 i = stakeIds.length; i > 0; --i) {
      StakeTx storage stx = stakeTxMap[stakeIds[i - 1]];
      if (stx.amount == 0) continue;

      uint256 rawReward = _collectReward(stx, settleRound) + stx.reward;
      stx.reward = 0;
      reward += rawReward * stx.multiplier / SatoshiPlusHelper.DENOMINATOR;
    }

    if (reward != 0) {
      emit claimedReward(delegator, reward);
    }
  }

  /*********************** External methods ***************************/

  /// Delegate native coin with a specific lock duration (in rounds/days)
  /// The multiplier is determined by matching lockRound against grades
  /// @param candidate The validator candidate
  /// @param lockRound Number of rounds to lock (must match a grade's lockDays)
  function delegateCoin(address candidate, uint256 lockRound) external override payable returns (bytes32 stakeId) {
    require(msg.value >= requiredCoinDeposit, "delegate amount is too small");
    uint256 multiplier = IGradeManager(GRADE_MANAGER_ADDR).getMultiplier(lockRound);

    stakeId = _createStake(candidate, msg.value, roundTag + lockRound, multiplier);
    emit delegatedCoin(stakeId, candidate, msg.sender, msg.value);
  }

  function _createStake(address candidate, uint256 amount, uint256 lockUntilRound, uint256 multiplier) internal returns (bytes32 stakeId) {
    stakeId = bytes32(stakeIdCounter++);
    stakeTxMap[stakeId] = StakeTx({
      candidate: candidate,
      delegator: msg.sender,
      amount: amount,
      round: roundTag,
      lockUntilRound: lockUntilRound,
      multiplier: multiplier,
      reward: 0,
      undelegateRequestTime: 0
    });
    delegatorStakeIds[msg.sender].push(stakeId);
    Candidate storage c = candidateMap[candidate];
    c.realtimeAmount += amount;
    c.realtimeWeightedAmount += amount * multiplier;
  }


  /// Request to undelegate — must wait UNDELEGATE_DELAY rounds before withdrawing
  function requestUndelegate(bytes32 stakeId) external override {
    StakeTx storage stx = stakeTxMap[stakeId];
    require(stx.amount > 0, "stake not found");
    require(stx.delegator == msg.sender, "not the delegator");
    require(stx.undelegateRequestTime == 0, "already requested");

    stx.undelegateRequestTime = block.timestamp;
    emit undelegateRequested(stakeId, msg.sender, block.timestamp);
  }

  /// Withdraw after undelegate delay has passed
  /// If lock period completed (roundTag >= lockUntilRound): full reward at original multiplier
  /// If early exit: reward at minimum multiplier (DENOMINATOR = 1.0x)
  function undelegateCoin(bytes32 stakeId) external override returns (uint256 amount, uint256 reward) {
    StakeTx storage stx = stakeTxMap[stakeId];
    require(stx.amount > 0, "stake not found");
    require(stx.delegator == msg.sender, "not the delegator");
    require(stx.undelegateRequestTime > 0, "must request first");
    require(block.timestamp >= stx.undelegateRequestTime + UNDELEGATE_DELAY, "delay not met");

    amount = stx.amount;
    address candidate = stx.candidate;

    uint256 rawReward = _collectReward(stx, roundTag - 1) + stx.reward;
    uint256 mul = roundTag >= stx.lockUntilRound ? stx.multiplier : SatoshiPlusHelper.DENOMINATOR;
    reward = rawReward * mul / SatoshiPlusHelper.DENOMINATOR;

    Candidate storage c = candidateMap[candidate];
    c.realtimeAmount -= amount;
    c.realtimeWeightedAmount -= amount * stx.multiplier;

    _removeStake(msg.sender, stakeId);

    Address.sendValue(payable(msg.sender), amount + reward);

    emit undelegatedCoin(stakeId, candidate, msg.sender, amount);
  }

  /// Transfer a stake to a different candidate
  function transferCoin(address targetCandidate, bytes32 stakeId) external override {
    StakeTx storage stx = stakeTxMap[stakeId];
    require(stx.amount > 0, "stake not found");
    require(stx.delegator == msg.sender, "not the delegator");
    require(stx.candidate != targetCandidate, "same candidate");

    // Settle reward from old candidate, store in StakeTx
    stx.reward += _collectReward(stx, roundTag - 1);

    // Move stake
    address oldCandidate = stx.candidate;
    uint256 weighted = stx.amount * stx.multiplier;
    candidateMap[oldCandidate].realtimeAmount -= stx.amount;
    candidateMap[oldCandidate].realtimeWeightedAmount -= weighted;
    candidateMap[targetCandidate].realtimeAmount += stx.amount;
    candidateMap[targetCandidate].realtimeWeightedAmount += weighted;
    stx.candidate = targetCandidate;
    stx.round = roundTag;

    emit transferredCoin(stakeId, targetCandidate, msg.sender, stx.amount);
  }

  /*********************** Internal methods ***************************/

  function _collectReward(StakeTx storage stx, uint256 settleRound) internal returns (uint256 reward) {
    if (stx.round >= settleRound) return 0;

    uint256 accruedAtSettle = _getAccruedReward(stx.candidate, settleRound);
    uint256 accruedAtStart = _getAccruedReward(stx.candidate, stx.round);
    if (accruedAtSettle <= accruedAtStart) return 0;

    // base reward (without multiplier) — caller applies multiplier as needed
    reward = (accruedAtSettle - accruedAtStart) * stx.amount / SatoshiPlusHelper.CORE_STAKE_DECIMAL;

    stx.round = settleRound;
  }

  function _getAccruedReward(address candidate, uint256 round) internal view returns (uint256) {
    uint256 value = accruedRewardMap[candidate][round];
    if (value != 0) return value;

    Candidate storage c = candidateMap[candidate];
    uint256 len = c.rewardEndRounds.length;
    for (uint256 i = len; i > 0; --i) {
      uint256 endRound = c.rewardEndRounds[i - 1];
      if (endRound >= round) {
        uint256 startRound = (i >= 2) ? c.rewardEndRounds[i - 2] + 1 : 1;
        if (round >= startRound) {
          return accruedRewardMap[candidate][endRound];
        }
      }
    }
    return 0;
  }

  function _removeStake(address delegator, bytes32 stakeId) internal {
    delete stakeTxMap[stakeId];
    bytes32[] storage ids = delegatorStakeIds[delegator];
    for (uint256 i = 0; i < ids.length; i++) {
      if (ids[i] == stakeId) {
        ids[i] = ids[ids.length - 1];
        ids.pop();
        break;
      }
    }
  }

  /*********************** Governance ********************************/
  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov {
    if (Memory.compareStrings(key, "requiredCoinDeposit")) {
      require(value.length == 32, "length mismatch");
      uint256 newRequiredCoinDeposit = BytesToTypes.bytesToUint256(32, value);
      if (newRequiredCoinDeposit == 0) {
        revert OutOfBounds(key, newRequiredCoinDeposit, 1, type(uint256).max);
      }
      requiredCoinDeposit = newRequiredCoinDeposit;
    } else {
      revert UnsupportedGovParam(key);
    }
    emit paramChange(key, value);
  }

  /*********************** View methods ********************************/
  function getDelegatorStakeIds(address delegator) external view returns (bytes32[] memory) {
    return delegatorStakeIds[delegator];
  }

  function getContinuousRewardEndRounds(address candidate) external view returns (uint256[] memory) {
    return candidateMap[candidate].rewardEndRounds;
  }
}
