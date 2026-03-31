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
  uint256 constant public INIT_REWARD_FOR_SYNC_HEADER = 1e19;
  uint256 public constant INIT_CALLER_COMPENSATION_MOLECULE = 50;
  uint256 public constant INIT_ROUND_SIZE = 100;
  uint256 public constant INIT_MAXIMUM_WEIGHT = 20;

  uint256 public rewardForSyncHeader;
  uint256 public callerCompensationMolecule;
  uint256 public roundSize;
  uint256 public maxWeight;
  uint256 public countInRound;
  uint256 public collectedRewardForHeaderRelayer;

  address payable[] public headerRelayerAddressRecord;
  mapping(address => uint256) public headerRelayersSubmitCount;
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

  modifier onlyLightClient() {
    require(
      msg.sender == ZEC_LIGHT_CLIENT_ADDR,
      "the sender must be a light client contract"
    );
    _;
  }

  event relayerRegister(address indexed relayer);
  event relayerUnRegister(address indexed relayer);

  function init() external onlyNotInit{
    requiredDeposit = INIT_REQUIRED_DEPOSIT;
    dues = INIT_DUES;
    rewardForSyncHeader = INIT_REWARD_FOR_SYNC_HEADER;
    callerCompensationMolecule = INIT_CALLER_COMPENSATION_MOLECULE;
    roundSize = INIT_ROUND_SIZE;
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

  /// Record a header submission by a relayer, called by LightClient contracts
  /// Triggers reward distribution when round is complete
  /// @param relayer The relayer who submitted the header
  function recordHeaderSubmission(address relayer) external override onlyLightClient {
    collectedRewardForHeaderRelayer += rewardForSyncHeader;
    if (headerRelayersSubmitCount[relayer] == 0) {
      headerRelayerAddressRecord.push(payable(relayer));
    }
    headerRelayersSubmitCount[relayer]++;
    if (++countInRound >= roundSize) {
      uint256 callerHeaderReward = _distributeRelayerReward();
      relayerRewardVault[relayer] += callerHeaderReward;
      countInRound = 0;
    }
  }

  /// Claim accumulated relayer rewards
  /// @param relayer The relayer address to claim for
  function claimRelayerReward(address relayer) external override onlyInit {
    uint256 reward = relayerRewardVault[relayer];
    require(reward != 0, "no relayer reward");
    relayerRewardVault[relayer] = 0;
    address payable recipient = payable(relayer);
    ISystemReward(SYSTEM_REWARD_ADDR).claimRewards(recipient, reward);
  }

  /// Distribute relayer rewards within a round
  /// @return The caller compensation reward
  function _distributeRelayerReward() internal returns (uint256) {
    uint256 totalReward = collectedRewardForHeaderRelayer;
    uint256 totalWeight = 0;
    address payable[] memory _relayers = headerRelayerAddressRecord;
    uint256 relayerSize = _relayers.length;
    uint256[] memory relayerWeight = new uint256[](relayerSize);
    for (uint256 index = 0; index < relayerSize; index++) {
      uint256 weight = calculateRelayerWeight(headerRelayersSubmitCount[_relayers[index]]);
      relayerWeight[index] = weight;
      totalWeight += weight;
    }

    uint256 callerReward = totalReward * callerCompensationMolecule / 10000;
    totalReward -= callerReward;
    uint256 remainReward = totalReward;
    for (uint256 index = 1; index < relayerSize; index++) {
      uint256 reward = relayerWeight[index] * totalReward / totalWeight;
      relayerRewardVault[_relayers[index]] += reward;
      remainReward -= reward;
    }
    relayerRewardVault[_relayers[0]] += remainReward;

    collectedRewardForHeaderRelayer = 0;
    for (uint256 index = 0; index < relayerSize; index++) {
      delete headerRelayersSubmitCount[_relayers[index]];
    }
    delete headerRelayerAddressRecord;
    return callerReward;
  }

  /// Calculate relayer weight based on number of blocks relayed
  /// @param count The number of blocks relayed by a specific relayer
  /// @return The relayer weight
  function calculateRelayerWeight(uint256 count) public view returns (uint256) {
    if (count <= maxWeight) {
      return count;
    } else if (maxWeight < count && count <= 2 * maxWeight) {
      return maxWeight;
    } else if (2 * maxWeight < count && count <= (2 * maxWeight + 3 * maxWeight / 4)) {
      return 3 * maxWeight - count;
    } else {
      return count / 4;
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
    } else if (Memory.compareStrings(key,"callerCompensationMolecule")) {
      require(value.length == 32, "length of callerCompensationMolecule mismatch");
      uint256 newCallerCompensationMolecule = BytesToTypes.bytesToUint256(32, value);
      require(newCallerCompensationMolecule <= 10000, "the callerCompensationMolecule out of range");
      callerCompensationMolecule = newCallerCompensationMolecule;
    } else if (Memory.compareStrings(key,"roundSize")) {
      require(value.length == 32, "length of roundSize mismatch");
      uint256 newRoundSize = BytesToTypes.bytesToUint256(32, value);
      require(newRoundSize >= maxWeight, "the roundSize out of range");
      roundSize = newRoundSize;
    } else if (Memory.compareStrings(key,"maxWeight")) {
      require(value.length == 32, "length of maxWeight mismatch");
      uint256 newMaxWeight = BytesToTypes.bytesToUint256(32, value);
      require(newMaxWeight > 0 && newMaxWeight <= roundSize, "the maxWeight out of range");
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
