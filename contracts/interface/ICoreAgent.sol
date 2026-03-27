// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./IAgent.sol";

interface ICoreAgent is IAgent {
  /// @param candidate the validator candidate address
  /// @param delegator the delegator address
  /// @param channelId the channel id
  function proxyDelegate(address candidate, address delegator, uint32 channelId) external payable;
}