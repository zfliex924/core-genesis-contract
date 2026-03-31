// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./IAgent.sol";

interface INativeAgent is IAgent {
  function delegateCoin(address candidate) external payable;
  function undelegateCoin(address candidate, uint256 amount) external;
  function transferCoin(address sourceCandidate, address targetCandidate, uint256 amount) external;
}
