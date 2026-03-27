// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./IAgent.sol";

interface ICoreAgent is IAgent {
  /// Claim reward for delegator
  /// @param delegator the delegator address
  /// @param claim claim or store rewards
  /// @return reward Amount claimed
  /// @return stakedAmount1 the staked amount in the first round
  /// @return stakedAmount2 the real amount in the last round
  function claimReward(address delegator, bool claim) external returns (uint256 reward, uint256 stakedAmount1, uint256 stakedAmount2);

  /// @param candidate the validator candidate address
  /// @param delegator the delegator address
  /// @param channelId the channel id
  function proxyDelegate(address candidate, address delegator, uint32 channelId) external payable;
}