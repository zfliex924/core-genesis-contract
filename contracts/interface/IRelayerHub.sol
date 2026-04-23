// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.24;

interface IRelayerHub {
  function isRelayer(address sender) external view returns (bool);

  /// Record a header submission by a relayer, called by ZcashLightClient
  /// @param relayer The relayer who submitted the header
  function recordHeaderSubmission(address relayer) external;

  /// Record a coinbase submission by a relayer, called by HashPowerAgent
  /// @param relayer The relayer who submitted the coinbase tx
  function recordCoinbaseSubmission(address relayer) external;

  /// Record a ZEC delegate submission by a relayer, called by ZecAgent
  /// @param relayer The relayer who submitted the delegate tx
  function recordDelegateSubmission(address relayer) external;

  /// Claim accumulated relayer rewards
  /// @param relayer The relayer address to claim for
  function claimRelayerReward(address relayer) external;
}
