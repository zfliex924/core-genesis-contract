// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.24;

interface ISlashIndicator {
  function clean() external;
  function exitMaintenanceSlash(address validator, uint256 blockCount) external;
}