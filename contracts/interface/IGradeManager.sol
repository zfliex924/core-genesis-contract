// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

interface IGradeManager {
  function getMultiplier(uint256 lockValue) external view returns (uint256);
  function getDualMultiplier(uint256 ratio) external view returns (uint256);
}
