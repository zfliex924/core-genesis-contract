// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.24;

import "./interface/IAgent.sol";
import "./interface/IHashPowerAgent.sol";
import "./interface/ICandidateHub.sol";
import "./interface/ILightClient.sol";
import "./interface/IParamSubscriber.sol";
import "./interface/IRelayerHub.sol";
import "./lib/BitcoinHelper.sol";
import "./lib/SatoshiPlusHelper.sol";
import "./lib/TypedMemView.sol";
import "./System.sol";

/// This contract handles Zcash hash power staking (measured in ZEC blocks).
///
/// Block headers themselves live in ZcashLightClient. Relayers report each
/// block's coinbase here via submitCoinbase. When a block reaches
/// CONFIRM_BLOCK confirmations on the heaviest chain its miner power is
/// credited to the candidate's bucket for the round derived from the block's
/// timestamp.
///
/// Rewards are distributed proportionally to *bound* miners only. The share of
/// rewards corresponding to unbound miner power (blocks that submitted
/// coinbase pointing to non-elected candidates, or blocks whose coinbase was
/// never submitted) is returned as undistributed (burned by StakeHub).
contract HashPowerAgent is IAgent, IHashPowerAgent, System, IParamSubscriber {

  using BitcoinHelper for bytes;
  using BitcoinHelper for bytes29;
  using TypedMemView for bytes29;

  uint256 public constant CONFIRM_BLOCK = 24;
  uint256 public constant POWER_ROUND_GAP = 3;
  // Coinbase OP_RETURN payload layout:
  //   <magic (4)> <version (1)> <candidateId (4)> <miner (20)>  = 29 bytes
  uint256 internal constant COINBASE_PAYLOAD_SIZE = 29;
  uint32 internal constant COINBASE_VERSION = 1;

  // delegator → claimable reward
  mapping(address => uint256) public rewardMap;

  // Power totals captured at the end of each getStakeAmounts call so that
  // distributeReward can scale per-validator rewards by the bound/total ratio.
  // stakedRoundAmount sums miner counts across the candidates passed in
  // (= the valid candidates for the round). totalRoundAmount sums across ALL
  // candidates that submitted in the round, including non-elected ones.
  uint256 public stakedRoundAmount;
  uint256 public totalRoundAmount;

  struct CoinbaseInfo {
    bool submitted;       // proof has been verified for this block
    bool credited;        // miner power has been added to roundPowerMap
    address candidate;    // address(0) if the coinbase has no SAT+ binding
    address miner;        // address(0) if the coinbase has no SAT+ binding
  }
  // ZEC blockHash → submitted coinbase info
  mapping(bytes32 => CoinbaseInfo) public coinbaseMap;

  struct CandidatePower {
    address[] miners;
    bytes32[] zecBlocks;
  }

  struct RoundPower {
    // total ZEC blocks credited to this round (bound + unbound). Used as the
    // denominator when scaling rewards down by the bound/total ratio.
    uint256 blockCount;
    address[] candidates;
    mapping(address => CandidatePower) powerMap;
  }
  mapping(uint256 => RoundPower) roundPowerMap;

  /*********************** events **************************/
  event claimedHashReward(address indexed delegator, uint256 amount);
  event validatorAvgReward(address indexed validator, uint256 avgReward);
  event coinbaseSubmitted(bytes32 indexed blockHash, address indexed candidate, address indexed miner);
  event minerPowerCredited(bytes32 indexed blockHash, address indexed candidate, address indexed miner);

  /*********************** Init ********************************/
  function init() external onlyNotInit {
    alreadyInit = true;
  }

  /*********************** Coinbase tracking ********************************/

  /// Relayer submits a Zcash block's coinbase transaction together with a
  /// Merkle proof from the coinbase txid up to that block's merkle root. The
  /// proof binds the supplied bytes to the stored block, the vin check binds
  /// the bytes to a real coinbase, and the OP_RETURN payload tells us which
  /// candidate operator and miner reward address this block belongs to — so
  /// the relayer cannot fabricate the binding.
  ///
  /// If the block already has CONFIRM_BLOCK confirmations on the heaviest
  /// chain the miner is credited immediately; otherwise it will be credited
  /// later by onNewTip when the chain extends past it.
  function submitCoinbase(
    bytes calldata coinbaseTx,
    uint32 blockHeight,
    bytes32[] calldata nodes
  ) external override onlyRelayer {
    // Parse the transaction once; reuse the struct for txid computation and payload inspection.
    BitcoinHelper.ZcashTx memory parsedTx = coinbaseTx.extractTx();

    // Coinbase is the first transaction in the block, so the merkle leaf index is fixed to 0.
    bytes32 txid = BitcoinHelper.calculateTxId(parsedTx);
    require(
      ILightClient(ZEC_LIGHT_CLIENT_ADDR).checkTxProof(txid, blockHeight, 0, nodes, 0),
      "coinbase proof failed"
    );

    bytes32 blockHash = ILightClient(ZEC_LIGHT_CLIENT_ADDR).height2HashMap(blockHeight);
    require(!coinbaseMap[blockHash].submitted, "coinbase already submitted");

    require(_isCoinbaseVin(parsedTx.vinView), "not a coinbase tx");

    // Coinbases without a SAT+ OP_RETURN are still recorded so a relayer can
    // mark a block as processed exactly once; they simply contribute no miner
    // power and never get credited.
    (uint32 candidateId, address miner) = _parseCoinbasePayload(parsedTx.voutView);
    address candidate;
    if (miner != address(0)) {
      candidate = _resolveCandidate(candidateId);
    }

    coinbaseMap[blockHash] = CoinbaseInfo({
      submitted: true,
      credited: false,
      candidate: candidate,
      miner: miner
    });
    emit coinbaseSubmitted(blockHash, candidate, miner);

    if (blockHeight + CONFIRM_BLOCK <= ILightClient(ZEC_LIGHT_CLIENT_ADDR).getChainTipHeight()) {
      _credit(blockHash);
    }

    // Reward all valid coinbase submissions, including unbound blocks (no SAT+
    // OP_RETURN), because they still increment r.blockCount and keep the
    // bound/total ratio accurate for reward scaling in distributeReward.
    IRelayerHub(RELAYER_HUB_ADDR).recordCoinbaseSubmission(msg.sender);
  }

  /// A Bitcoin/Zcash coinbase transaction has exactly one input whose outpoint
  /// is the all-zero txid with output index 0xFFFFFFFF.
  function _isCoinbaseVin(bytes29 vinView) internal pure returns (bool) {
    if (uint256(vinView.indexCompactInt(0)) != 1) return false;
    bytes29 input = vinView.indexVin(0);
    bytes29 outpoint = input.outpoint();
    if (outpoint.index(0, 32) != bytes32(0)) return false;
    return outpoint.outpointIdx() == 0xFFFFFFFF;
  }

  /// Scan the coinbase outputs for the SAT+ OP_RETURN payload that binds this
  /// block to a (candidateId, miner) pair. Returns zero values if no matching
  /// payload is present — most Zcash blocks aren't mined for Z Protocol and
  /// therefore won't have one.
  function _parseCoinbasePayload(bytes29 voutView) internal pure returns (uint32 candidateId, address miner) {
    uint256 nOuts = uint256(voutView.indexCompactInt(0));
    for (uint256 i = 0; i < nOuts; ++i) {
      bytes29 output = voutView.indexVout(i);
      bytes29 skp = output.scriptPubkeyWithLength();
      bytes29 payload = skp.opReturnPayload();
      if (payload == TypedMemView.NULL) continue;
      if (payload.len() < COINBASE_PAYLOAD_SIZE) continue;
      if (payload.indexUint(0, 4) != SatoshiPlusHelper.SATOSHI_MAGIC) continue;
      uint32 version = uint32(payload.indexUint(4, 1));
      if (version != COINBASE_VERSION) continue;
      candidateId = uint32(payload.indexUint(5, 4));
      miner = payload.indexAddress(9);
      return (candidateId, miner);
    }
    return (0, address(0));
  }

  /// Resolve candidateId to operator address via CandidateHub.idMap. Returns
  /// address(0) for unknown ids so the surrounding submitCoinbase call can
  /// still mark the block as processed instead of reverting.
  function _resolveCandidate(uint32 candidateId) internal view returns (address candidate) {
    (bool ok, bytes memory data) = CANDIDATE_HUB_ADDR.staticcall(
      abi.encodeWithSignature("idMap(uint32)", candidateId)
    );
    if (!ok || data.length != 32) return address(0);
    candidate = abi.decode(data, (address));
  }

  /// Notification from ZcashLightClient that a strictly higher block extended
  /// the heaviest chain. We walk CONFIRM_BLOCK back from the new tip and try
  /// to credit that older block.
  function onNewTip(bytes32 newTipHash) external override onlyCaller(ZEC_LIGHT_CLIENT_ADDR) {
    bytes32 initHash = ILightClient(ZEC_LIGHT_CLIENT_ADDR).initBlockHash();
    bytes32 cursor = newTipHash;
    for (uint256 i = 0; i < CONFIRM_BLOCK; ++i) {
      if (cursor == initHash) return;
      cursor = ILightClient(ZEC_LIGHT_CLIENT_ADDR).getPrevHash(cursor);
    }
    _credit(cursor);
  }

  function _credit(bytes32 blockHash) internal {
    CoinbaseInfo storage info = coinbaseMap[blockHash];
    if (!info.submitted || info.credited) return;

    uint64 timestamp = ILightClient(ZEC_LIGHT_CLIENT_ADDR).getTimestamp(blockHash);
    uint256 blockRoundTag = uint256(timestamp) / SatoshiPlusHelper.ROUND_INTERVAL;
    uint256 frozenRoundTag = ICandidateHub(CANDIDATE_HUB_ADDR).getRoundTag() - POWER_ROUND_GAP;
    if (blockRoundTag <= frozenRoundTag) return;

    info.credited = true;
    RoundPower storage r = roundPowerMap[blockRoundTag];
    // Every credited block — bound or unbound — counts toward the round's
    // total block count. Only bound blocks contribute miner power.
    r.blockCount += 1;

    if (info.candidate == address(0)) return;

    if (r.powerMap[info.candidate].miners.length == 0) {
      r.candidates.push(info.candidate);
    }
    r.powerMap[info.candidate].miners.push(info.miner);
    r.powerMap[info.candidate].zecBlocks.push(blockHash);
    emit minerPowerCredited(blockHash, info.candidate, info.miner);
  }

  /*********************** IAgent implementations ***************************/

  /// Get miner power per candidate for the lookup round (current - POWER_ROUND_GAP).
  /// Side effect: caches stakedRoundAmount (sum across the passed-in candidates,
  /// i.e. the valid candidates for the round) and totalRoundAmount (every
  /// credited block in the round, bound or unbound) for the subsequent
  /// distributeReward call.
  function getStakeAmounts(
    address[] calldata candidates,
    uint256 roundTag
  ) external override onlyStakeHub returns (
    uint256[] memory amounts,
    uint256 totalAmount,
    uint256[] memory weightedAmounts,
    uint256 totalWeightedAmount
  ) {
    uint256 lookup = roundTag - POWER_ROUND_GAP;
    RoundPower storage r = roundPowerMap[lookup];
    uint256 count = candidates.length;
    amounts = new uint256[](count);

    uint256 staked;
    for (uint256 i = 0; i < count; ++i) {
      uint256 power = r.powerMap[candidates[i]].miners.length;
      amounts[i] = power;
      staked += power;
    }
    stakedRoundAmount = staked;

    totalAmount = r.blockCount;
    totalRoundAmount = totalAmount;

    weightedAmounts = amounts;
    totalWeightedAmount = totalAmount;
  }

  /// Distribute rewards to bound miners.
  /// Each miner gets: rewardList[i] / minerSize * stakedRoundAmount / totalRoundAmount.
  /// The unbound portion is returned as undistributed.
  function distributeReward(address[] calldata validators, uint256[] calldata rewardList, uint256 round) external override onlyStakeHub
    returns (uint256 undistributed)
  {
    uint256 validatorSize = validators.length;
    require(validatorSize == rewardList.length, "the length of validatorList and rewardList should be equal");

    RoundPower storage r = roundPowerMap[round - POWER_ROUND_GAP];

    for (uint256 i = 0; i < validatorSize; ++i) {
      if (rewardList[i] == 0) continue;

      address[] storage miners = r.powerMap[validators[i]].miners;
      uint256 minerSize = miners.length;
      if (minerSize == 0) {
        undistributed += rewardList[i];
        continue;
      }

      uint256 effectiveReward = rewardList[i];
      if (totalRoundAmount > 0 && stakedRoundAmount < totalRoundAmount) {
        effectiveReward = rewardList[i] * stakedRoundAmount / totalRoundAmount;
        undistributed += rewardList[i] - effectiveReward;
      }

      if (effectiveReward > 0) {
        uint256 avgReward = effectiveReward / minerSize;
        for (uint256 j = 0; j < minerSize; ++j) {
          rewardMap[miners[j]] += avgReward;
        }
        emit validatorAvgReward(validators[i], avgReward);
      }
    }
  }

  function setNewRound(address[] calldata validators, uint256 round) external override onlyStakeHub {
  }

  function claimReward(address delegator) external override onlyStakeHub returns (uint256 reward) {
    reward = rewardMap[delegator];
    if (reward != 0) {
      delete rewardMap[delegator];
      emit claimedHashReward(delegator, reward);
    }
  }

  /*********************** Public getters ***************************/

  function getRoundPowers(
    uint256 roundTimeTag,
    address[] calldata candidates
  ) external view returns (uint256[] memory powers, uint256 totalPower) {
    RoundPower storage r = roundPowerMap[roundTimeTag];
    uint256 count = candidates.length;
    powers = new uint256[](count);
    for (uint256 i = 0; i < count; ++i) {
      powers[i] = r.powerMap[candidates[i]].miners.length;
      totalPower += powers[i];
    }
  }

  function getRoundMiners(
    uint256 roundTimeTag,
    address candidate
  ) external view returns (address[] memory miners) {
    return roundPowerMap[roundTimeTag].powerMap[candidate].miners;
  }

  function getRoundBlocks(
    uint256 roundTimeTag,
    address candidate
  ) external view returns (bytes32[] memory zecBlocks) {
    return roundPowerMap[roundTimeTag].powerMap[candidate].zecBlocks;
  }

  function getRoundCandidates(
    uint256 roundTimeTag
  ) external view returns (address[] memory candidates) {
    return roundPowerMap[roundTimeTag].candidates;
  }

  /*********************** Governance ********************************/
  function updateParam(string calldata key, bytes calldata /*value*/) external override onlyInit onlyGov view {
    revert UnsupportedGovParam(key);
  }
}
