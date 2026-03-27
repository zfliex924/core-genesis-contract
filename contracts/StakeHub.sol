// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./interface/IParamSubscriber.sol";
import "./interface/IStakeHub.sol";
import "./interface/IAgent.sol";
import "./interface/ISystemReward.sol";
import "./interface/IBitcoinStake.sol";
import "./interface/IBurn.sol";
import "./interface/IZecAgent.sol";
import "./interface/IValidatorSet.sol";
import "./interface/ICandidateHub.sol";
import "./interface/ICoreAgent.sol";
import "./System.sol";
import "./lib/Address.sol";
import "./lib/Memory.sol";
import "./lib/BytesLib.sol";
import "./lib/RLPDecode.sol";
import "./lib/SatoshiPlusHelper.sol";

/// This contract deals with overall hybrid score and reward distribution logics.
/// It interacts with CandidateHub.sol and other protocol contracts during the turnround process.
/// Underneath it interacts with the agent contracts to deal with different staking assets separately.
///
/// Key change from Core Chain: rewards are distributed to agents by fixed hardcap ratio,
/// not by per-candidate dynamic scores. candidateScoresMap is removed.
contract StakeHub is IStakeHub, System, IParamSubscriber {
  using BytesLib for *;

  // Supported asset types
  Asset[] public assets;

  // key: agent contract address
  // value: asset information of the round
  mapping(address => AssetState) public stateMap;

  // other smart contracts granted to interact with StakeHub
  mapping(address => bool) public operators;

  // Delegator's map
  mapping(address => Delegator) public delegatorMap;

  struct Asset {
    string  name;
    address agent;
    uint32 hardcap;
  }

  struct AssetState {
    uint256 amount;
    uint256 factor;
  }

  struct Delegator {
    uint256 changeRound;
    uint256[] rewards;
  }

  /*********************** events **************************/
  event roundReward(string indexed name, uint256 round, address[] validator, uint256[] amount);
  event claimedReward(address indexed delegator, uint256[] amounts);
  event received(address indexed from, uint256 amount);

  function init() external onlyNotInit {
    // initialize list of supported assets
    assets.push(Asset("CORE", CORE_AGENT_ADDR, 6000));
    assets.push(Asset("HASHPOWER", HASH_AGENT_ADDR, 2000));
    assets.push(Asset("BTC", BTC_AGENT_ADDR, 4000));
    assets.push(Asset("ZEC", ZEC_AGENT_ADDR, 3000));

    operators[CORE_AGENT_ADDR] = true;
    operators[HASH_AGENT_ADDR] = true;
    operators[BTC_AGENT_ADDR] = true;
    operators[BTC_STAKE_ADDR] = true;
    operators[ZEC_AGENT_ADDR] = true;

    alreadyInit = true;

    address[] memory validators = IValidatorSet(VALIDATOR_CONTRACT_ADDR).getValidatorOps();
    uint256[] memory factors = new uint256[](4);
    factors[0] = 1;
    // HASH_UNIT_CONVERSION * 1e6
    factors[1] = 1e18 * 1e6;
    // BTC_UNIT_CONVERSION * 2e4
    factors[2] = 1e10 * 2e4;
    // ZEC factor
    factors[3] = 1e8 * 1e4;

    uint256 len = assets.length;
    for (uint256 j = 0; j < len; j++) {
      stateMap[assets[j].agent] = AssetState(0, factors[j]);
    }
  }

  receive() external payable {
    if (msg.value != 0) {
      emit received(msg.sender, msg.value);
    }
  }

  /*********************** Interface implementations ***************************/
  /// Receive staking rewards from ValidatorSet, which is triggered at the
  /// beginning of turn round.
  /// Rewards are distributed to each agent proportionally by hardcap.
  ///
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

    // Calculate total hardcap weight
    uint256 assetSize = assets.length;
    uint256 totalHardcap;
    for (uint256 i = 0; i < assetSize; ++i) {
      totalHardcap += assets[i].hardcap;
    }

    uint256[] memory rewards = new uint256[](validatorSize);
    uint256 burnReward;

    for (uint256 i = 0; i < assetSize; ++i) {
      uint256 hardcap = assets[i].hardcap;
      for (uint256 j = 0; j < validatorSize; ++j) {
        rewards[j] = rewardList[j] * hardcap / totalHardcap;
      }
      emit roundReward(assets[i].name, roundTag, validators, rewards);
      burnReward += IAgent(assets[i].agent).distributeReward(validators, rewards, roundTag);
    }
    // Burn undistributed rewards (no stakers on some validators)
    if (burnReward != 0 && address(this).balance >= burnReward) {
      IBurn(BURN_ADDR).burn{value: burnReward}();
    }
  }

  /// Calculate hybrid score for all candidates
  /// This is used for validator election only.
  /// Reward distribution uses fixed hardcap ratios (in addRoundReward).
  ///
  /// @param candidates List of candidate operator addresses
  /// @param round The new round tag
  /// @return scores List of hybrid scores of all validator candidates in this round
  function getHybridScore(
    address[] calldata candidates,
    uint256 round
  ) external override onlyCandidate returns (uint256[] memory scores) {
    IBitcoinStake(BTC_STAKE_ADDR).prepare(round);
    IZecAgent(ZEC_AGENT_ADDR).prepare(round);

    uint256 candidateSize = candidates.length;
    uint256 assetSize = assets.length;

    uint256 factor0;
    uint256[] memory amounts;
    uint256[] memory totalAmounts = new uint256[](assetSize);
    scores = new uint256[](candidateSize);
    for (uint256 i = 0; i < assetSize; ++i) {
      (amounts, totalAmounts[i]) =
        IAgent(assets[i].agent).getStakeAmounts(candidates, round);
      uint256 factor = 1;
      if (i == 0) {
        factor0 = factor;
      } else if (totalAmounts[0] != 0 && totalAmounts[i] != 0) {
        factor = (factor0 * totalAmounts[0]) * assets[i].hardcap / assets[0].hardcap / totalAmounts[i];
      }
      for (uint256 j = 0; j < candidateSize; ++j) {
        scores[j] += amounts[j] * factor;
      }
      stateMap[assets[i].agent] = AssetState(totalAmounts[i], factor);
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

  /// Claim reward for delegator
  /// @return rewards Amounts claimed
  function claimReward() external returns (uint256[] memory rewards) {
    address delegator = msg.sender;
    rewards = _calculateReward(delegator, true);

    Delegator storage d  = delegatorMap[delegator];
    for (uint256 i = 0; i < d.rewards.length; i++) {
      rewards[i] += d.rewards[i];
    }
    uint256 currentRound = ICandidateHub(CANDIDATE_HUB_ADDR).getRoundTag();
    if (d.changeRound != currentRound) {
      d.changeRound = currentRound;
    }
    delete delegatorMap[delegator].rewards;

    uint256 reward;
    for (uint256 i = 0; i < rewards.length; i++) {
      reward += rewards[i];
    }
    if (reward != 0) {
      Address.sendValue(payable(delegator), reward);
      emit claimedReward(delegator, rewards);
    }
  }

  /// This method is invoked whenever user stake changes.
  /// @param delegator delegator address
  function onStakeChange(address delegator) override external {
    calculateReward(delegator);
  }

  // Calculate reward for delegator.
  /// @param delegator delegator address
  function calculateReward(address delegator) public {
    Delegator storage d = delegatorMap[delegator];
    uint256 currentRound = ICandidateHub(CANDIDATE_HUB_ADDR).getRoundTag();
    if (d.changeRound != currentRound) {
      uint256[] memory rewards = _calculateReward(delegator, false);
      for (uint256 i = 0; i < rewards.length; i++) {
        if (d.rewards.length == i) {
          d.rewards.push(rewards[i]);
        } else {
          d.rewards[i] += rewards[i];
        }
      }
      d.changeRound = currentRound;
    }
  }

  /// Calculate reward for delegator
  /// No more cross-agent dependency (surplus/floatReward removed)
  /// Each agent calculates rewards independently
  function _calculateReward(address delegator, bool claim) internal returns (uint256[] memory rewards) {
    uint256 lastRound = ICandidateHub(CANDIDATE_HUB_ADDR).getRoundTag() - 1;

    uint256 assetSize = assets.length;
    rewards = new uint256[](assetSize);

    // CORE agent uses its own claimReward interface
    (rewards[0], , ) = ICoreAgent(assets[0].agent).claimReward(delegator, claim);

    // All other agents use IAgent.claimReward
    for (uint256 i = 1; i < assetSize; ++i) {
      (rewards[i], ) = IAgent(assets[i].agent).claimReward(delegator, 0, lastRound, claim);
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
    uint256 newValue = value.toUint256(0);
    if (!_updateHardcap(key, newValue)) {
      revert UnsupportedGovParam(key);
    }
    emit paramChange(key, value);
  }

  function _updateHardcap(string calldata key, uint256 newValue) internal returns(bool) {
    uint256 indexplus;
    if (Memory.compareStrings(key, "coreHardcap")) {
      indexplus = 1;
    } else if(Memory.compareStrings(key, "hashHardcap")) {
      indexplus = 2;
    } else if(Memory.compareStrings(key, "btcHardcap")) {
      indexplus = 3;
    } else if(Memory.compareStrings(key, "zecHardcap")) {
      indexplus = 4;
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

  /*********************** External methods ********************************/
  function getAssets() external view returns (Asset[] memory) {
    return assets;
  }

  function getDelegator(address delegator) external view returns(Delegator memory) {
    return delegatorMap[delegator];
  }
}
