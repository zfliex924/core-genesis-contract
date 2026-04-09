// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./interface/IParamSubscriber.sol";
import "./interface/IStakeHub.sol";
import "./interface/IAgent.sol";
import "./interface/ISystemReward.sol";
import "./interface/IZecAgent.sol";
import "./interface/IValidatorSet.sol";
import "./interface/ICandidateHub.sol";
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


  struct Asset {
    string  name;
    address agent;
    uint32 hardcap;
  }

  struct AssetState {
    uint256 amount;
    uint256 factor;
  }

  /*********************** events **************************/
  event roundReward(string indexed name, uint256 round, address[] validator, uint256[] amount);
  event claimedReward(address indexed delegator, uint256[] amounts);
  event received(address indexed from, uint256 amount);

  function init() external onlyNotInit {
    // initialize list of supported assets
    assets.push(Asset("CORE", NATIVE_AGENT_ADDR, 6000));
    assets.push(Asset("HASHPOWER", HASH_AGENT_ADDR, 2000));
    assets.push(Asset("ZEC", ZEC_AGENT_ADDR, 3000));

    operators[NATIVE_AGENT_ADDR] = true;
    operators[HASH_AGENT_ADDR] = true;
    operators[ZEC_AGENT_ADDR] = true;

    stateMap[NATIVE_AGENT_ADDR] = AssetState(0, 1);
    stateMap[HASH_AGENT_ADDR]   = AssetState(0, 1e18 * 1e6);  // HASH_UNIT_CONVERSION * 1e6
    stateMap[ZEC_AGENT_ADDR]    = AssetState(0, 1e8 * 1e4);   // ZEC_UNIT_CONVERSION * 1e4

    alreadyInit = true;
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
      payable(BURN_ADDR).transfer(burnReward);
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

  /// Claim reward for delegator across all agents
  /// @return rewards Amounts claimed per asset
  function claimReward() external returns (uint256[] memory rewards) {
    address delegator = msg.sender;
    uint256 assetSize = assets.length;
    rewards = new uint256[](assetSize);

    uint256 total;
    for (uint256 i = 0; i < assetSize; ++i) {
      rewards[i] = IAgent(assets[i].agent).claimReward(delegator);
      total += rewards[i];
    }
    if (total != 0) {
      Address.sendValue(payable(delegator), total);
      emit claimedReward(delegator, rewards);
    }
  }

  modifier onlyAgent() {
    require(operators[msg.sender], "the sender must be an agent contract");
    _;
  }

  /// Called by agents to pay out reward from StakeHub's balance during undelegate
  /// @param to Reward recipient
  /// @param amount Reward amount
  function payReward(address to, uint256 amount) external override onlyAgent {
    if (amount != 0) {
      Address.sendValue(payable(to), amount);
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
    } else if(Memory.compareStrings(key, "zecHardcap")) {
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

  /*********************** External methods ********************************/
  function getAssets() external view returns (Asset[] memory) {
    return assets;
  }

}
