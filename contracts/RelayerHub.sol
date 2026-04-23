// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./lib/BytesToTypes.sol";
import "./lib/Memory.sol";
import "./interface/IRelayerHub.sol";
import "./interface/ISystemReward.sol";
import "./interface/IParamSubscriber.sol";
import "./System.sol";

/// This contract manages relayers and their rewards on Z Protocol blockchain
/// Relayer reward tracking is centralized here instead of being duplicated in each LightClient
contract RelayerHub is IRelayerHub, System, IParamSubscriber{
  uint256 public constant INIT_REQUIRED_DEPOSIT =  1e20;
  uint256 public constant INIT_DUES =  1e18;

  // the refundable deposit
  uint256 public requiredDeposit;
  // the unregister fee
  uint256 public dues;

  mapping(address =>Relayer) relayers;
  mapping(address =>bool) relayersExistMap;

  struct Relayer{
    uint256 deposit;
    uint256 dues;
  }

  // Relayer reward state
  // Single default rate for all three relayer task types. The three runtime
  // variables (rewardForSyncHeader / rewardForCoinbaseSubmission /
  // rewardForDelegateSubmission) are still independently governable.
  uint256 public constant INIT_REWARD = 1e18;
  uint256 public constant INIT_CALLER_COMPENSATION_MOLECULE = 50;
  uint256 public constant INIT_HEADER_ROUND_SIZE = 100;
  uint256 public constant INIT_SUBMISSION_ROUND_SIZE = 20;
  uint256 public constant INIT_MAXIMUM_WEIGHT = 20;

  uint256 public rewardForSyncHeader;
  uint256 public rewardForCoinbaseSubmission;
  uint256 public rewardForDelegateSubmission;
  uint256 public callerCompensationMolecule;
  uint256 public maxWeight;

  // Per-pool accumulator. Header submissions and user-action submissions
  // (coinbase + delegate) accumulate and distribute independently because
  // header throughput is much higher than user-action throughput.
  struct RewardPool {
    uint256 collected;
    uint256 countInRound;
    uint256 roundSize;
    address payable[] addressRecord;
    mapping(address => uint256) submitCount;
  }
  RewardPool internal headerPool;       // recordHeaderSubmission
  RewardPool internal submissionPool;   // recordCoinbaseSubmission + recordDelegateSubmission

  mapping(address => uint256) public relayerRewardVault;

  modifier noExist() {
    require(!relayersExistMap[msg.sender], "relayer already exists");
    _;
  }

  modifier exist() {
    require(relayersExistMap[msg.sender], "relayer does not exist");
    _;
  }

  modifier noProxy() {
    require(msg.sender == tx.origin, "no proxy is allowed");
    _;
  }

  event relayerRegister(address indexed relayer);
  event relayerUnRegister(address indexed relayer);

  function init() external onlyNotInit{
    requiredDeposit = INIT_REQUIRED_DEPOSIT;
    dues = INIT_DUES;
    rewardForSyncHeader = INIT_REWARD;
    rewardForCoinbaseSubmission = INIT_REWARD;
    rewardForDelegateSubmission = INIT_REWARD;
    callerCompensationMolecule = INIT_CALLER_COMPENSATION_MOLECULE;
    headerPool.roundSize = INIT_HEADER_ROUND_SIZE;
    submissionPool.roundSize = INIT_SUBMISSION_ROUND_SIZE;
    maxWeight = INIT_MAXIMUM_WEIGHT;
    alreadyInit = true;
  }

  /// Register as a relayer on Z Protocol blockchain
  function register() external payable noExist onlyInit noProxy{
    require(msg.value == requiredDeposit, "deposit value does not match requirement");
    relayers[msg.sender] = Relayer(requiredDeposit, dues);
    relayersExistMap[msg.sender] = true;
    emit relayerRegister(msg.sender);
  }

  /// Unregister the relayer role
  function  unregister() external exist onlyInit{
    Relayer memory r = relayers[msg.sender];
    delete relayersExistMap[msg.sender];
    delete relayers[msg.sender];
    payable(msg.sender).transfer(r.deposit - r.dues);
    payable(SYSTEM_REWARD_ADDR).transfer(r.dues);
    emit relayerUnRegister(msg.sender);
  }

  /*********************** Relayer Reward Management ********************************/

  /// Record a header submission, called by ZcashLightClient.
  function recordHeaderSubmission(address relayer) external override onlyCaller(ZEC_LIGHT_CLIENT_ADDR) {
    _recordSubmission(headerPool, relayer, rewardForSyncHeader);
  }

  /// Record a coinbase submission, called by HashPowerAgent.
  function recordCoinbaseSubmission(address relayer) external override onlyCaller(HASH_AGENT_ADDR) {
    _recordSubmission(submissionPool, relayer, rewardForCoinbaseSubmission);
  }

  /// Record a ZEC delegate submission, called by ZecAgent.
  function recordDelegateSubmission(address relayer) external override onlyCaller(ZEC_AGENT_ADDR) {
    _recordSubmission(submissionPool, relayer, rewardForDelegateSubmission);
  }

  /// Accumulate `reward` for `relayer` into `pool` and trigger that pool's
  /// distribution when its countInRound reaches roundSize. The caller of the
  /// boundary submission receives the caller-compensation cut.
  function _recordSubmission(RewardPool storage pool, address relayer, uint256 reward) internal {
    pool.collected += reward;
    if (pool.submitCount[relayer] == 0) {
      pool.addressRecord.push(payable(relayer));
    }
    pool.submitCount[relayer]++;
    if (++pool.countInRound >= pool.roundSize) {
      uint256 callerReward = _distributeRelayerReward(pool);
      relayerRewardVault[relayer] += callerReward;
      pool.countInRound = 0;
    }
  }

  /// Claim accumulated relayer rewards
  /// @param relayer The relayer address to claim for
  function claimRelayerReward(address relayer) external override onlyInit {
    uint256 reward = relayerRewardVault[relayer];
    require(reward != 0, "no relayer reward");
    address payable recipient = payable(relayer);
    uint256 actualAmount = ISystemReward(SYSTEM_REWARD_ADDR).claimRewards(recipient, reward);
    relayerRewardVault[relayer] -= actualAmount;
  }

  /// Distribute the accumulated rewards in `pool` to its participating
  /// relayers and reset the pool's per-round state.
  /// Any precision loss (dust) from integer division during distribution
  /// is allocated to the first relayer of the round as a first-mover bonus.
  /// @return The caller compensation reward
  function _distributeRelayerReward(RewardPool storage pool) internal returns (uint256) {
    uint256 totalReward = pool.collected;
    uint256 totalWeight = 0;
    address payable[] memory _relayers = pool.addressRecord;
    uint256 relayerSize = _relayers.length;
    uint256[] memory relayerWeight = new uint256[](relayerSize);
    for (uint256 index = 0; index < relayerSize; index++) {
      uint256 weight = calculateRelayerWeight(pool.submitCount[_relayers[index]]);
      relayerWeight[index] = weight;
      totalWeight += weight;
    }

    // 1. Deduct the compensation for the boundary caller first
    uint256 callerReward = totalReward * callerCompensationMolecule / 10000;
    totalReward -= callerReward;
    uint256 remainReward = totalReward;

    // 2. Distribute rewards proportionally to relayers from index 1
    for (uint256 index = 1; index < relayerSize; index++) {
      uint256 reward = relayerWeight[index] * totalReward / totalWeight;
      relayerRewardVault[_relayers[index]] += reward;
      remainReward -= reward;
    }

    // 3. Allocate the first relayer's exact share PLUS any division dust.
    // _relayers[0] is the first submitter of this round, acting as the dust collector.
    relayerRewardVault[_relayers[0]] += remainReward;

    pool.collected = 0;
    for (uint256 index = 0; index < relayerSize; index++) {
      delete pool.submitCount[_relayers[index]];
    }
    delete pool.addressRecord;
    return callerReward;
  }

  /*********************** Pool view helpers ********************************/

  function getHeaderPoolState() external view returns (uint256 collected, uint256 countInRound, uint256 roundSize) {
    return (headerPool.collected, headerPool.countInRound, headerPool.roundSize);
  }

  function getSubmissionPoolState() external view returns (uint256 collected, uint256 countInRound, uint256 roundSize) {
    return (submissionPool.collected, submissionPool.countInRound, submissionPool.roundSize);
  }

  function getHeaderPoolSubmitCount(address relayer) external view returns (uint256) {
    return headerPool.submitCount[relayer];
  }

  function getSubmissionPoolSubmitCount(address relayer) external view returns (uint256) {
    return submissionPool.submitCount[relayer];
  }

  /// Compute a relayer's distribution weight from their submission count
  /// within the current pool round. Shared across all three task types
  /// (header / coinbase / delegate). The piecewise curve rewards consistent
  /// participation while penalising hyperactive relayers, so a single
  /// relayer cannot monopolise the pool by spamming submissions:
  ///   count ∈ [0, maxWeight]              → weight = count                (linear)
  ///   count ∈ (maxWeight, 2·maxWeight]    → weight = maxWeight             (capped)
  ///   count ∈ (2·maxWeight, 2.75·maxWeight] → weight = 3·maxWeight − count (decay)
  ///   count > 2.75·maxWeight              → weight = count / 4             (penalised)
  /// @param count Submissions made by the relayer in this round
  /// @return The relayer's weight used to split the round's reward pool
  function calculateRelayerWeight(uint256 count) public view returns (uint256) {
    if (count <= maxWeight) {
      return count;
    } else if (maxWeight < count && count <= 2 * maxWeight) {
      return maxWeight;
    } else if (2 * maxWeight < count && count <= (2 * maxWeight + 3 * maxWeight / 4)) {
      return 3 * maxWeight - count;
    } else {
      return count >= 4 ? count / 4 : 1;
    }
  }

  /*********************** Param update ********************************/
  /// Update parameters through governance vote
  /// @param key The name of the parameter
  /// @param value the new value set to the parameter
  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov{
    if (Memory.compareStrings(key,"requiredDeposit")) {
      require(value.length == 32, "length of requiredDeposit mismatch");
      uint256 newRequiredDeposit = BytesToTypes.bytesToUint256(32, value);
      require(newRequiredDeposit > dues, "the requiredDeposit out of range");
      requiredDeposit = newRequiredDeposit;
    } else if (Memory.compareStrings(key,"dues")) {
      require(value.length == 32, "length of dues mismatch");
      uint256 newDues = BytesToTypes.bytesToUint256(32, value);
      require(newDues > 0 && newDues < requiredDeposit, "the dues out of range");
      dues = newDues;
    } else if (Memory.compareStrings(key,"rewardForSyncHeader")) {
      require(value.length == 32, "length of rewardForSyncHeader mismatch");
      uint256 newRewardForSyncHeader = BytesToTypes.bytesToUint256(32, value);
      require(newRewardForSyncHeader > 0 && newRewardForSyncHeader <= 1e20, "the rewardForSyncHeader out of range");
      rewardForSyncHeader = newRewardForSyncHeader;
    } else if (Memory.compareStrings(key,"rewardForCoinbaseSubmission")) {
      require(value.length == 32, "length of rewardForCoinbaseSubmission mismatch");
      uint256 newReward = BytesToTypes.bytesToUint256(32, value);
      require(newReward > 0 && newReward <= 1e20, "the rewardForCoinbaseSubmission out of range");
      rewardForCoinbaseSubmission = newReward;
    } else if (Memory.compareStrings(key,"rewardForDelegateSubmission")) {
      require(value.length == 32, "length of rewardForDelegateSubmission mismatch");
      uint256 newReward = BytesToTypes.bytesToUint256(32, value);
      require(newReward > 0 && newReward <= 1e20, "the rewardForDelegateSubmission out of range");
      rewardForDelegateSubmission = newReward;
    } else if (Memory.compareStrings(key,"callerCompensationMolecule")) {
      require(value.length == 32, "length of callerCompensationMolecule mismatch");
      uint256 newCallerCompensationMolecule = BytesToTypes.bytesToUint256(32, value);
      require(newCallerCompensationMolecule <= 10000, "the callerCompensationMolecule out of range");
      callerCompensationMolecule = newCallerCompensationMolecule;
    } else if (Memory.compareStrings(key,"headerRoundSize")) {
      require(value.length == 32, "length of headerRoundSize mismatch");
      uint256 newRoundSize = BytesToTypes.bytesToUint256(32, value);
      require(newRoundSize >= maxWeight, "the headerRoundSize out of range");
      headerPool.roundSize = newRoundSize;
    } else if (Memory.compareStrings(key,"submissionRoundSize")) {
      require(value.length == 32, "length of submissionRoundSize mismatch");
      uint256 newRoundSize = BytesToTypes.bytesToUint256(32, value);
      require(newRoundSize >= maxWeight, "the submissionRoundSize out of range");
      submissionPool.roundSize = newRoundSize;
    } else if (Memory.compareStrings(key,"maxWeight")) {
      require(value.length == 32, "length of maxWeight mismatch");
      uint256 newMaxWeight = BytesToTypes.bytesToUint256(32, value);
      require(newMaxWeight > 0 && newMaxWeight <= headerPool.roundSize && newMaxWeight <= submissionPool.roundSize, "the maxWeight out of range");
      maxWeight = newMaxWeight;
    } else {
      revert UnsupportedGovParam(key);
    }
    emit paramChange(key, value);
  }

  /// Whether the input address is a relayer
  /// @param sender The address to check
  /// @return true/false
  function isRelayer(address sender) external override view returns (bool) {
    return relayersExistMap[sender];
  }
}
