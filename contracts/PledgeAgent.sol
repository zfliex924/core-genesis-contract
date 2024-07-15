// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./interface/IAgent.sol";
import "./interface/IParamSubscriber.sol";
import "./interface/ICandidateHub.sol";
import "./interface/ISystemReward.sol";
import "./lib/Address.sol";
import "./lib/BitcoinHelper.sol";
import "./lib/BytesToTypes.sol";
import "./lib/Memory.sol";
import "./lib/SatoshiPlusHelper.sol";
import "./System.sol";

/// This contract manages user delegate CORE.
/// HARDFORK V-1.0.3
/// `effective transfer` is introduced in this hardfork to keep the rewards for users 
/// when transferring CORE tokens from one validator to another
/// `effective transfer` only contains the amount of CORE tokens transferred 
/// which are eligible for claiming rewards in the acting round
contract PledgeAgent is IAgent, System, IParamSubscriber {
  using BitcoinHelper for *;
  using TypedMemView for *;

  uint256 public constant INIT_REQUIRED_COIN_DEPOSIT = 1e18;
  int256 public constant CLAIM_ROUND_LIMIT = 500;
  uint256 public constant POWER_BLOCK_FACTOR = 1e18;

  uint256 public requiredCoinDeposit;

  // HARDFORK V-1.0.10 Deprecated
  // powerFactor/10000 determines the weight of BTC hash power vs CORE stakes
  // the default value of powerFactor is set to 20000 
  // which means the overall BTC hash power takes 2/3 total weight 
  // when calculating hybrid score and distributing block rewards
  uint256 public powerFactor;

  // key: candidate's operateAddr
  mapping(address => Agent) public agentsMap;

  // This field is used to store `special` reward records of delegators. 
  // There are two cases
  //  1, distribute hash power rewards dust to one miner when turn round
  //  2, save the amount of tokens failed to claim by coin delegators
  // key: delegator address
  // value: amount of CORE tokens claimable
  mapping(address => uint256) public rewardMap;

  // This field position is never used in previous.
  // It stays here in order to keep data compatibility for TestNet upgrade
  // HARDFORK V-1.0.10
  // key: delegator address
  // value: delegator info.
  mapping(address => Delegator) public delegatorsMap;

  // key: round index
  // value: useful state information of round
  mapping(uint256 => RoundState) public stateMap;

  // roundTag is set to be timestamp / round interval,
  // the valid value should be greater than 10,000 since the chain started.
  // It is initialized to 1.
  uint256 public roundTag;

  // HARDFORK V-1.0.3
  // debtDepositMap keeps delegator's amount of CORE which should be deducted when claiming rewards in every round
  // HARDFORK V-1.0.10 Deprecated
  mapping(uint256 => mapping(address => uint256)) public debtDepositMap;

  // HARDFORK V-1.0.10
  // Following fields is deprecated.
  // `btcReceiptMap` and `round2expireInfoMap` will be clean after moving data
  // into BitcoinStake.
  // The other 5 fields and `powerFactor` will be reset via gov.

  // HARDFORK V-1.0.7
  // btcReceiptMap keeps all BTC staking receipts on Core
  mapping(bytes32 => BtcReceipt) public btcReceiptMap;

  // round2expireInfoMap keeps the amount of expired BTC staking value for each round
  mapping(uint256 => BtcExpireInfo) round2expireInfoMap;

  // staking weight of each BTC vs. CORE
  uint256 public btcFactor;

  // minimum rounds to stake for a BTC staking transaction
  uint256 public minBtcLockRound;

  // the number of blocks to mark a BTC staking transaction as confirmed
  uint32 public btcConfirmBlock;

  // minimum value to stake for a BTC staking transaction
  uint256 public minBtcValue;

  uint256 public delegateBtcGasPrice;

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
    uint256 transferOutDeposit;
    // HARDFORK V-1.0.10 Deprecated
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
  }

  struct RoundState {
    uint256 power;
    uint256 coin;
    uint256 powerFactor;
    uint256 btc;
    uint256 btcFactor;
  }

  struct Delegator {
    address[] candidates;
    uint256 amount;
  }

  /*********************** events **************************/
  event paramChange(string key, bytes value);
  event delegatedCoin(address indexed agent, address indexed delegator, uint256 amount, uint256 totalAmount);
  event undelegatedCoin(address indexed agent, address indexed delegator, uint256 amount);
  event transferredCoin(
    address indexed sourceAgent,
    address indexed targetAgent,
    address indexed delegator,
    uint256 amount,
    uint256 totalAmount
  );
  event btcPledgeExpired(bytes32 indexed txid, address indexed delegator);
  event claimedReward(address indexed delegator, address indexed operator, uint256 amount, bool success);

  /// The validator candidate is inactive, it is expected to be active
  /// @param candidate Address of the validator candidate
  error InactiveAgent(address candidate);

  /// Same source/target addressed provided, it is expected to be different
  /// @param source Address of the source candidate
  /// @param target Address of the target candidate
  error SameCandidate(address source, address target);

  function init() external onlyNotInit {
    requiredCoinDeposit = INIT_REQUIRED_COIN_DEPOSIT;
    roundTag = block.timestamp / SatoshiPlusHelper.ROUND_INTERVAL;
    alreadyInit = true;
  }

  /*********************** Interface implementations ***************************/
  /// HARDFORK V-1.0.10
  /// Do some preparement before new round.
  /// @param round The new round tag
  function prepare(uint256 round) external override {
    // Nothing
  }

  /// Receive round rewards from StakeHub, which is triggered at the beginning of turn round
  /// @param validators List of validator operator addresses
  /// @param rewardList List of reward amount
  function distributeReward(address[] calldata validators, uint256[] calldata rewardList, uint256) external override onlyStakeHub
  {
    uint256 validateSize = validators.length;
    require(validateSize == rewardList.length, "the length of validators and rewardList should be equal");
    for (uint256 i = 0; i < validateSize; ++i) {
      Agent storage a = agentsMap[validators[i]];
      if (a.rewardSet.length == 0) {
        continue;
      }
      Reward storage r = a.rewardSet[a.rewardSet.length - 1];
      uint256 roundScore = r.score;
      if (roundScore == 0) {
        delete a.rewardSet[a.rewardSet.length - 1];
        continue;
      }
      if (rewardList[i] == 0) {
        continue;
      }
      r.totalReward = rewardList[i];
      r.remainReward = rewardList[i];
    }
  }

  /// Get stake amount
  /// @param candidates List of candidate operator addresses
  ///
  /// @return amounts List of amounts of all special candidates in this round
  /// @return totalAmount The sum of all amounts of valid/invalid candidates.
  function getStakeAmounts(address[] calldata candidates, uint256) external override view returns (uint256[] memory amounts, uint256 totalAmount) {
    uint256 candidateSize = candidates.length;
    amounts = new uint256[](candidateSize);
    for (uint256 i = 0; i < candidateSize; ++i) {
      Agent storage a = agentsMap[candidates[i]];
      amounts[i] = a.totalDeposit;
      totalAmount += amounts[i];
    }
  }

  /// Start new round, this is called by the CandidateHub contract
  /// @param validators List of elected validators in this round
  /// @param round The new round tag
  function setNewRound(address[] calldata validators, uint256 round) external override onlyStakeHub {
    uint256 validatorSize = validators.length;
    for (uint256 i = 0; i < validatorSize; ++i) {
      Agent storage a = agentsMap[validators[i]];
      uint256 score = a.totalDeposit;
      a.rewardSet.push(Reward(0, 0, score, score, round));
    }
    roundTag = round;
  }

  function onFelony(address agent) external onlyValidator {
    Agent storage a = agentsMap[agent];
    uint256 len = a.rewardSet.length;
    if (len > 0) {
      Reward storage r = a.rewardSet[len-1];
      if (r.round == roundTag && r.coin == 0) {
        delete a.rewardSet[len-1];
      }
    }
  }

  /*********************** External methods ***************************/
  /// Delegate coin to a validator
  /// @param agent The operator address of validator
  function delegateCoin(address agent) external payable {
    if (!ICandidateHub(CANDIDATE_HUB_ADDR).canDelegate(agent)) {
      revert InactiveAgent(agent);
    }
    uint256 newDeposit = delegateCoin(agent, msg.sender, msg.value);
    emit delegatedCoin(agent, msg.sender, msg.value, newDeposit);
    addCandidate(msg.sender, agent);
  }

  /// Undelegate coin from a validator
  /// @param candidate The operator address of validator
  function undelegateCoin(address candidate) external {
    undelegateCoin(candidate, 0);
  }

  /// Undelegate coin from a validator
  /// @param candidate The operator address of validator
  /// @param amount The amount of CORE to undelegate
  function undelegateCoin(address candidate, uint256 amount) public {
    uint256 deposit = undelegateCoin(candidate, msg.sender, amount, false);
    Address.sendValue(payable(msg.sender), deposit);
    emit undelegatedCoin(candidate, msg.sender, deposit);
    // TODO removeCandidate(msg.sender, address candidate)
  }

  /// Transfer coin stake to a new validator
  /// @param sourceAgent The validator to transfer coin stake from
  /// @param targetAgent The validator to transfer coin stake to
  function transferCoin(address sourceAgent, address targetAgent) external {
    transferCoin(sourceAgent, targetAgent, 0);
  }

  /// Transfer coin stake to a new validator
  /// @param sourceAgent The validator to transfer coin stake from
  /// @param targetAgent The validator to transfer coin stake to
  /// @param amount The amount of CORE to transfer
  function transferCoin(address sourceAgent, address targetAgent, uint256 amount) public {
    if (!ICandidateHub(CANDIDATE_HUB_ADDR).canDelegate(targetAgent)) {
      revert InactiveAgent(targetAgent);
    }
    if (sourceAgent == targetAgent) {
      revert SameCandidate(sourceAgent, targetAgent);
    }
    uint256 deposit = undelegateCoin(sourceAgent, msg.sender, amount, true);
    uint256 newDeposit = delegateCoin(targetAgent, msg.sender, deposit);

    emit transferredCoin(sourceAgent, targetAgent, msg.sender, deposit, newDeposit);
  }

  /// Claim reward for delegator
  /// @param agentList The list of validators to claim rewards on, it can be empty
  /// @return (Amount claimed, Are all rewards claimed)
  function claimReward(address[] calldata agentList) external returns (uint256, bool) {
    // limit round count to control gas usage
    int256 roundLimit = CLAIM_ROUND_LIMIT;
    uint256 reward;
    uint256 rewardSum = rewardMap[msg.sender];
    if (rewardSum != 0) {
      rewardMap[msg.sender] = 0;
    }

    uint256 agentSize = agentList.length;
    for (uint256 i = 0; i < agentSize; ++i) {
      Agent storage a = agentsMap[agentList[i]];
      if (a.rewardSet.length == 0) {
        continue;
      }
      CoinDelegator storage d = a.cDelegatorMap[msg.sender];
      if (d.newDeposit == 0 && d.transferOutDeposit == 0) {
        continue;
      }
      int256 roundCount = int256(a.rewardSet.length - d.rewardIndex);
      reward = collectCoinReward(a, d, roundLimit);
      roundLimit -= roundCount;
      rewardSum += reward;
      if (d.newDeposit == 0 && d.transferOutDeposit == 0) {
        delete a.cDelegatorMap[msg.sender];
      }
      // if there are rewards to be collected, leave them there
      if (roundLimit < 0) {
        break;
      }
    }

    if (rewardSum != 0) {
      distributeReward(payable(msg.sender), rewardSum);
    }
    return (rewardSum, roundLimit >= 0);
  }

  function claimReward() external override onlyStakeHub returns (uint256) {
    uint256 reward;
    uint256 rewardSum = rewardMap[msg.sender];
    if (rewardSum != 0) {
      rewardMap[msg.sender] = 0;
    }

    Delegator storage delegator = delegatorsMap[msg.sender];
    uint256 candidateSize = delegator.candidates.length;
    for (uint256 i = candidateSize; i != 0;) {
      --i;
      Agent storage a = agentsMap[delegator.candidates[i]];
      if (a.rewardSet.length == 0) {
        continue;
      }
      CoinDelegator storage d = a.cDelegatorMap[msg.sender];
      if (d.newDeposit == 0 && d.transferOutDeposit == 0) {
        continue;
      }
      reward = collectCoinReward(a, d, 0xFFFFFFFF);
      rewardSum += reward;
      if (d.newDeposit == 0 && d.transferOutDeposit == 0) {
        delete a.cDelegatorMap[msg.sender];
        removeCandidate(msg.sender, delegator.candidates[i]);
      }
    }

    if (rewardSum != 0) {
      distributeReward(payable(msg.sender), rewardSum);
    }
    return rewardSum;
  }

  // HARDFORK V-1.0.7 
  /// claim BTC staking rewards
  /// @param txidList the list of BTC staking transaction id to claim rewards 
  /// @return rewardSum amount of reward claimed
  function claimBtcReward(bytes32[] calldata txidList) external returns (uint256 rewardSum) {
    int256 claimLimit = CLAIM_ROUND_LIMIT;
    uint256 len = txidList.length;
    for(uint256 i = 0; i < len && claimLimit != 0; i++) {
      bytes32 txid = txidList[i];
      BtcReceipt storage br = btcReceiptMap[txid];
      require(br.value != 0, "btc tx not found");
      address delegator = br.delegator;
      require(delegator == msg.sender, "not the delegator of this btc receipt");

      uint256 reward;
      (reward, claimLimit) = collectBtcReward(txid, claimLimit);
      rewardSum += reward;
      if (br.value == 0) {
        emit btcPledgeExpired(txid, delegator);
      }
    }

    if (rewardSum != 0) {
      distributeReward(payable(msg.sender), rewardSum);
    }
    return rewardSum;
  }

  function cleanDelegateInfo(bytes32 txid) external onlyBtcStake returns (address candidate, address delegator, uint256 amount, uint256 round, uint256 lockTime) {
    BtcReceipt storage br = btcReceiptMap[txid];
    require(br.value != 0, "btc tx not found");

    // Set return values
    candidate = br.agent;
    delegator = br.delegator;
    amount = br.value;
    lockTime = br.endRound * SatoshiPlusHelper.ROUND_INTERVAL;

    Agent storage agent = agentsMap[br.agent];
    if (br.rewardIndex == agent.rewardSet.length) {
      round = roundTag;
    } else {
      Reward storage reward = agent.rewardSet[br.rewardIndex];
      if (reward.round == 0 || reward.round == roundTag) {
        round = roundTag;
      } else {
        round = roundTag - 1;
      }
    }
    // distribute reward
    (uint256 rewardValue,) = collectBtcReward(txid, 0x7FFFFFFF);
    if (rewardValue != 0) {
      distributeReward(payable(br.delegator), rewardValue);
    }

    // Clean round2expireInfoMap
    BtcExpireInfo storage expireInfo = round2expireInfoMap[br.endRound];
    uint256 length = expireInfo.agentAddrList.length;
    for (uint256 j = length; j != 0; j--) {
      if (expireInfo.agentAddrList[j-1] == candidate) {
        agentsMap[candidate].totalBtc -= amount;
        if (expireInfo.agent2valueMap[candidate] == amount) {
          delete expireInfo.agent2valueMap[candidate];
          delete expireInfo.agentExistMap[candidate];
        } else {
          expireInfo.agent2valueMap[candidate] -= amount;
        }
        if (j != length) {
           expireInfo.agentAddrList[j-1] = expireInfo.agentAddrList[length - 1];
        }
        expireInfo.agentAddrList.pop();
        break;
      }
    }
    if (expireInfo.agentAddrList.length == 0) {
      delete round2expireInfoMap[br.endRound];
    }

    // Clean btcReceiptMap
    delete btcReceiptMap[txid];
  }

  /*********************** Internal methods ***************************/
  function distributeReward(address payable delegator, uint256 reward) internal {
    Address.sendValue(delegator, reward);
    emit claimedReward(delegator, msg.sender, reward, true);
  }

  function delegateCoin(address agent, address delegator, uint256 deposit) internal returns (uint256) {
    require(deposit >= requiredCoinDeposit, "deposit is too small");
    Agent storage a = agentsMap[agent];
    CoinDelegator storage d = a.cDelegatorMap[delegator];
    uint256 rewardAmount;
    if (d.changeRound != 0) {
      rewardAmount = collectCoinReward(a, d, 0x7FFFFFFF);
    }
    a.totalDeposit += deposit;

    if (d.newDeposit == 0 && d.transferOutDeposit == 0) {
      d.newDeposit = deposit;
      d.changeRound = roundTag;
      d.rewardIndex = a.rewardSet.length;
    } else {
      if (d.changeRound < roundTag) {
        d.deposit = d.newDeposit;
        d.changeRound = roundTag;
      }
      d.newDeposit += deposit;
    }

    if (rewardAmount != 0) {
      distributeReward(payable(delegator), rewardAmount);
    }
    return d.newDeposit;
  }
  
  function undelegateCoin(address agent, address delegator, uint256 amount, bool isTransfer) internal returns (uint256) {
    Agent storage a = agentsMap[agent];
    CoinDelegator storage d = a.cDelegatorMap[delegator];
    uint256 rewardAmount = collectCoinReward(a, d, 0x7FFFFFFF);
    require(d.deposit != 0, "Not enough deposit token");
    uint256 deposit = d.deposit;
    if (amount == 0) {
      amount = deposit;
    }
    if (deposit != amount) {
      require(amount >= requiredCoinDeposit, "undelegate amount is too small"); 
      require(d.newDeposit >= requiredCoinDeposit + amount, "remaining amount is too small");
    }
    a.totalDeposit -= amount;

    if (isTransfer) {
      d.transferOutDeposit += amount;
    } else {
      if (a.rewardSet.length != 0) {
        Reward storage r = a.rewardSet[a.rewardSet.length - 1];
        if (r.round == roundTag) {
          r.coin -= amount;
        }
      }
    }

    if (!isTransfer && d.newDeposit == amount && d.transferOutDeposit == 0) {
      delete a.cDelegatorMap[delegator];
      removeCandidate(delegator, agent);
    } else {
      d.deposit -= amount;
      d.newDeposit -= amount;
    }

    if (rewardAmount != 0) {
      distributeReward(payable(delegator), rewardAmount);
    }

    return amount;
  }

  function collectCoinReward(Reward storage r, uint256 deposit) internal returns (uint256 rewardAmount) {
    require(r.coin >= deposit, "reward is not enough");
    uint256 rsPower = stateMap[r.round].power;
    if (rsPower == 0) {
      rsPower = 1;
    }
    rewardAmount = (r.totalReward * deposit * rsPower) / r.score;
    require(r.remainReward >= rewardAmount, "there is not enough reward");
    r.coin -= deposit;
    r.remainReward -= rewardAmount;
  }

  function collectCoinReward(Agent storage a, CoinDelegator storage d, int256 roundLimit) internal returns (uint256 rewardAmount) {
    uint256 changeRound = d.changeRound;
    uint256 curRound = roundTag;
    if (changeRound < curRound) {
      d.transferInDeposit = 0;
    }

    uint256 rewardLength = a.rewardSet.length;
    uint256 rewardIndex = d.rewardIndex;
    if (rewardIndex >= rewardLength) {
      return 0;
    }
    if (rewardIndex + uint256(roundLimit) < rewardLength) {
      rewardLength = rewardIndex + uint256(roundLimit);
    }

    while (rewardIndex < rewardLength) {
      Reward storage r = a.rewardSet[rewardIndex];
      uint256 rRound = r.round;
      if (rRound == curRound) {
        break;
      }
      uint256 deposit = d.newDeposit;
      // HARDFORK V-1.0.10
      // d.deposit and d.transferOutDeposit are both eligible for claiming rewards
      if (rRound == changeRound) {
        if (debtDepositMap[rRound][msg.sender] != 0) {
          debtDepositMap[rRound][msg.sender] = 0;
        }
        uint256 transferOutDeposit = d.transferOutDeposit;
        deposit = d.deposit + transferOutDeposit;
        d.deposit = d.newDeposit;
        if (transferOutDeposit != 0) {
          d.transferOutDeposit = 0;
        }
      }
      if (deposit != 0) {
        rewardAmount += collectCoinReward(r, deposit);
        if (r.coin == 0) {
          delete a.rewardSet[rewardIndex];
        }
      }
      rewardIndex++;
    }

    // update index whenever claim happens
    d.rewardIndex = rewardIndex;
    return rewardAmount;
  }

  function addExpire(BtcReceipt storage br) internal {
    BtcExpireInfo storage expireInfo = round2expireInfoMap[br.endRound];
    if (expireInfo.agentExistMap[br.agent] == 0) {
      expireInfo.agentAddrList.push(br.agent);
      expireInfo.agentExistMap[br.agent] = 1;
    }
    expireInfo.agent2valueMap[br.agent] += br.value;
  }

  function collectBtcReward(bytes32 txid, int256 claimLimit) internal returns (uint256, int256) {
    uint256 curRound = roundTag;
    BtcReceipt storage br = btcReceiptMap[txid];
    uint256 reward = 0;
    Agent storage a = agentsMap[br.agent];
    uint256 rewardIndex = br.rewardIndex;
    uint256 rewardLength = a.rewardSet.length;
    while (rewardIndex < rewardLength && claimLimit != 0) {
      Reward storage r = a.rewardSet[rewardIndex];
      uint256 rRound = r.round;
      if (rRound == curRound || br.endRound <= rRound) {
        break;
      }
      uint256 deposit = br.value * stateMap[rRound].btcFactor;
      reward += collectCoinReward(r, deposit);
      if (r.coin == 0) {
        delete a.rewardSet[rewardIndex];
      }
      rewardIndex += 1;
      claimLimit -= 1;
    }

    if (br.endRound <= (rewardIndex == rewardLength ? curRound : a.rewardSet[rewardIndex].round)) {
      delete btcReceiptMap[txid];
    } else {
      br.rewardIndex = rewardIndex;
    }
    return (reward, claimLimit);
  }

  function addCandidate(address delegator, address candidate) internal {
    Delegator storage d = delegatorsMap[delegator];
    uint256 l = d.candidates.length;
    for (uint256 i = 0; i < l; ++i) {
      if (d.candidates[i] == candidate) {
        return;
      }
    }
    d.candidates.push(candidate);
  }

  function removeCandidate(address delegator, address candidate) internal {
    Delegator storage d = delegatorsMap[delegator];
    uint256 l = d.candidates.length;
    for (uint256 i = 0; i < l; ++i) {
      if (d.candidates[i] == candidate) {
        if (i + 1 < l) {
          d.candidates[i] = d.candidates[l-1];
        }
        d.candidates.pop();
        return;
      }
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
    if (Memory.compareStrings(key, "requiredCoinDeposit")) {
      uint256 newRequiredCoinDeposit = BytesToTypes.bytesToUint256(32, value);
      if (newRequiredCoinDeposit == 0) {
        revert OutOfBounds(key, newRequiredCoinDeposit, 1, type(uint256).max);
      }
      requiredCoinDeposit = newRequiredCoinDeposit;
    } else if (Memory.compareStrings(key, "clearDeprecatedFields")) {
      btcFactor = 0;
      powerFactor = 0;
      minBtcLockRound = 0;
      btcConfirmBlock = 0;
      minBtcValue = 0;
      delegateBtcGasPrice = 0;
    } else {
      require(false, "unknown param");
    }
    emit paramChange(key, value);
  }

  /*********************** Public view ********************************/
  /// Get delegator information
  /// @param agent The operator address of validator
  /// @param delegator The delegator address
  /// @return CoinDelegator Information of the delegator
  function getDelegator(address agent, address delegator) external view returns (CoinDelegator memory) {
    CoinDelegator memory d = agentsMap[agent].cDelegatorMap[delegator];
    return d;
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

  function getStakeInfo(address candidate) external view returns (uint256 core, uint256 hashpower, uint256 btc) {
    Agent storage agent = agentsMap[candidate];
    core = agent.coin;
    hashpower = agent.power / POWER_BLOCK_FACTOR;
    btc = agent.btc;
  }
}