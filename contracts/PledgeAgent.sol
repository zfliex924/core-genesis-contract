// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./interface/ICoreAgent.sol";
import "./interface/IPledgeAgent.sol";
import "./interface/IParamSubscriber.sol";
import "./interface/ISystemReward.sol";
import "./lib/Address.sol";
import "./lib/TypedMemView.sol";
import "./lib/Memory.sol";
import "./lib/SatoshiPlusHelper.sol";
import "./System.sol";

/// This contract manages user delegate, also known as stake
/// Including both coin delegate and hash delegate

/// HARDFORK V-1.0.3
/// `effective transfer` is introduced in this hardfork to keep the rewards for users 
/// when transferring CORE tokens from one validator to another
/// `effective transfer` only contains the amount of CORE tokens transferred 
/// which are eligible for claiming rewards in the acting round

/// HARDFORK V-1.0.12
/// This contract is retired. 
/// It's role is replaced by StakeHub and 3 agent contracts to handle different types of staking assets separately
/// It is kept in the codebase for backward compatibiliy

contract PledgeAgent is IPledgeAgent, System, IParamSubscriber {
  using TypedMemView for *;

  // Deprecated in V-1.0.13
  // minimal CORE require to stake
  uint256 public requiredCoinDeposit;

  // Deprecated in V-1.0.13
  // powerFactor/10000 determines the weight of BTC hash power vs CORE stakes
  // the default value of powerFactor is set to 20000 
  // which means the overall BTC hash power takes 2/3 total weight 
  // when calculating hybrid score and distributing block rewards
  uint256 public powerFactor;

  // Deprecated in V-1.0.13
  // key: candidate's operateAddr
  mapping(address => Agent) public agentsMap;

  // This field is used to store collected rewards of delegators. 
  // key: delegator address
  // value: amount of CORE tokens claimable
  mapping(address => uint256) public rewardMap;

  // This field is not used in the latest implementation
  // It stays here in order to keep data compatibility for TestNet upgrade
  mapping(bytes20 => address) public btc2ethMap;

  // key: round index
  // value: useful state information of round
  mapping(uint256 => RoundState) public stateMap;

  // roundTag is set to be timestamp / round interval,
  // the valid value should be greater than 10,000 since the chain started.
  // It is initialized to 1.
  uint256 public roundTag;

  // HARDFORK V-1.0.3 
  // debtDepositMap keeps delegator's amount of CORE which should be deducted when claiming rewards in every round
  mapping(uint256 => mapping(address => uint256)) public debtDepositMap;

  // Deprecated in V-1.0.13
  // btcReceiptMap keeps all BTC staking receipts on Core
  mapping(bytes32 => BtcReceipt) public btcReceiptMap;

  // Deprecated in V-1.0.13
  // round2expireInfoMap keeps the amount of expired BTC staking value for each round
  mapping(uint256 => BtcExpireInfo) round2expireInfoMap;

  // Deprecated in V-1.0.13
  uint256 public btcFactor;
  uint256 public minBtcLockRound;
  uint32 public btcConfirmBlock;
  uint256 public minBtcValue;
  uint256 public delegateBtcGasPrice;

  // reentrant lock
  bool private reentrantLocked;

  // HARDFORK V-1.0.7
  struct BtcReceipt {
    address agent;
    address delegator;
    uint256 value;
    uint256 endRound;
    uint256 rewardIndex;
    address payable feeReceiver;
    uint256 fee;
  }

  // HARDFORK V-1.0.7
  struct BtcExpireInfo {
    address[] agentAddrList;
    mapping(address => uint256) agent2valueMap;
    mapping(address => uint256) agentExistMap;
  }

  struct CoinDelegator {
    uint256 deposit;
    uint256 newDeposit;
    uint256 changeRound;
    uint256 rewardIndex;
    // HARDFORK V-1.0.3
    // transferOutDeposit keeps the `effective transfer` out of changeRound
    // transferInDeposit keeps the `effective transfer` in of changeRound
    uint256 transferOutDeposit;
    uint256 transferInDeposit;
  }

  struct Reward {
    uint256 totalReward;
    uint256 remainReward;
    uint256 score;
    uint256 coin;
    uint256 round;
  }

  // The Agent struct for Candidate.
  struct Agent {
    uint256 totalDeposit;
    mapping(address => CoinDelegator) cDelegatorMap;
    Reward[] rewardSet;
    uint256 power;
    uint256 coin;
    uint256 btc;
    uint256 totalBtc;
    bool    moved;
  }

  struct RoundState {
    uint256 power;
    uint256 coin;
    uint256 powerFactor;
    uint256 btc;
    uint256 btcFactor;
  }

  /*********************** events **************************/
  event claimedReward(address indexed delegator, address indexed operator, uint256 amount, bool success);
  event received(address indexed from, uint256 amount);

  function init() external onlyNotInit {
    roundTag = block.timestamp / SatoshiPlusHelper.ROUND_INTERVAL;
    alreadyInit = true;
  }

  modifier noReentrant() {
    require(!reentrantLocked, "PledgeAgent reentrant call.");
    reentrantLocked = true;
    _;
    reentrantLocked = false;
  }

  /*********************** External methods ***************************/
  /// Delegate coin to a validator
  /// @param agent The operator address of validator
  /// HARDFORK V-1.0.12 Deprecated, the method is kept here for backward compatibility
  function delegateCoin(address agent) external payable override noReentrant{
    ICoreAgent(CORE_AGENT_ADDR).proxyDelegate{value: msg.value}(agent, msg.sender, 0);
  }

  /// Undelegate coin from a validator
  /// @param agent The operator address of validator
  /// HARDFORK V-1.0.12 Deprecated, the method is kept here for backward compatibility
  function undelegateCoin(address agent) external override {
    undelegateCoin(agent, 0);
  }

  /// Undelegate coin from a validator
  /// @param agent The operator address of validator
  /// @param amount The amount of CORE to undelegate
  /// HARDFORK V-1.0.12 Deprecated, the method is kept here for backward compatibility
  function undelegateCoin(address agent, uint256 amount) public override noReentrant{
    uint256 undelegateAmount = ICoreAgent(CORE_AGENT_ADDR).proxyUnDelegate(agent, msg.sender, amount);
    Address.sendValue(payable(msg.sender), undelegateAmount);
  }

  /// Transfer coin stake to a new validator
  /// @param sourceAgent The validator to transfer coin stake from
  /// @param targetAgent The validator to transfer coin stake to
  // HARDFORK V-1.0.12 Deprecated, the method is kept here for backward compatibility
  function transferCoin(address sourceAgent, address targetAgent) external override {
    transferCoin(sourceAgent, targetAgent, 0);
  }

  /// Transfer coin stake to a new validator
  /// @param sourceAgent The validator to transfer coin stake from
  /// @param targetAgent The validator to transfer coin stake to
  /// @param amount The amount of CORE to transfer
  // HARDFORK V-1.0.12 Deprecated, the method is kept here for backward compatibility
  function transferCoin(address sourceAgent, address targetAgent, uint256 amount) public override noReentrant{
    (bool success, ) = CORE_AGENT_ADDR.call(abi.encodeWithSignature("proxyTransfer(address,address,address,uint256)", sourceAgent, targetAgent, msg.sender, amount));
    require (success, "call CORE_AGENT_ADDR.proxyTransfer() failed");
  }

  /// Claim rewards for delegator
  /// @return (Amount claimed, Are all rewards claimed)
  function claimReward(address[] calldata) external override noReentrant returns (uint256, bool) {
    uint256 rewardSum = rewardMap[msg.sender];

    (bool success, bytes memory data) = STAKE_HUB_ADDR.call(abi.encodeWithSignature("proxyClaimReward(address)", msg.sender));
    require (success, "call STAKE_HUB_ADDR.proxyClaimReward() failed");
    uint256 proxyRewardSum =  abi.decode(data, (uint256));

    if (proxyRewardSum != 0) {
      rewardMap[msg.sender] += proxyRewardSum;
    }

    _distributeReward(msg.sender);

    return (rewardSum + proxyRewardSum, true);
  }

  /*********************** Internal methods ***************************/
  /// send rewards to delegator and clear the record in rewardMap
  /// @param delegator the delegator address
  function _distributeReward(address delegator) internal {
    uint256 reward = rewardMap[delegator];
    if (reward != 0) {
      rewardMap[delegator] = 0;
      Address.sendValue(payable(delegator), reward);
      emit claimedReward(delegator, msg.sender, reward, true);
    }
  }

  /*********************** Governance ********************************/
  /// Update parameters through governance vote
  /// @param key The name of the parameter
  /// @param value the new value set to the parameter
  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov {
    if (value.length != 32) {
      revert MismatchParamLength(key);
    }
    if (Memory.compareStrings(key, "clearDeprecatedMembers")) {
      requiredCoinDeposit = 0;
      powerFactor = 0;
      btcFactor = 0;
      minBtcLockRound = 0;
      btcConfirmBlock = 0;
      minBtcValue = 0;
      delegateBtcGasPrice = 0;
    } else {
      revert UnsupportedGovParam(key);
    }
    emit paramChange(key, value);
  }

  /*********************** Public view ********************************/
  /// Get delegator information
  /// @param agent The operator address of validator
  /// @param delegator The delegator address
  /// @return cd CoinDelegator Information of the delegator
  function getDelegator(address agent, address delegator) external view returns (CoinDelegator memory cd) {
      cd = agentsMap[agent].cDelegatorMap[delegator];
      (bool success, bytes memory result) = CORE_AGENT_ADDR.staticcall(abi.encodeWithSignature("getDelegator(address,address)", agent, delegator));
      require (success, "call CORE_AGENT_ADDR.getDelegator() failed");
      (uint256 stakedAmount, uint256 realtimeAmount, uint256 transferredAmount, uint256 changeRound) = abi.decode(result, (uint256,uint256,uint256,uint256));
      if (realtimeAmount != 0 || transferredAmount != 0) {
        cd.deposit = stakedAmount;
        cd.newDeposit = realtimeAmount;
        cd.changeRound = changeRound;
        cd.transferOutDeposit = transferredAmount;
      }
  }

  /// Get reward information of a validator by index
  /// @param agent The operator address of validator
  /// @param index The reward index
  /// @return Reward The reward information
  function getReward(address agent, uint256 index) external view returns (Reward memory) {
    Agent storage a = agentsMap[agent];
    require(index < a.rewardSet.length, "out of up bound");
    return a.rewardSet[index];
  }

  /// Get expire information of a validator by round and agent
  /// @param round The end round of the btc lock
  /// @param agent The operator address of validator
  /// @return expireValue The expire value of the agent in the round
  function getExpireValue(uint256 round, address agent) external view returns (uint256){
    BtcExpireInfo storage expireInfo = round2expireInfoMap[round];
    return expireInfo.agent2valueMap[agent];
  }

  function getExpireList(uint256 round) external view returns (address[] memory){
    return round2expireInfoMap[round].agentAddrList;
  }

  function getDebt(uint256 round, address delegator) external view returns (uint256) {
    return debtDepositMap[round][delegator];
  }

  receive() external payable {
    if (msg.value != 0) {
      emit received(msg.sender, msg.value);
    }
  }
}