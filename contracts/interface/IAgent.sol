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
  /// @return amounts List of amounts of all special candidates in this round
  /// @return totalAmount The sum of all amounts of valid/invalid candidates.
  function getStakeAmounts(address[] calldata candidates, uint256 round) external returns (uint256[] memory amounts, uint256 totalAmount);

  /// Start new round, this is called by the StakeHub contract
  /// @param validators List of elected validators in this round
  /// @param round The new round tag
  function setNewRound(address[] calldata validators, uint256 round) external;

  /// Receive round rewards from StakeHub, which is triggered at the beginning of turn round
  /// @param validators List of validator operator addresses
  /// @param rewardList List of reward amount
  /// @param round The round tag
  /// @param stakeWeight the weight of stake asset
  /// @return burnAmount the amount of reward to burn
  function distributeReward(address[] calldata validators, uint256[] calldata rewardList, uint256 round, uint256 stakeWeight) external returns (uint256 burnAmount);

  /// Claim reward for delegator
  /// @param delegator the delegator address
  /// @param txIds the given txid list to claim. If the list is empty, it means all.
  /// @return reward Amount claimed
  function claimReward(address delegator, bytes32[] memory txIds) external returns (uint256 reward);

  /// Enable stake weight
  /// @param delegator the delegator address
  function enableStakeWeight(address delegator) external;

  /// Disable stake weight
  /// @param delegator the delegator address
  function disableStakeWeight(address delegator) external;
}