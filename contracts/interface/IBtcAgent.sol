// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./IAgent.sol";

interface IBtcAgent is IAgent {
  struct DualStakingGrade {
    uint32 stakeRate;
    uint32 percentage;
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
}