// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

interface ISlashIndicator {
  function clean() external;
  function exitMaintenanceSlash(address validator, uint256 blockCount) external;
}