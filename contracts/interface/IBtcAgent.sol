// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./IAgent.sol";

interface IBtcAgent is IAgent {
  struct DualStakingGrade {
    uint32 stakeRate;
    uint32 percentage;
  }

  struct LockLengthGrade {
    uint64 lockDuration; // In second
    uint32 percentage; // [0 ~ DENOMINATOR]
  }

  /// Returns grades.
  function getGrades() external view returns (DualStakingGrade[] memory);

  /// Return a grade for the given stake rate.
  ///
  /// @param rate the stake rate
  /// @return percentage the target percentage
  /// @return stakeRate the target stake rate
  function getGrade(uint256 rate) external view returns (uint256 percentage, uint256 stakeRate);

  /// Liquidation reward for delegator
  /// @param isStakeWeight whether the delegator is stake weight
  /// @param delegator the delegator address
  /// @param coreAmount the staked amount of staked CORE.
  /// @param settleRound the settlement round
  /// @return floatReward floating reward amount
  function liquidationReward(bool isStakeWeight, address delegator, uint256 coreAmount, uint256 settleRound) external returns (int256 floatReward);

  /// Calculate float reward for BTC staker
  /// @param lockTime the lock time of the BTC stake transaction
  /// @param blockTimestamp the block timestamp of the BTC stake transaction
  /// @param amount the amount of the BTC stake transaction
  /// @param initReward the initial reward of the BTC stake transaction
  /// @param coreAmount the staked amount of staked CORE.
  /// @return reward the reward of the BTC stake transaction
  /// @return floatReward the floating reward of the BTC stake transaction
  /// @return remainingCoreAmount the remaining core amount of the BTC stake transaction
  /// @return ldPercentage the time grading percentage of the BTC stake transaction
  /// @return dsPercentage the dual staking percentage of the BTC stake transaction
  function calculateFloatReward(uint32 lockTime, uint64 blockTimestamp, uint64 amount, uint256 initReward, uint256 coreAmount) external view returns (uint256 reward, int256 floatReward, uint256 remainingCoreAmount, uint256 ldPercentage, uint256 dsPercentage);
}