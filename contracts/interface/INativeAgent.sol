// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./IAgent.sol";

interface INativeAgent is IAgent {
  function delegateCoin(address candidate, uint256 lockRound) external payable returns (bytes32 stakeId);
  function undelegateCoin(bytes32 stakeId) external returns (uint256 amount, uint256 reward);
  function transferCoin(address targetCandidate, bytes32 stakeId) external;
}
