// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

interface IHashPowerAgent {
  /// Submit the coinbase transaction of a Zcash block, with a Merkle proof
  /// proving it was included at index 0 of the block referenced by blockHeight.
  /// The coinbase's OP_RETURN payload binds the block to a candidate operator
  /// and a miner reward (EVM) address.
  /// @param coinbaseTx the raw coinbase transaction bytes
  /// @param blockHeight Zcash block height containing this coinbase
  /// @param nodes Merkle proof from the coinbase txid up to the block's merkle root
  function submitCoinbase(bytes calldata coinbaseTx, uint32 blockHeight, bytes32[] calldata nodes) external;

  /// Notification from ZcashLightClient when a strictly higher block extends
  /// the heaviest chain. The agent walks CONFIRM_BLOCK back from the new tip
  /// and credits that older block's miner power if its coinbase was already
  /// submitted.
  function onNewTip(bytes32 blockHash) external;
}
