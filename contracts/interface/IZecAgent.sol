// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

interface IZecAgent {
  /// Delegate ZEC to Z Protocol using CLTV locked output
  /// @param zecTx the ZEC transaction data
  /// @param blockHeight block height of the transaction
  /// @param nodes Merkle proof nodes
  /// @param index index of the tx in Merkle tree
  /// @param script redeem script of the CLTV locked output
  function delegate(bytes calldata zecTx, uint32 blockHeight, bytes32[] memory nodes, uint256 index, bytes memory script) external;

  /// Prepare for new round - expire stakes whose lockTime has passed
  /// @param round The new round tag
  function prepare(uint256 round) external;
}
