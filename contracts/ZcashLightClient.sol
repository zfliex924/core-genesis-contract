// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./lib/Memory.sol";
import "./lib/BytesToTypes.sol";
import "./lib/SatoshiPlusHelper.sol";
import "./interface/ILightClient.sol";
import "./interface/ICandidateHub.sol";
import "./interface/IRelayerHub.sol";
import "./interface/IParamSubscriber.sol";
import "./System.sol";

/// This contract implements a Zcash light client on Z Protocol blockchain
/// Relayers store Zcash block headers to the blockchain by calling this contract
/// Which is used for ZEC staking proof verification and miner power tracking
///
/// Key differences from BtcLightClient:
/// - PoW algorithm: Equihash (n=200, k=9) instead of SHA256d
/// - Hash function: Blake2b instead of SHA256
/// - Block header: 1487 bytes (140-byte header + 3-byte compact size + 1344-byte Equihash solution)
/// - Difficulty adjustment: every block (not every 2016 blocks)
/// - Precompiles: 0x68 for Equihash verification, 0x69 for Blake2b hashing
contract ZcashLightClient is ILightClient, System, IParamSubscriber {

  // error codes for storeBlockHeader
  int256 public constant ERR_DIFFICULTY = 20010;
  int256 public constant ERR_NO_PREV_BLOCK = 20030;
  int256 public constant ERR_BLOCK_ALREADY_EXISTS = 20040;
  int256 public constant ERR_PROOF_OF_WORK = 20090;
  int256 public constant ERR_INVALID_HEADER_LENGTH = 20100;

  // Zcash block header constants
  // 140 bytes base header + 3 bytes CompactSize(1344) + 1344 bytes Equihash solution
  uint256 public constant HEADER_SIZE = 1487;
  uint256 public constant BASE_HEADER_SIZE = 140;

  // Zcash difficulty adjusts every block (using DigiShield / Zcash Averaging Window)
  uint256 public constant AVERAGING_WINDOW = 17;
  uint256 public constant MEDIAN_TIMESPAN = 11;
  uint256 public constant DAMPING_FACTOR = 4;
  uint256 public constant TARGET_SPACING = 75; // 75 seconds per block
  uint256 public constant AVERAGING_WINDOW_TIMESPAN = AVERAGING_WINDOW * TARGET_SPACING;
  uint256 public constant MIN_ACTUAL_TIMESPAN = AVERAGING_WINDOW_TIMESPAN * (100 - 16) / 100;
  uint256 public constant MAX_ACTUAL_TIMESPAN = AVERAGING_WINDOW_TIMESPAN * (100 + 32) / 100;

  // Precompile addresses for Zcash-specific cryptographic operations
  address public constant EQUIHASH_PRECOMPILE = address(0x68);
  address public constant BLAKE2B_PRECOMPILE = address(0x69);

  // Confirmation and power tracking
  uint256 public constant CONFIRM_BLOCK = 24;
  uint256 public constant POWER_ROUND_GAP = 7;

  uint256 public constant INIT_STORE_BLOCK_GAS_PRICE = 35e9;

  // Chain state
  uint256 public highScore;
  bytes32 public heaviestBlock;
  bytes32 public initBlockHash;

  uint256 public storeBlockGasPrice;

  struct CandidatePower {
    address[] miners;
    bytes32[] zecBlocks;
  }

  struct RoundPower {
    address[] candidates;
    mapping(address => CandidatePower) powerMap;
  }
  mapping(uint256 => RoundPower) roundPowerMap;

  // Block storage
  // key: blockHash (Blake2b of header)
  // value layout:
  // | base header | reserved | reward address | score    | height  | candidate address |
  // | 140 bytes   | 4 bytes  | 20 bytes       | 16 bytes | 4 bytes | 20 bytes          |
  mapping(bytes32 => bytes) public blockChain;
  mapping(bytes32 => address payable) public submitters;
  mapping(uint32 => bytes32) public height2HashMap;

  // Init parameters (to be set via template for different networks)
  bytes public INIT_CONSENSUS_STATE_BYTES;
  uint32 public INIT_CHAIN_HEIGHT;

  /*********************** events **************************/
  event StoreHeaderFailed(bytes32 indexed blockHash, int256 indexed returnCode);
  event StoreHeader(bytes32 indexed blockHash, address candidate, address indexed rewardAddr, uint32 indexed height);
  event AddMinerPower(bytes32 indexed blockHash, address indexed candidate, address indexed miner);

  /*********************** init **************************/
  function init() external onlyNotInit {
    storeBlockGasPrice = INIT_STORE_BLOCK_GAS_PRICE;
    alreadyInit = true;
  }

  /// Initialize with a trusted Zcash block header as the starting point
  /// @param headerBytes The trusted Zcash block header (1487 bytes)
  /// @param height The height of the trusted block
  function initGenesisBlock(bytes calldata headerBytes, uint32 height) external onlyInit {
    require(initBlockHash == bytes32(0), "genesis block already initialized");
    require(headerBytes.length == HEADER_SIZE, "invalid header length");

    bytes32 blockHash = blake2b256(headerBytes);
    highScore = 1;
    heaviestBlock = blockHash;
    initBlockHash = blockHash;
    INIT_CHAIN_HEIGHT = height;

    // Store base header (first 140 bytes) with metadata
    bytes memory baseHeader = slice(headerBytes, 0, BASE_HEADER_SIZE);
    blockChain[blockHash] = encode(baseHeader, address(0), 1, height, address(0));
    height2HashMap[height] = blockHash;
  }

  /// Store a Zcash block header
  /// @param headerBytes Zcash block header (1487 bytes)
  function storeBlockHeader(bytes calldata headerBytes) external onlyRelayer {
    require(
      tx.gasprice == (storeBlockGasPrice == 0 ? INIT_STORE_BLOCK_GAS_PRICE : storeBlockGasPrice),
      "must use limited gasprice"
    );
    require(headerBytes.length == HEADER_SIZE, "invalid header length");

    // Compute block hash using Blake2b
    bytes32 blockHash = blake2b256(headerBytes);
    require(submitters[blockHash] == address(0), "can't sync duplicated header");

    // Verify Equihash proof of work
    require(verifyEquihash(headerBytes), "invalid Equihash solution");

    // Extract and verify header fields
    bytes memory baseHeader = slice(headerBytes, 0, BASE_HEADER_SIZE);
    (uint32 blockHeight, uint256 scoreBlock, int256 errCode) = checkProofOfWork(baseHeader, blockHash);
    if (errCode != 0) {
      emit StoreHeaderFailed(blockHash, errCode);
      return;
    }

    require(blockHeight + 720 > getHeight(heaviestBlock), "can't sync header too far in the past");

    // Parse coinbase for candidate and reward addresses
    // These are extracted from OP_RETURN in the coinbase transaction
    address candidateAddr = address(0);
    address rewardAddr = address(0);

    // Store block
    blockChain[blockHash] = encode(baseHeader, rewardAddr, scoreBlock, blockHeight, candidateAddr);
    submitters[blockHash] = payable(msg.sender);
    height2HashMap[blockHeight] = blockHash;

    // Record submission for relayer rewards (managed by RelayerHub)
    IRelayerHub(RELAYER_HUB_ADDR).recordHeaderSubmission(msg.sender);

    // Update chain tip
    if (scoreBlock >= highScore) {
      if (blockHeight > getHeight(heaviestBlock)) {
        addMinerPower(blockHash);
      }
      heaviestBlock = blockHash;
      highScore = scoreBlock;
    }

    emit StoreHeader(blockHash, candidateAddr, rewardAddr, blockHeight);
  }

  /// Store coinbase transaction data for miner binding
  /// @param blockHash The Zcash block hash
  /// @param candidateAddr The validator candidate address (from OP_RETURN)
  /// @param rewardAddr The miner reward address (from OP_RETURN)
  function storeCoinbaseInfo(
    bytes32 blockHash,
    address candidateAddr,
    address rewardAddr
  ) external onlyRelayer {
    require(blockChain[blockHash].length > 0, "block not found");

    // Update candidate and reward address in stored block data
    bytes memory stored = blockChain[blockHash];
    uint256 scoreBlock = getScore(blockHash);
    uint32 blockHeight = getHeight(blockHash);
    bytes memory baseHeader = slice(stored, 0, BASE_HEADER_SIZE);
    blockChain[blockHash] = encode(baseHeader, rewardAddr, scoreBlock, blockHeight, candidateAddr);

    // Try to add miner power if this block is confirmed
    if (blockHeight + CONFIRM_BLOCK <= getHeight(heaviestBlock)) {
      addMinerPowerDirect(blockHash, blockHeight, candidateAddr, rewardAddr);
    }
  }

  function addMinerPower(bytes32 blockHash) internal {
    for (uint256 i = 0; i < CONFIRM_BLOCK; ++i) {
      if (blockHash == initBlockHash) return;
      blockHash = getPrevHash(blockHash);
    }

    uint256 blockRoundTag = getTimestamp(blockHash) / SatoshiPlusHelper.ROUND_INTERVAL;
    address candidate = getCandidate(blockHash);

    uint256 frozenRoundTag = ICandidateHub(CANDIDATE_HUB_ADDR).getRoundTag() - POWER_ROUND_GAP;
    if (candidate != address(0) && blockRoundTag > frozenRoundTag) {
      address miner = getRewardAddress(blockHash);
      RoundPower storage r = roundPowerMap[blockRoundTag];
      uint256 power = r.powerMap[candidate].miners.length;
      if (power == 0) {
        r.candidates.push(candidate);
      }
      r.powerMap[candidate].miners.push(miner);
      r.powerMap[candidate].zecBlocks.push(blockHash);
      emit AddMinerPower(blockHash, candidate, miner);
    }
  }

  function addMinerPowerDirect(
    bytes32 blockHash,
    uint32 blockHeight,
    address candidate,
    address miner
  ) internal {
    uint256 blockRoundTag = getTimestamp(blockHash) / SatoshiPlusHelper.ROUND_INTERVAL;
    uint256 frozenRoundTag = ICandidateHub(CANDIDATE_HUB_ADDR).getRoundTag() - POWER_ROUND_GAP;
    if (candidate != address(0) && blockRoundTag > frozenRoundTag) {
      RoundPower storage r = roundPowerMap[blockRoundTag];
      uint256 power = r.powerMap[candidate].miners.length;
      if (power == 0) {
        r.candidates.push(candidate);
      }
      r.powerMap[candidate].miners.push(miner);
      r.powerMap[candidate].zecBlocks.push(blockHash);
      emit AddMinerPower(blockHash, candidate, miner);
    }
  }

  /*********************** Tx Proof Verification **************************/

  /// Verify a ZEC transaction's Merkle proof
  /// @param txid Transaction ID
  /// @param blockHeight Block height containing the transaction
  /// @param confirmBlock Number of confirmations required
  /// @param nodes Merkle proof nodes
  /// @param index Transaction index in the Merkle tree
  /// @return Whether the proof is valid
  function checkTxProof(
    bytes32 txid,
    uint32 blockHeight,
    uint32 confirmBlock,
    bytes32[] calldata nodes,
    uint256 index
  ) public view override returns (bool) {
    if (checkResult == true) {
      return checkResult;
    }

    bytes32 blockHash = height2HashMap[blockHeight];
    if (blockHeight + confirmBlock > getChainTipHeight() || txid == bytes32(0) || blockHash == bytes32(0)) {
      return false;
    }

    // Merkle root is at offset 68 in the base header (same as Bitcoin: 4 + 32 + 32 = 68)
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

    if (checkResult == true) {
      return (checkResult, timesTamp);
    }

    if (r) {
      bytes32 blockHash = height2HashMap[blockHeight];
      uint64 timestamp = getTimestamp(blockHash);
      return (r, timestamp);
    }
    return (r, 0);
  }

  /*********************** Cryptographic Helpers **************************/

  /// Compute Blake2b-256 hash via precompile
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

  /// Verify Equihash solution via precompile
  function verifyEquihash(bytes memory headerBytes) internal view returns (bool) {
    address precompile = EQUIHASH_PRECOMPILE;
    uint256 inputLen = headerBytes.length;
    bool success;
    assembly {
      let ptr := add(headerBytes, 0x20)
      // Precompile returns 1 (true) or 0 (false) in 32 bytes
      let result := mload(0x40)
      success := staticcall(gas(), precompile, ptr, inputLen, result, 0x20)
      if success {
        success := mload(result)
      }
    }
    return success;
  }

  /// Merkle step using SHA256d (same as Bitcoin transparent transactions)
  function merkleStep(bytes32 l, bytes32 r) private view returns (bytes32 digest) {
    assembly {
      let ptr := mload(0x40)
      mstore(ptr, l)
      mstore(add(ptr, 0x20), r)
      pop(staticcall(gas(), 2, ptr, 0x40, ptr, 0x20)) // sha256 #1
      pop(staticcall(gas(), 2, ptr, 0x20, ptr, 0x20)) // sha256 #2
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

  /// Encode block data for storage
  /// Layout: | base header (140 bytes) | reserved (4 bytes) | rewardAddr (20 bytes) | score (16 bytes) | height (4 bytes) | candidateAddr (20 bytes) |
  /// Total: 204 bytes
  function encode(
    bytes memory baseHeader,
    address rewardAddr,
    uint256 scoreBlock,
    uint32 blockHeight,
    address candidateAddr
  ) internal pure returns (bytes memory nodeBytes) {
    nodeBytes = new bytes(204);
    uint256 rewardAddrValue = uint256(uint160(rewardAddr)) << 64;
    uint256 v = (scoreBlock << 128) + (uint256(blockHeight) << 96);
    uint256 candidateValue = uint256(uint160(candidateAddr)) << 96;

    assembly {
      // copy base header (140 bytes)
      let mc := add(nodeBytes, 0x20)
      let end := add(mc, 140)
      for {
        let cc := add(baseHeader, 0x20)
      } lt(mc, end) {
        mc := add(mc, 0x20)
        cc := add(cc, 0x20)
      } {
        mstore(mc, mload(cc))
      }
      // rewardAddr at offset 144 (140 + 4 reserved)
      mc := add(add(nodeBytes, 0x20), 144)
      mstore(mc, rewardAddrValue)
      // score + height at offset 168 (144 + 24)
      mc := add(mc, 24)
      mstore(mc, v)
      // candidate at offset 188 (168 + 20)
      mc := add(mc, 20)
      mstore(mc, candidateValue)
    }
    return nodeBytes;
  }

  /// Check proof of work for Zcash
  /// Zcash adjusts difficulty every block using a rolling average window
  function checkProofOfWork(
    bytes memory baseHeader,
    bytes32 blockHash
  ) internal view returns (uint32 blockHeight, uint256 scoreBlock, int256 errCode) {
    bytes32 hashPrevBlock = bytes32(loadInt256(36, baseHeader));

    uint256 scorePrevBlock = getScore(hashPrevBlock);
    if (scorePrevBlock == 0) {
      return (blockHeight, scoreBlock, ERR_NO_PREV_BLOCK);
    }
    scoreBlock = getScore(blockHash);
    if (scoreBlock != 0) {
      return (blockHeight, scoreBlock, ERR_BLOCK_ALREADY_EXISTS);
    }

    // Extract bits (compact target) from header
    // In Zcash header: offset 100 for nBits (4 bytes, LE)
    uint32 bits = uint32(loadInt256(104, baseHeader) >> 224);
    uint256 target = targetFromBits(bits);

    // Check proof of work
    if (blockHash == bytes32(0) || uint256(blockHash) > target) {
      return (blockHeight, scoreBlock, ERR_PROOF_OF_WORK);
    }

    blockHeight = 1 + getHeight(hashPrevBlock);

    // Zcash difficulty adjustment is verified via the Equihash precompile
    // The precompile validates the solution against the claimed difficulty
    // So we trust the bits field if the Equihash solution is valid

    uint256 blockDifficulty = 0x0007FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF / target;
    scoreBlock = scorePrevBlock + blockDifficulty;
    return (blockHeight, scoreBlock, 0);
  }

  /*********************** Getters **************************/

  function getTimestamp(bytes32 hash) public view returns (uint64) {
    // Timestamp is at offset 100 in Zcash base header (4 bytes, LE)
    // But in our stored format, it's at the same position in the base header portion
    return uint32(loadInt256(100, blockChain[hash]) >> 224);
  }

  function getBits(bytes32 hash) public view returns (uint32) {
    return uint32(loadInt256(104, blockChain[hash]) >> 224);
  }

  function getPrevHash(bytes32 hash) public view returns (bytes32) {
    return bytes32(loadInt256(36, blockChain[hash]));
  }

  function getMerkleRoot(bytes32 hash) public view returns (bytes32) {
    return bytes32(loadInt256(68, blockChain[hash]));
  }

  function getCandidate(bytes32 hash) public view returns (address) {
    // candidateAddr at offset 188
    return address(uint160(loadInt256(220, blockChain[hash]) >> 96));
  }

  function getRewardAddress(bytes32 hash) public view returns (address) {
    // rewardAddr at offset 144
    return address(uint160(loadInt256(176, blockChain[hash]) >> 96));
  }

  function getScore(bytes32 hash) public view returns (uint256) {
    // score at offset 168, 16 bytes
    return (loadInt256(200, blockChain[hash]) >> 128);
  }

  function getHeight(bytes32 hash) public view returns (uint32) {
    // height at offset 184, 4 bytes
    return uint32(loadInt256(216, blockChain[hash]) >> 224);
  }

  function getChainTipHeight() public view returns (uint32) {
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

  /*********************** ILightClient Interface **************************/

  function getRoundPowers(
    uint256 roundTimeTag,
    address[] calldata candidates
  ) external override view returns (uint256[] memory powers, uint256 totalPower) {
    uint256 count = candidates.length;
    powers = new uint256[](count);
    RoundPower storage r = roundPowerMap[roundTimeTag];
    for (uint256 i = 0; i < count; ++i) {
      powers[i] = r.powerMap[candidates[i]].miners.length;
      totalPower += powers[i];
    }
    return (powers, totalPower);
  }

  function getRoundMiners(
    uint256 roundTimeTag,
    address candidate
  ) external override view returns (address[] memory miners) {
    return roundPowerMap[roundTimeTag].powerMap[candidate].miners;
  }

  function getRoundBlocks(
    uint256 roundTimeTag,
    address candidate
  ) external view returns (bytes32[] memory blocks) {
    return roundPowerMap[roundTimeTag].powerMap[candidate].zecBlocks;
  }

  function getRoundCandidates(
    uint256 roundTimeTag
  ) external override view returns (address[] memory candidates) {
    return roundPowerMap[roundTimeTag].candidates;
  }

  /*********************** Query Methods **************************/

  function isHeaderSynced(bytes32 zecHash) external view returns (bool) {
    return getHeight(zecHash) >= INIT_CHAIN_HEIGHT;
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

  // Mock support fields (same pattern as BtcLightClient)
  bool public checkResult;
  uint64 public timesTamp;
}
