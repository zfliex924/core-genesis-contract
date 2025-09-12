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

  /// for backward compatibility - allow users to unstake through PledgeAgent
  /// support channel from v1.0.20
  /// @param candidate the validator candidate address
  /// @param delegator the delegator address
  /// @param channelId the channel id, 0 represents from PledgeAgent
  function proxyDelegate(address candidate, address delegator, uint32 channelId) external payable;

  /// for backward compatibility - allow users to unstake through PledgeAgent
  /// support channel from v1.0.20
  /// @param candidate the validator candidate address
  /// @param delegator the delegator address
  /// @param amount the amount of CORE to unstake
  function proxyUnDelegate(address candidate, address delegator, uint256 amount) external returns(uint256);
}