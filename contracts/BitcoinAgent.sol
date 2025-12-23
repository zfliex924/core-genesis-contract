// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./interface/IBtcAgent.sol";
import "./interface/IBitcoinStake.sol";
import "./interface/IParamSubscriber.sol";
import "./lib/Memory.sol";
import "./lib/SatoshiPlusHelper.sol";
import "./System.sol";
import "./lib/BytesLib.sol";
import "./lib/RLPDecode.sol";
import "./lib/SafeCast.sol";

/// This contract handles BTC staking. 
/// It interacts with BitcoinStake.sol for
/// non-custodial BTC staking correspondingly. 
contract BitcoinAgent is IBtcAgent, System, IParamSubscriber {
  using BytesLib for *;
  using RLPDecode for bytes;
  using RLPDecode for RLPDecode.Iterator;
  using RLPDecode for RLPDecode.RLPItem;
  using SafeCast for uint256;

  uint256 public constant DEFAULT_CORE_BTC_CONVERSION = 1e10;

  // key: candidate
  // value: staked BTC amount
  mapping (address => StakeAmount) public candidateMap;

  // CORE grading applied to BTC stakers
  DualStakingGrade[] public grades;

  // whether the CORE grading is enabled
  bool public gradeActive;

  // conversion rate between CORE and the asset
  uint256 public assetWeight;

  // Deprecated in V-1.0.20
  uint256 public lstGradePercentage;

  // Time grading applied to BTC stakers
  LockLengthGrade[] public lockLengthGrades;

  struct StakeAmount {
    // Deprecated, never used.
    uint256 lstStakeAmount;
    // staked BTC amount from non custodial
    uint256 stakeAmount;
  }

  event claimedBtcReward(address indexed delegator, uint256 amount, uint256 unclaimedAmount, int256 floatReward, uint256 accStakedAmount, uint256 dualStakingRate);
  event storedBtcReward(address indexed delegator, uint256 amount, uint256 unclaimedAmount, int256 floatReward, uint256 accStakedAmount, uint256 dualStakingRate);

  error NotImplemented();

  function init() external onlyNotInit {
    assetWeight = DEFAULT_CORE_BTC_CONVERSION;
    alreadyInit = true;
  }

  /*********************** IAgent implementations ***************************/
  /// Receive round rewards from StakeHub, which is triggered at the beginning of turn round.
  /// @param validators List of validator operator addresses
  /// @param rewardList List of reward amount
  /// @param stakeWeight the weight of stake asset
  function distributeReward(address[] calldata validators, uint256[] calldata rewardList, uint256 /*round*/, uint256 stakeWeight) external override onlyStakeHub returns (uint256) {
    return IBitcoinStake(BTC_STAKE_ADDR).distributeReward(validators, rewardList, stakeWeight);
  }

  /// Get staked BTC amount
  /// @param candidates List of candidate operator addresses
  /// @return amounts List of staked BTC amounts of all candidates in this round
  /// @return totalAmount Total BTC staked on all candidates in this round
  function getStakeAmounts(address[] calldata candidates, uint256 /*round*/) external override onlyStakeHub returns (uint256[] memory amounts, uint256 totalAmount) {
    uint256 candidateSize = candidates.length;
    amounts = IBitcoinStake(BTC_STAKE_ADDR).getStakeAmounts(candidates);
    for (uint256 i = 0; i < candidateSize; ++i) {
      candidateMap[candidates[i]].stakeAmount = amounts[i];
      totalAmount += amounts[i];
    }
  }

  /// Start new round, this is called by the StakeHub contract
  /// @param validators List of elected validators in this round
  /// @param round The new round tag
  function setNewRound(address[] calldata validators, uint256 round) external override onlyStakeHub {
    IBitcoinStake(BTC_STAKE_ADDR).setNewRound(validators, round);
  }

  /// Liquidation reward for delegator
  /// @param isStakeWeight whether the delegator is stake weight
  /// @param delegator the delegator address
  /// @param coreAmount the staked amount of staked CORE.
  /// @param settleRound the settlement round
  /// @return floatReward floating reward amount
  function liquidationReward(bool isStakeWeight, address delegator, uint256 coreAmount, uint256 settleRound) external override onlyStakeHub returns (int256 floatReward) {
    return IBitcoinStake(BTC_STAKE_ADDR).liquidationReward(isStakeWeight, delegator, coreAmount, settleRound);
  }

  /// Claim reward for delegator
  /// @param delegator the delegator address
  /// @param btcIds the given txid list to claim. If the list is empty, it means all.
  /// @return reward Amount claimed
  function claimReward(address delegator, bytes32[] memory btcIds) external override onlyStakeHub returns (uint256 reward) {
    return IBitcoinStake(BTC_STAKE_ADDR).claimReward(delegator, btcIds);
  }

  /*********************** External methods ********************************/
  /// Returns grades.
  function getGrades() external view override returns (DualStakingGrade[] memory) {
    return grades;
  }

  /// Return a grade for the given stake rate.
  ///
  /// @param rate the stake rate
  /// @return percentage the target percentage
  /// @return stakeRate the target stake rate
  function getGrade(uint256 rate) public view override returns (uint256 percentage, uint256 stakeRate) {
    percentage = SatoshiPlusHelper.DENOMINATOR;
    stakeRate = 0;
    uint256 gradeLength = grades.length;
    if (gradeActive && gradeLength != 0) {
      percentage = grades[0].percentage;
      stakeRate = grades[0].stakeRate;
      rate /= assetWeight;
      for (uint256 j = gradeLength - 1; j != 0; j--) {
        if (rate >= grades[j].stakeRate) {
          percentage = grades[j].percentage;
          stakeRate = grades[j].stakeRate;
          break;
        }
      }
      stakeRate *= assetWeight;
    }
  }

  /// Enable stake weight.
  /// @param delegator the delegator address
  function enableStakeWeight(address delegator) external override onlyStakeHub {
     IBitcoinStake(BTC_STAKE_ADDR).enableStakeWeight(delegator);
  }

  /// Disable stake weight.
  /// @param delegator the delegator address
  function disableStakeWeight(address delegator) external override onlyStakeHub {
    IBitcoinStake(BTC_STAKE_ADDR).disableStakeWeight(delegator);
  }

  function calculateFloatReward(uint32 lockTime, uint64 blockTimestamp, uint64 amount, uint256 initReward, uint256 coreAmount) override external view returns (uint256 reward, int256 floatReward, uint256 remainingCoreAmount, uint256 ldPercentage, uint256 dsPercentage) {
    reward = initReward;
    if (reward != 0) {
      uint256 pReward;
      // apply time grading to BTC rewards
      if (lockLengthGrades.length != 0) {
        uint64 lockDuration = lockTime - blockTimestamp;
        ldPercentage = lockLengthGrades[0].percentage;
        for (uint256 j = lockLengthGrades.length - 1; j != 0; j--) {
          if (lockDuration >= lockLengthGrades[j].lockDuration) {
            ldPercentage = lockLengthGrades[j].percentage;
            break;
          }
        }
        pReward = reward * ldPercentage / SatoshiPlusHelper.DENOMINATOR;
        floatReward = pReward.toInt256() - reward.toInt256();
        reward = pReward;
      }
      (remainingCoreAmount, dsPercentage) = _applyDualStaking(coreAmount, amount);
      pReward = reward * dsPercentage / SatoshiPlusHelper.DENOMINATOR;
      floatReward += pReward.toInt256() - reward.toInt256();
      reward = pReward;
    } else {
      remainingCoreAmount = coreAmount;
    }
  }

  function _applyDualStaking(uint256 coreAmount, uint256 btcAmount) internal view returns (uint256, uint256) {
    uint256 dsPercentage;
    uint256 stakeRate = coreAmount / btcAmount;
    (dsPercentage, stakeRate) = getGrade(stakeRate);
    uint256 dualAmount = stakeRate * btcAmount;
    if (coreAmount > dualAmount) {
      coreAmount -= dualAmount;
    } else {
      coreAmount = 0;
    }
    return (coreAmount, dsPercentage);
  }

  /*********************** Governance ********************************/
  /// Update parameters through governance vote
  /// @param key The name of the parameter
  /// @param value the new value set to the parameter
  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyCaller(GOV_HUB_ADDR) {
    if (Memory.compareStrings(key, "grades")) {
      uint256 lastLength = grades.length;

      RLPDecode.RLPItem[] memory items = value.toRLPItem().toList();
      uint256 currentLength = items.length;
      if (currentLength == 0) {
         revert MismatchParamLength(key);
      }

      for (uint256 i = currentLength; i < lastLength; i++) {
        grades.pop();
      }

      uint256 stakeRate;
      uint256 percentage;
      for (uint256 i = 0; i < currentLength; i++) {
        RLPDecode.RLPItem[] memory itemArray = items[i].toList();
        stakeRate = RLPDecode.toUint(itemArray[0]);
        percentage = RLPDecode.toUint(itemArray[1]);
        if (stakeRate > 1e8) {
          revert OutOfBounds('stakeRate', stakeRate, 0, 1e8);
        }
        if (percentage > SatoshiPlusHelper.DENOMINATOR * 100) {
          revert OutOfBounds('percentage', percentage, 0, SatoshiPlusHelper.DENOMINATOR * 100);
        }
        if (i >= lastLength) {
          grades.push(DualStakingGrade(uint32(stakeRate), uint32(percentage)));
        } else {
          grades[i] = DualStakingGrade(uint32(stakeRate), uint32(percentage));
        }
      }
      // check stakeRate & percentage in order.
      for (uint256 i = 1; i < currentLength; i++) {
        require(grades[i-1].stakeRate < grades[i].stakeRate, "stakeRate disorder");
        require(grades[i-1].percentage < grades[i].percentage, "percentage disorder");
      }
      require(grades[0].stakeRate == 0, "lowest stakeRate must be zero");
    } else if (Memory.compareStrings(key, "gradeActive")) {
      if (value.length != 1) {
        revert MismatchParamLength(key);
      }
      uint8 newGradeActive = value.toUint8(0);
      if (newGradeActive > 1) {
        revert OutOfBounds(key, newGradeActive, 0, 1);
      }
      gradeActive = newGradeActive == 1;
    } else if (Memory.compareStrings(key, "lockLengthGrades")) {
      uint256 lastLength = lockLengthGrades.length;
      RLPDecode.RLPItem[] memory items = value.toRLPItem().toList();
      uint256 currentLength = items.length;

      for (uint256 i = currentLength; i < lastLength; i++) {
        lockLengthGrades.pop();
      }
      uint256 lockDuration;
      uint256 percentage;
      for (uint256 i = 0; i < currentLength; i++) {
        RLPDecode.RLPItem[] memory itemArray = items[i].toList();
        lockDuration = RLPDecode.toUint(itemArray[0]);
        // limit lockDuration 4000 rounds.
        if (lockDuration > 4000) {
          revert OutOfBounds('lockDuration', percentage, 0, 4000);
        }
        percentage = RLPDecode.toUint(itemArray[1]);
        if (percentage == 0 || percentage > SatoshiPlusHelper.DENOMINATOR) {
          revert OutOfBounds('percentage', percentage, 1, SatoshiPlusHelper.DENOMINATOR);
        }
        lockDuration *= SatoshiPlusHelper.ROUND_INTERVAL;
        if (i >= lastLength) {
          lockLengthGrades.push(LockLengthGrade(uint64(lockDuration), uint32(percentage)));
        } else {
          lockLengthGrades[i] = LockLengthGrade(uint64(lockDuration), uint32(percentage));
        }
      }
      // check lockDuration & percentage in order.
      for (uint256 i = 1; i < currentLength; i++) {
        require(lockLengthGrades[i-1].lockDuration < lockLengthGrades[i].lockDuration, "lockDuration disorder");
        require(lockLengthGrades[i-1].percentage < lockLengthGrades[i].percentage, "percentage disorder");
      }
      if (currentLength != 0) {
        require(lockLengthGrades[0].lockDuration == 0, "lowest lockDuration must be zero");
      }
    }
    else {
        revert UnsupportedGovParam(key);
    }

    emit paramChange(key, value);
  }
}