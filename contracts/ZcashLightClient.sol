// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.24;

import "./lib/Memory.sol";
import "./lib/BytesToTypes.sol";
import "./interface/ILightClient.sol";
import "./interface/IHashPowerAgent.sol";
import "./interface/IRelayerHub.sol";
import "./interface/IParamSubscriber.sol";
import "./System.sol";

/// This contract implements a Zcash light client on Z Protocol blockchain.
/// Relayers store Zcash block headers here so they can be used as proofs by
/// ZEC staking and so that miner power can be tracked by HashPowerAgent.
/// Coinbase / miner-power bookkeeping lives in HashPowerAgent; this contract
/// only stores headers, validates PoW, and notifies HashPowerAgent when the
/// heaviest chain extends.
contract ZcashLightClient is ILightClient, System, IParamSubscriber {

  // error codes for storeBlockHeader
  int256 public constant ERR_DIFFICULTY = 20010;
  int256 public constant ERR_NO_PREV_BLOCK = 20030;
  int256 public constant ERR_BLOCK_ALREADY_EXISTS = 20040;
  int256 public constant ERR_PROOF_OF_WORK = 20090;
  int256 public constant ERR_INVALID_HEADER_LENGTH = 20100;

  // Zcash block header constants
  uint256 public constant HEADER_SIZE = 1487;
  uint256 public constant BASE_HEADER_SIZE = 140;

  // Encoded record layout: [baseHeader (140) | packed (32)]
  // packed = (scoreBlock << 128) | (uint256(blockHeight) << 96)
  uint256 internal constant ENCODED_SIZE = 172;

  // Zcash difficulty constants
  uint256 public constant AVERAGING_WINDOW = 17;
  uint256 public constant MEDIAN_TIMESPAN = 11;
  uint256 public constant DAMPING_FACTOR = 4;
  uint256 public constant TARGET_SPACING = 75;
  uint256 public constant AVERAGING_WINDOW_TIMESPAN = AVERAGING_WINDOW * TARGET_SPACING;
  uint256 public constant MIN_ACTUAL_TIMESPAN = AVERAGING_WINDOW_TIMESPAN * (100 - 16) / 100;
  uint256 public constant MAX_ACTUAL_TIMESPAN = AVERAGING_WINDOW_TIMESPAN * (100 + 32) / 100;

  // Precompile addresses
  address public constant BLAKE2B_PRECOMPILE = address(0x67);
  address public constant EQUIHASH_PRECOMPILE = address(0x68);

  bytes public constant INIT_CONSENSUS_STATE_BYTES = hex"0400000081f84d9b1ea6be1ca5e30cf79e0b288487276445fc20f02a20410a579bfa21fd39da26b3711bee3c7bff1ca714cd86550ed925313f8866e0ece7f3310dbae22e62cf113f5bcbab6a0436b18254daa8d46cb9d42fc0adbda76b8e9118e9a406123add4c4d0f0f0f200000000000000000000000000000000000000000000000000000000000000000fd4005000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
  uint32 public constant INIT_CHAIN_HEIGHT = 200;

  uint256 public constant INIT_STORE_BLOCK_GAS_PRICE = 35e9;

  // Chain state
  uint256 public highScore;
  bytes32 public heaviestBlock;
  bytes32 public override initBlockHash;

  uint256 public storeBlockGasPrice;

  // Block storage
  mapping(bytes32 => bytes) public blockChain;
  mapping(bytes32 => address payable) public submitters;
  mapping(uint32 => bytes32) public override height2HashMap;

  /*********************** events **************************/
  event StoreHeaderFailed(bytes32 indexed blockHash, int256 indexed returnCode);
  event StoreHeader(bytes32 indexed blockHash, uint32 indexed height);

  /*********************** init **************************/
  function init() external onlyNotInit {
    bytes32 blockHash = doubleShaFlip(INIT_CONSENSUS_STATE_BYTES);

    highScore = 1;
    heaviestBlock = blockHash;
    initBlockHash = blockHash;

    bytes memory baseHeader = slice(INIT_CONSENSUS_STATE_BYTES, 0, BASE_HEADER_SIZE);
    blockChain[blockHash] = encode(baseHeader, 1, INIT_CHAIN_HEIGHT);
    height2HashMap[INIT_CHAIN_HEIGHT] = blockHash;
    storeBlockGasPrice = INIT_STORE_BLOCK_GAS_PRICE;
    alreadyInit = true;
  }

  /// Store a Zcash block header.
  /// Coinbase / miner-power binding for this block is reported separately via
  /// HashPowerAgent.submitCoinbase; this function only stores the header and
  /// notifies the agent when the heaviest chain extends so it can credit the
  /// block that just reached CONFIRM_BLOCK confirmations.
  function storeBlockHeader(bytes calldata headerBytes) external onlyRelayer {
    require(
      tx.gasprice == (storeBlockGasPrice == 0 ? INIT_STORE_BLOCK_GAS_PRICE : storeBlockGasPrice),
      "must use limited gasprice"
    );
    require(headerBytes.length == HEADER_SIZE, "invalid header length");

    bytes32 blockHash = doubleShaFlip(headerBytes);
    require(submitters[blockHash] == address(0), "can't sync duplicated header");

    require(verifyEquihash(headerBytes), "invalid Equihash solution");

    bytes memory baseHeader = slice(headerBytes, 0, BASE_HEADER_SIZE);
    (uint32 blockHeight, uint256 scoreBlock, int256 errCode) = checkProofOfWork(baseHeader, blockHash);
    if (errCode != 0) {
      emit StoreHeaderFailed(blockHash, errCode);
      return;
    }

    require(blockHeight + 720 > getHeight(heaviestBlock), "can't sync header too far in the past");

    blockChain[blockHash] = encode(baseHeader, scoreBlock, blockHeight);
    submitters[blockHash] = payable(msg.sender);
    height2HashMap[blockHeight] = blockHash;

    IRelayerHub(RELAYER_HUB_ADDR).recordHeaderSubmission(msg.sender);

    if (scoreBlock >= highScore) {
      bool extending = blockHeight > getHeight(heaviestBlock);
      heaviestBlock = blockHash;
      highScore = scoreBlock;
      if (extending) {
        IHashPowerAgent(HASH_AGENT_ADDR).onNewTip(blockHash);
      }
    }

    emit StoreHeader(blockHash, blockHeight);
  }

  /*********************** Tx Proof Verification **************************/

  function checkTxProof(
    bytes32 txid,
    uint32 blockHeight,
    uint32 confirmBlock,
    bytes32[] calldata nodes,
    uint256 index
  ) public view override returns (bool) {
    bytes32 blockHash = height2HashMap[blockHeight];
    if (blockHeight + confirmBlock > getChainTipHeight() || txid == bytes32(0) || blockHash == bytes32(0)) {
      return false;
    }

    bytes32 root = bytes32(loadInt256(68, blockChain[blockHash]));
    if (nodes.length == 0) {
      return (txid == root);
    }

    bytes32 current = txid;
    for (uint256 i = 0; i < nodes.length; i++) {
      if (index % 2 == 1) {
        current = merkleStep(nodes[i], current);
      } else {
        current = merkleStep(current, nodes[i]);
      }
      index >>= 1;
    }
    return (current == root);
  }

  function checkTxProofAndGetTime(
    bytes32 txid,
    uint32 blockHeight,
    uint32 confirmBlock,
    bytes32[] calldata nodes,
    uint256 index
  ) external view override returns (bool, uint64) {
    bool r = checkTxProof(txid, blockHeight, confirmBlock, nodes, index);
    if (r) {
      bytes32 blockHash = height2HashMap[blockHeight];
      uint64 timestamp = getTimestamp(blockHash);
      return (r, timestamp);
    }
    return (r, 0);
  }

  /*********************** Cryptographic Helpers **************************/

  function blake2b256(bytes memory input) internal view returns (bytes32 result) {
    address precompile = BLAKE2B_PRECOMPILE;
    uint256 inputLen = input.length;
    assembly {
      let ptr := add(input, 0x20)
      if iszero(staticcall(gas(), precompile, ptr, inputLen, result, 0x20)) {
        revert(0, 0)
      }
      result := mload(result)
    }
  }

  function verifyEquihash(bytes memory headerBytes) internal view returns (bool) {
    address precompile = EQUIHASH_PRECOMPILE;
    uint256 inputLen = headerBytes.length;
    bool success;
    assembly {
      let ptr := add(headerBytes, 0x20)
      let result := mload(0x40)
      success := staticcall(gas(), precompile, ptr, inputLen, result, 0x20)
      if success {
        success := mload(result)
      }
    }
    return success;
  }

  function merkleStep(bytes32 l, bytes32 r) private view returns (bytes32 digest) {
    assembly {
      let ptr := mload(0x40)
      mstore(ptr, l)
      mstore(add(ptr, 0x20), r)
      pop(staticcall(gas(), 2, ptr, 0x40, ptr, 0x20))
      pop(staticcall(gas(), 2, ptr, 0x20, ptr, 0x20))
      digest := mload(ptr)
    }
  }

  /*********************** Block Data Encoding/Decoding **************************/

  function slice(bytes memory input, uint256 start, uint256 end) internal pure returns (bytes memory _output) {
    uint256 length = end - start;
    _output = new bytes(length);
    uint256 src = Memory.dataPtr(input);
    uint256 dest;
    assembly {
      dest := add(add(_output, 0x20), start)
    }
    Memory.copy(src, dest, length);
    return _output;
  }

  /// Pack a stored block record as: 140-byte base header followed by a
  /// 32-byte word with scoreBlock in the high 16 bytes and blockHeight in
  /// the next 4 bytes. Total size 172 bytes.
  function encode(
    bytes memory baseHeader,
    uint256 scoreBlock,
    uint32 blockHeight
  ) internal pure returns (bytes memory nodeBytes) {
    nodeBytes = new bytes(ENCODED_SIZE);
    uint256 packed = (scoreBlock << 128) | (uint256(blockHeight) << 96);
    assembly {
      // copy base header (140 bytes -> 5 * 32-byte words; the trailing
      // 20 bytes of the last word are overwritten below by the packed word)
      let dest := add(nodeBytes, 0x20)
      let src := add(baseHeader, 0x20)
      mstore(dest, mload(src))
      mstore(add(dest, 0x20), mload(add(src, 0x20)))
      mstore(add(dest, 0x40), mload(add(src, 0x40)))
      mstore(add(dest, 0x60), mload(add(src, 0x60)))
      // last 12 bytes of base header (offsets 128..140)
      let last := mload(add(src, 0x80))
      mstore(add(dest, 0x80), last)
      // overwrite from offset 140 with the packed score/height word
      mstore(add(dest, 140), packed)
    }
    return nodeBytes;
  }

  function checkProofOfWork(
    bytes memory baseHeader,
    bytes32 blockHash
  ) internal view returns (uint32 blockHeight, uint256 scoreBlock, int256 errCode) {
    bytes32 hashPrevBlock = flip32Bytes(bytes32(loadInt256(36, baseHeader)));

    uint256 scorePrevBlock = getScore(hashPrevBlock);
    if (scorePrevBlock == 0) {
      return (blockHeight, scoreBlock, ERR_NO_PREV_BLOCK);
    }
    scoreBlock = getScore(blockHash);
    if (scoreBlock != 0) {
      return (blockHeight, scoreBlock, ERR_BLOCK_ALREADY_EXISTS);
    }

    // nBits is at base-header byte offset 104; loadInt256(_offst, _input) reads
    // 32 bytes starting at memory address (_input + _offst), which is data
    // offset (_offst - 32). To read the 32-byte word starting at data offset
    // 104 we therefore pass 104 + 32 = 136.
    uint32 bits = flip4Bytes(uint32(loadInt256(136, baseHeader) >> 224));
    uint256 target = targetFromBits(bits);

    if (blockHash == bytes32(0) || uint256(blockHash) > target) {
      return (blockHeight, scoreBlock, ERR_PROOF_OF_WORK);
    }

    blockHeight = 1 + getHeight(hashPrevBlock);

    uint256 blockDifficulty = 0x0007FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF / target;
    scoreBlock = scorePrevBlock + blockDifficulty;
    return (blockHeight, scoreBlock, 0);
  }

  // reverse 32 bytes given by value
  function flip32Bytes(bytes32 input) internal pure returns (bytes32 v) {
    v = input;

    // swap bytes
    v = ((v & 0xFF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00) >> 8) |
        ((v & 0x00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF) << 8);

    // swap 2-byte long pairs
    v = ((v & 0xFFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000) >> 16) |
        ((v & 0x0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF) << 16);

    // swap 4-byte long pairs
    v = ((v & 0xFFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000) >> 32) |
        ((v & 0x00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF) << 32);

    // swap 8-byte long pairs
    v = ((v & 0xFFFFFFFFFFFFFFFF0000000000000000FFFFFFFFFFFFFFFF0000000000000000) >> 64) |
        ((v & 0x0000000000000000FFFFFFFFFFFFFFFF0000000000000000FFFFFFFFFFFFFFFF) << 64);

    // swap 16-byte long pairs
    v = (v >> 128) | (v << 128);
  }

  function flip4Bytes(uint32 input) internal pure returns (uint32 v) {
    v = input;
    v = ((v & 0xFF00FF00) >> 8) | ((v & 0x00FF00FF) << 8);
    v = (v >> 16) | (v << 16);
  }

  function doubleShaFlip(bytes memory dataBytes) internal pure returns (bytes32) {
    return flip32Bytes(sha256(abi.encodePacked(sha256(dataBytes))));
  }

  /*********************** Getters **************************/

  // See checkProofOfWork for the explanation of the +32 offset convention used
  // by loadInt256. nTime is at base-header offset 100, nBits at 104.
  function getTimestamp(bytes32 hash) public view override returns (uint64) {
    return flip4Bytes(uint32(loadInt256(132, blockChain[hash]) >> 224));
  }

  function getBits(bytes32 hash) public view returns (uint32) {
    return flip4Bytes(uint32(loadInt256(136, blockChain[hash]) >> 224));
  }

  function getPrevHash(bytes32 hash) public view override returns (bytes32) {
    return flip32Bytes(bytes32(loadInt256(36, blockChain[hash])));
  }

  function getMerkleRoot(bytes32 hash) public view returns (bytes32) {
    return flip32Bytes(bytes32(loadInt256(68, blockChain[hash])));
  }

  // The packed score/height word lives at data offset 140, so loadInt256 is
  // called with 140 + 32 = 172.
  function getScore(bytes32 hash) public view returns (uint256) {
    return loadInt256(172, blockChain[hash]) >> 128;
  }

  function getHeight(bytes32 hash) public view override returns (uint32) {
    bytes memory data = blockChain[hash];
    if (data.length == 0) return 0;
    return uint32(loadInt256(172, data) >> 96);
  }

  function getChainTipHeight() public view override returns (uint32) {
    return getHeight(heaviestBlock);
  }

  function targetFromBits(uint32 bits) internal pure returns (uint256 target) {
    uint32 nSize = bits >> 24;
    uint32 nWord = bits & 0x00ffffff;
    if (nSize <= 3) {
      nWord >>= 8 * (3 - nSize);
      target = nWord;
    } else {
      target = nWord;
      target <<= 8 * (nSize - 3);
    }
    return target;
  }

  function loadInt256(uint256 _offst, bytes memory _input) internal pure returns (uint256 _output) {
    assembly {
      _output := mload(add(_input, _offst))
    }
  }

  /*********************** Query Methods **************************/

  function isHeaderSynced(bytes32 zecHash) external view returns (bool) {
    return blockChain[zecHash].length > 0;
  }

  function getSubmitter(bytes32 zecHash) external view returns (address payable) {
    return submitters[zecHash];
  }

  function getChainTip() external view returns (bytes32) {
    return heaviestBlock;
  }

  /*********************** Governance **************************/

  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov {
    if (value.length != 32) {
      revert MismatchParamLength(key);
    }
    if (Memory.compareStrings(key, "storeBlockGasPrice")) {
      uint256 newStoreBlockGasPrice = BytesToTypes.bytesToUint256(32, value);
      if (newStoreBlockGasPrice < 1e9) {
        revert OutOfBounds(key, newStoreBlockGasPrice, 1e9, type(uint256).max);
      }
      storeBlockGasPrice = newStoreBlockGasPrice;
    } else {
      revert UnsupportedGovParam(key);
    }
    emit paramChange(key, value);
  }

}
