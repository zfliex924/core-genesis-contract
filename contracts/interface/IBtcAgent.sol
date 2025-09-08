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
}