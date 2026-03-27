// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

interface IRelayerHub {
  function isRelayer(address sender) external view returns (bool);

  /// Record a header submission by a relayer, called by LightClient contracts
  /// @param relayer The relayer who submitted the header
  function recordHeaderSubmission(address relayer) external;

  /// Claim accumulated relayer rewards
  /// @param relayer The relayer address to claim for
  function claimRelayerReward(address relayer) external;
}


