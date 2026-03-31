// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

interface IChannel {
  /// Called by ZecAgent when a ZEC stake has version == SATOSHI_STAKE_CHANNEL_VERSION
  /// The delegator in ZecAgent is set to Channel's address; Channel tracks the real delegator
  /// @param realDelegator The actual user who initiated the stake
  /// @param txid The ZEC staking transaction ID
  /// @param candidate The validator candidate
  function onZecStake(address realDelegator, bytes32 txid, address candidate) external;
}
