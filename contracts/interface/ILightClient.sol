// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.24;

interface ILightClient {
  function checkTxProof(bytes32 txid, uint32 blockHeight, uint32 confirmBlock, bytes32[] calldata nodes, uint256 index) external view returns (bool);

  function checkTxProofAndGetTime(bytes32 txid, uint32 blockHeight, uint32 confirmBlock, bytes32[] calldata nodes, uint256 index) external view returns (bool, uint64);

  function getPrevHash(bytes32 hash) external view returns (bytes32);

  function getHeight(bytes32 hash) external view returns (uint32);

  function getTimestamp(bytes32 hash) external view returns (uint64);

  function getChainTipHeight() external view returns (uint32);

  function initBlockHash() external view returns (bytes32);

  function height2HashMap(uint32 blockHeight) external view returns (bytes32);
}
