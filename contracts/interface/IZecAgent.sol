// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

interface IZecAgent {
  /// Delegate ZEC to Z Protocol, called by relayer
  /// @param zecTx the ZEC transaction data
  /// @param blockHeight block height of the transaction
  /// @param nodes Merkle proof nodes
  /// @param index index of the tx in Merkle tree
  function delegate(bytes calldata zecTx, uint32 blockHeight, bytes32[] memory nodes, uint256 index) external;

  /// Report a staked UTXO has been spent on Zcash chain
  /// If spent before stakeDuration expires, the stake is downgraded to demand rate
  /// @param zecTx the spending ZEC transaction data
  /// @param blockHeight block height of the spending transaction
  /// @param nodes Merkle proof nodes
  /// @param index index of the tx in Merkle tree
  function reportSpent(bytes calldata zecTx, uint32 blockHeight, bytes32[] memory nodes, uint256 index) external;

  /// Prepare for new round - expire stakes whose duration has passed
  /// @param round The new round tag
  function prepare(uint256 round) external;
}
