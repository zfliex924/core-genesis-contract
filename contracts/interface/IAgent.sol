// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

interface IAgent {
  /// The validator candidate is inactive, it is expected to be active
  /// @param candidate Address of the validator candidate
  error InactiveCandidate(address candidate);

  /// Same address provided when transfer.
  /// @param candidate Address of the candidate
  error SameCandidate(address candidate);

  /// Get stake amount
  /// @param candidates List of candidate operator addresses
  /// @param round The new round tag
  /// @return amounts List of realtime amounts of all candidates
  /// @return totalAmount The sum of all realtime amounts
  /// @return weightedAmounts List of weighted amounts of all candidates
  /// @return totalWeightedAmount The sum of all weighted amounts
  function getStakeAmounts(address[] calldata candidates, uint256 round) external returns (uint256[] memory amounts, uint256 totalAmount, uint256[] memory weightedAmounts, uint256 totalWeightedAmount);

  /// Start new round, this is called by the StakeHub contract
  /// @param validators List of elected validators in this round
  /// @param round The new round tag
  function setNewRound(address[] calldata validators, uint256 round) external;

  /// Receive round rewards from StakeHub, which is triggered at the beginning of turn round
  /// @param validators List of validator operator addresses
  /// @param rewardList List of reward amount
  /// @param round The round tag
  /// @return undistributed Amount of rewards not distributed (to be burned)
  function distributeReward(address[] calldata validators, uint256[] calldata rewardList, uint256 round) external returns (uint256 undistributed);

  /// Claim reward for delegator
  /// @param delegator the delegator address
  /// @return reward Amount claimed
  function claimReward(address delegator) external returns (uint256 reward);
}