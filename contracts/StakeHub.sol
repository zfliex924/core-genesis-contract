// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./interface/IParamSubscriber.sol";
import "./interface/IStakeHub.sol";
import "./interface/IAgent.sol";
import "./interface/ISystemReward.sol";
import "./interface/IValidatorSet.sol";
import "./System.sol";
import "./lib/Address.sol";
import "./lib/Memory.sol";
import "./lib/BytesLib.sol";
import "./lib/SatoshiPlusHelper.sol";

/// This contract deals with overall hybrid score and reward distribution logics. 
/// It replaces the existing role of PledgeAgent.sol to interact with CandidateHub.sol and other protocol contracts during the turnround process. 
/// Under the neath it interacts with the new agent contracts to deal with CORE, BTC and hash staking separately. 
contract StakeHub is IStakeHub, System, IParamSubscriber {
  using BytesLib for *;

  uint256 public constant MASK_STAKE_CORE = 1;
  uint256 public constant MASK_STAKE_HASH = 2;
  uint256 public constant MASK_STAKE_BTC = 4;

  // Supported asset types
  //  - CORE
  //  - Hash power (measured in BTC blocks)
  //  - BTC 
  Asset[] public assets;

  // key: candidate op address
  // value: score of each staked asset type
  //        The first element represents total score of the validator.
  mapping(address => uint256[]) public candidateScoresMap;

  // key: delegator address
  // value: MASK value of staked asset types
  // TODO unused
  mapping(address => uint256) public delegatesMaskMap;

  // key: agent contract address 
  // value: asset information of the round
  mapping(address => AssetState) public stateMap;

  // key: delegator address
  // value: system debts, e.g. transmitting fee of a BTC staking transaction
  mapping(address => Debt) debts;

  // other smart contracts granted to interact with StakeHub
  mapping(address => bool) public operators;

  // key: contributor address, e.g. relayer's
  // value: rewards collected for contributing to the system
  // TODO unused
  mapping(address => uint256) public payableNotes;

  // CORE grading applied to BTC stakers
  DualStakingGrade[] public grades;

  // whether the CORE grading is enabled
  uint256 public gradeActive;

  // accumulated unclaimed rewards each round, will be redistributed at the beginning of the next round
  uint256 public unclaimedReward;

  struct Asset {
    string  name;
    address agent;
    uint32 hardcap;
    uint32 bonusRate;
  }

  struct AssetState {
    uint256 amount;
    uint256 factor;
  }

  struct Debt {
    NotePayable[] notes;
  }
  struct NotePayable {
    address contributor;
    uint256 amount;
  }

  struct DualStakingGrade {
    uint32 rewardRate;
    uint32 percentage; // [0 ~ DENOMINATOR]
  }

  /*********************** events **************************/
  event roundReward(string indexed name, uint256 round, address[] validator, uint256[] amount, uint256 bonus);
  event claimedReward(address indexed delegator, uint256 amount);
  event claimedRelayerReward(address indexed relayer, uint256 amount);

  function init() external onlyNotInit {
    // initialize list of supported assets
    assets.push(Asset("CORE", CORE_AGENT_ADDR, 6000, 0));
    assets.push(Asset("HASHPOWER", HASH_AGENT_ADDR, 2000, 0));
    assets.push(Asset("BTC", BTC_AGENT_ADDR, 4000, uint32(SatoshiPlusHelper.DENOMINATOR)));

    _initializeFromPledgeAgent();

    operators[PLEDGE_AGENT_ADDR] = true;
    operators[CORE_AGENT_ADDR] = true;
    operators[HASH_AGENT_ADDR] = true;
    operators[BTC_AGENT_ADDR] = true;
    operators[BTC_STAKE_ADDR] = true;
    operators[BTCLST_STAKE_ADDR] = true;
    // Default active btc grade.
    gradeActive = MASK_STAKE_BTC;

    alreadyInit = true;
  }

  /*********************** Interface implementations ***************************/
  /// Receive staking rewards from ValidatorSet, which is triggered at the
  /// beginning of turn round
  /// @param validators List of validator operator addresses
  /// @param rewardList List of reward amount
  function addRoundReward(
    address[] calldata validators,
    uint256[] calldata rewardList,
    uint256 roundTag
  ) external payable override onlyValidator
  {
    uint256 validatorSize = validators.length;
    require(validatorSize == rewardList.length, "the length of validators and rewardList should be equal");
    uint256[] memory rewards = new uint256[](validatorSize);

    uint256 burnReward;
    uint256 assetSize = assets.length;
    uint256 totalReward;
    uint256 usedBonus;
    for (uint256 i = 0; i < assetSize; ++i) {
      //Asset storage asset = assets[i];
      totalReward = 0;
      for (uint256 j = 0; j < validatorSize; ++ j) {
        address validator = validators[j];
        uint256 totalScore = candidateScoresMap[validator][0];
        // only reach here if running a new chain from genesis
        if (totalScore == 0) {
          if (i % assetSize == 0) {
            burnReward += rewardList[j];// burnReward
          }
          rewards[j] = 0;
          continue;
        }
        rewards[j] = rewardList[j] * candidateScoresMap[validator][i+1] / totalScore;
        totalReward += rewards[j];
      }
      uint assetBonus = totalReward == 0 ? 0 : unclaimedReward * assets[i].bonusRate / SatoshiPlusHelper.DENOMINATOR;
      if (totalReward != 0) {
        // added after hardcap to leave more rewards to users
        for (uint256 j = 0; j < validatorSize; ++j) {
          uint256 r = rewards[j] * assetBonus / totalReward;
          rewards[j] += r;
          usedBonus += r;
        }
      }
      emit roundReward(assets[i].name, roundTag, validators, rewards, assetBonus);
      IAgent(assets[i].agent).distributeReward(validators, rewards, roundTag);
    }
    unclaimedReward -= usedBonus;
    // burn overflow reward after hardcap
    ISystemReward(SYSTEM_REWARD_ADDR).receiveRewards{ value: burnReward }();
  }

  /// Calculate hybrid score for all candidates
  /// This function will also calculate the discount of rewards for each asset
  /// to apply hardcap
  ///
  /// @param candidates List of candidate operator addresses
  /// @param round The new round tag
  /// @return scores List of hybrid scores of all validator candidates in this round
  function getHybridScore(
    address[] calldata candidates,
    uint256 round
  ) external override onlyCandidate returns (uint256[] memory scores) {
    uint256 candidateSize = candidates.length;
    uint256 assetSize = assets.length;

    uint256 hardcapSum;
    for (uint256 i = 0; i < assetSize; ++i) {
      hardcapSum += assets[i].hardcap;
      IAgent(assets[i].agent).prepare(round);
    }
    // score := asset's amount * factor.
    // asset score & hardcaps are used to calculate discount for each asset
    scores = new uint256[](candidateSize);
    address candiate;
    uint256 factor0;
    uint256[] memory totalAmounts = new uint256[](assetSize);
    for (uint256 i = 0; i < assetSize; ++i) {
      (uint256[] memory amounts, uint256 totalAmount) =
        IAgent(assets[i].agent).getStakeAmounts(candidates, round);
      totalAmounts[i] = totalAmount;
      uint256 factor = 1;
      if (i == 0) {
        factor0 = factor;
      } else if (totalAmounts[0] != 0 && totalAmounts[i] != 0) {
        factor = (factor0 * totalAmounts[0]) * assets[i].hardcap / assets[0].hardcap / totalAmounts[i];
      }
      if (candidateScoresMap[candiate].length == 0) {
        candidateScoresMap[candiate].push(0);
      }
      uint score;
      for (uint256 j = 0; j < candidateSize; ++j) {
        score = amounts[j] * factor;
        scores[j] += score;
        candiate = candidates[j];
        // length should never be less than i
        if (candidateScoresMap[candiate].length == i+1) {
          candidateScoresMap[candiate].push(score);
        } else {
          candidateScoresMap[candiate][i+1] = score;
        }
      }
      stateMap[assets[i].agent] = AssetState(totalAmount, factor);
    }

    for (uint256 j = 0; j < candidateSize; ++j) {
      candidateScoresMap[candidates[j]][0] = scores[j];
    }
  }

  /// Start new round, this is called by the CandidateHub contract
  /// @param validators List of elected validators in this round
  /// @param round The new round tag
  function setNewRound(address[] calldata validators, uint256 round) external override onlyCandidate {
    uint256 assetSize = assets.length;
    for (uint256 i = 0; i < assetSize; ++i) {
      IAgent(assets[i].agent).setNewRound(validators, round);
    }
  }

  /// add a system debt on a delegator
  /// @param delegator the delegator to pay the debt
  /// @param contributor the contributor to receive the fee
  /// @param amount amount of CORE
  function addNotePayable(address delegator, address contributor, uint256 amount) external override {
    require(operators[msg.sender], 'only debt operators');
    debts[delegator].notes.push(NotePayable(contributor, amount));
  }

  /// Claim reward for delegator
  /// @return rewards Amounts claimed
  /// @return debtAmount system debt paid
  function claimReward() external returns (uint256[] memory rewards, uint256 debtAmount) {
    address delegator = msg.sender;
    (rewards, debtAmount) = calculateReward(delegator);

    uint256 reward = 0;
    for (uint256 i = 0; i < rewards.length; i++) {
      reward += rewards[i];
    }
    reward -= debtAmount;
    if (reward != 0) {
      Address.sendValue(payable(delegator), reward);
      emit claimedReward(delegator, reward);
    }
  }

  /// Calculate reward for delegator
  /// @param delegator delegator address
  /// @param rewards rewards on each type of staked assets
  /// @param debtAmount system debt paid
  function calculateReward(address delegator) public returns (uint256[] memory rewards, uint256 debtAmount) {
    uint256 assetSize = assets.length;
    rewards = new uint256[](assetSize);
    uint256[] memory unclaimedRewards = new uint256[](assetSize);
    uint256 gradeLength = grades.length;
    uint256 totalReward;
    uint256 totalUnclaimedReward;
    for (uint256 i = 0; i < assetSize; ++i) {
      (rewards[i], unclaimedRewards[i]) = IAgent(assets[i].agent).claimReward(delegator);
      uint256 mask = (1 << i);
      // apply CORE grading to rewards
      if ((gradeActive & mask) == mask && gradeLength != 0 && rewards[i] != 0) {
        uint256 rewardRate = rewards[0] * SatoshiPlusHelper.DENOMINATOR / rewards[i];
        uint256 p = grades[0].percentage;
        for (uint256 j = gradeLength - 1; j != 0; j--) {
          if (rewardRate >= grades[j].rewardRate) {
            p = grades[j].percentage;
            break;
          }
        }
        uint256 rewardClaimed = rewards[i] * p / SatoshiPlusHelper.DENOMINATOR;
        unclaimedRewards[i] += (rewards[i] - rewardClaimed);
        rewards[i] = rewardClaimed;
      }
      totalReward += rewards[i];
      totalUnclaimedReward += unclaimedRewards[i];
    }

    // pay system debts from staking rewards
    if (totalReward != 0) {
      Debt storage lb = debts[delegator];
      uint256 lbamount;
      for (uint256 i = lb.notes.length; i != 0; --i) {
        lbamount = lb.notes[i-1].amount;
        if (lbamount <= totalReward) {
          payableNotes[lb.notes[i-1].contributor] += lbamount;
          debtAmount += lbamount;
          totalReward -= lbamount;
          lb.notes.pop();
        } else {
          payableNotes[lb.notes[i-1].contributor] += totalReward;
          debtAmount += totalReward;
          lb.notes[i-1].amount -= totalReward;
          totalReward = 0;
          break;
        }
      }
    }

    unclaimedReward += totalUnclaimedReward;
  }

  /// Claim reward for relayer
  /// @return reward Amount claimed
  /// TODO might also call system reward to send all rewards as a whole
  function claimRelayerReward() external returns (uint256 reward) {
    address relayer = msg.sender;
    reward = payableNotes[relayer];
    if (reward != 0) {
      payableNotes[relayer] = 0;
      Address.sendValue(payable(relayer), reward);
      emit claimedRelayerReward(relayer, reward);
    }
  }

  /*********************** Governance ********************************/
  /// Update parameters through governance vote
  /// @param key The name of the parameter
  /// @param value the new value set to the parameter
  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov {
    if (Memory.compareStrings(key, "grades")) {
      // TODO more details on how the grading binary array is designed and parsed
      uint256 lastLength = grades.length;
      uint256 currentLength = value.indexUint(0, 1);

      if (((currentLength << 2) | 1) == value.length) {
        revert MismatchParamLength(key);
      }

      for (uint256 i = currentLength; i < lastLength; i++) {
        grades.pop();
      }
      uint32 rewardRate;
      uint32 percentage;
      for (uint256 i = 0; i < currentLength; i++) {
        uint256 startIndex = (i << 2) | 1;
        rewardRate = uint32(value.indexUint(startIndex, 2));
        percentage = uint32(value.indexUint(startIndex + 2, 2));
        if (percentage == 0 || percentage > SatoshiPlusHelper.DENOMINATOR) {
          revert OutOfBounds('percentage', percentage, 1, SatoshiPlusHelper.DENOMINATOR);
        }
        if (i >= lastLength) {
          grades.push(DualStakingGrade(rewardRate, percentage));
        } else {
          grades[i] = DualStakingGrade(rewardRate, percentage);
        }
      }
      // check rewardRate & percentage in order.
      for (uint256 i = 1; i < currentLength; i++) {
        require(grades[i-1].rewardRate < grades[i].rewardRate, "rewardRate disorder");
        require(grades[i-1].percentage < grades[i].percentage, "percentage disorder");
      }
    } else {
      if (value.length != 32) {
        revert MismatchParamLength(key);
      }
      uint256 newValue = value.toUint256(0);
      if (Memory.compareStrings(key, "gradeActive")) {
        if (newValue > 7) {
          revert OutOfBounds(key, newValue, 0, 7);
        }
        gradeActive = newValue;
      } else if (!updateHardcap(key, newValue) && !updateBonusRate(key, newValue)) {
        revert UnsupportedGovParam(key);
      }
    }
  
    emit paramChange(key, value);
  }

  function updateHardcap(string calldata key, uint256 newValue) internal returns(bool) {
    uint256 indexplus;
    if (Memory.compareStrings(key, "coreHardcap")) {
      indexplus = 1;
    } else if(Memory.compareStrings(key, "hashHardcap")) {
      indexplus = 2;
    } else if(Memory.compareStrings(key, "btcHardcap")) {
      indexplus = 3;
    }
    if (indexplus != 0) {
      if (newValue == 0 || newValue > 1e5) {
        revert OutOfBounds(key, newValue, 1, 1e5);
      }
      assets[indexplus - 1].hardcap = uint32(newValue);
      return true;
    }
    return false;
  }

  function updateBonusRate(string calldata key, uint256 newValue) internal returns(bool) {
    uint256 indexplus;
    if (Memory.compareStrings(key, "coreBonusRate")) {
      indexplus = 1;
    } else if(Memory.compareStrings(key, "hashBonusRate")) {
      indexplus = 2;
    } else if(Memory.compareStrings(key, "btcBonusRate")) {
      indexplus = 3;
    }
    if (indexplus != 0) {
      if (newValue > SatoshiPlusHelper.DENOMINATOR) {
        revert OutOfBounds(key, newValue, 0, SatoshiPlusHelper.DENOMINATOR);
      }
      assets[indexplus - 1].bonusRate = uint32(newValue);
      uint32 sum = assets[0].bonusRate+assets[1].bonusRate+assets[2].bonusRate;
      require(sum <= SatoshiPlusHelper.DENOMINATOR, "the sum of bonus rates out of bound.");
      return true;
    }
    return false;
  }
  /*********************** External methods ********************************/
  function getCandidateScores(address candidate) external view returns (uint256[] memory) {
    return candidateScoresMap[candidate];
  }

  function getAssets() external view returns (Asset[] memory) {
    return assets;
  }

  /*********************** Internal methods ********************************/
  function _initializeFromPledgeAgent() internal {
    // get stake summary of current round (snapshot values of last turn round)
    address[] memory validators = IValidatorSet(VALIDATOR_CONTRACT_ADDR).getValidatorOps();
    (bool success, bytes memory data) = PLEDGE_AGENT_ADDR.call(abi.encodeWithSignature("getStakeInfo(address[])", validators));
    require (success, "call PLEDGE_AGENT_ADDR.getStakeInfo() failed");
    (uint256[] memory cores, uint256[] memory hashs, uint256[] memory btcs) = abi.decode(data, (uint256[], uint256[], uint256[]));

    uint256[] memory factors = new uint256[](3);
    factors[0] = 1;
    // TODO INIT_HASH_FACTOR and INIT_BTC_FACTOR should be set more accurately before launch
    // HASH_UNIT_CONVERSION * 1e6
    factors[1] = 1e18 * 1e6;
    // BTC_UNIT_CONVERSION * 2e4
    factors[2] = 1e10 * 2e4;
    // initialize hybrid score based on data migrated from PledgeAgent.getStakeInfo()
    uint256 validatorSize = validators.length;
    uint256[] memory totalAmounts = new uint256[](3);
    for (uint256 i = 0; i < validatorSize; ++i) {
      address validator = validators[i];

      totalAmounts[0] += cores[i];
      totalAmounts[1] += hashs[i];
      totalAmounts[2] += btcs[i];

      candidateScoresMap[validator].push(cores[i] * factors[0] + hashs[i] * factors[1] + btcs[i] * factors[2]);
      candidateScoresMap[validator].push(cores[i]);
      candidateScoresMap[validator].push(hashs[i]);
      candidateScoresMap[validator].push(btcs[i]);
    }

    uint256 len = assets.length;
    for (uint256 j = 0; j < len; j++) {
      stateMap[assets[j].agent] = AssetState(totalAmounts[j], factors[j]);
    }

    // get active candidates.
    (success, data) = CANDIDATE_HUB_ADDR.call(abi.encodeWithSignature("getCandidates()"));
    require (success, "call CANDIDATE_HUB.getCandidates() failed");
    address[] memory candidates = abi.decode(data, (address[]));

    // move candidate amount.
    (success,) = PLEDGE_AGENT_ADDR.call(abi.encodeWithSignature("moveCandidateData(address[])", candidates));
    require (success, "call PLEDGE_AGENT_ADDR.moveCandidateData() failed");
  }
}