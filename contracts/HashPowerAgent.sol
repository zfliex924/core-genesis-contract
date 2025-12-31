// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./interface/IAgent.sol";
import "./interface/IParamSubscriber.sol";
import "./interface/ILightClient.sol";
import "./lib/SatoshiPlusHelper.sol";
import "./System.sol";

/// This contract handles Bitcoin hash power staking (measured in BTC blocks).
contract HashPowerAgent is IAgent, System, IParamSubscriber {

  // This field is used to store hash power reward of delegators
  // it is updated on turnround
  // key: delegator address
  // value: amount of CORE tokens claimable
  mapping(address => Reward) public rewardMap;

  // The number of staked blocks & total blocks.
  uint256 stakedRoundAmount;
  uint256 totalRoundAmount;

  /*********************** events **************************/
  event claimedHashReward(address indexed delegator, uint256 amount);
  event validatorAvgReward(address indexed validator, uint256 avgReward);

  struct Reward {
    uint256 reward;
    uint256 round;
    uint256 stakeWeight;
  }

  /*********************** Init ********************************/
  function init() external onlyNotInit {
    alreadyInit = true;
  }

  /*********************** IAgent implementations ***************************/
  /// Receive round rewards from StakeHub, which is triggered at the beginning of turn round
  /// @param validators List of validator operator addresses
  /// @param rewardList List of reward amount
  /// @param round The round tag
  /// @param stakeWeight the weight of stake asset
  /// @return destoryAmount the amount of destory reward
  function distributeReward(address[] calldata validators, uint256[] calldata rewardList, uint256 round, uint256 stakeWeight) external override onlyStakeHub returns (uint256 destoryAmount) {
    require(validators.length == rewardList.length, "the length of validatorList and rewardList should be equal");

    // fetch BTC miners who delegated hash power in the about to end round; 
    // and distribute rewards to them
    uint256 avgReward;
    uint256 actureReward;
    uint256 totalReward;
    uint256 distributedReward;
    for (uint256 i = 0; i < validators.length; ++i) {
      totalReward += rewardList[i];
      if (rewardList[i] == 0) {
        continue;
      }
      address[] memory miners = ILightClient(LIGHT_CLIENT_ADDR).getRoundMiners(round-7, validators[i]);
      // distribute rewards to every miner
      if (miners.length != 0) {
        avgReward = rewardList[i] / miners.length * SatoshiPlusHelper.DENOMINATOR / stakeWeight;
        if (totalRoundAmount != 0) {
          avgReward = avgReward * stakedRoundAmount / totalRoundAmount;
        }
        for (uint256 j = 0; j < miners.length; ++j) {
          Reward storage r = rewardMap[miners[j]];
          actureReward = avgReward;
          if (r.stakeWeight != 0) {
            if (r.round < round) {
              uint256 weight = r.stakeWeight + SatoshiPlusHelper.STAKE_WEIGHT_PER_ROUND;
              if (weight > SatoshiPlusHelper.STAKE_WEIGHT_UPPER_BOUND) {
                weight = SatoshiPlusHelper.STAKE_WEIGHT_UPPER_BOUND;
              }
              r.stakeWeight = weight;
              r.round = round;
            }
            actureReward = avgReward * r.stakeWeight / SatoshiPlusHelper.DENOMINATOR;
          }
          distributedReward += actureReward;
          rewardMap[miners[j]].reward += actureReward;
        }
        emit validatorAvgReward(validators[i], actureReward);
      }
    }
    destoryAmount = totalReward - distributedReward;
  }

  /// Get staked BTC hash value
  /// @param candidates List of candidate operator addresses
  /// @param round The new round tag
  /// @return amounts List of staked BTC hash values on all candidates in the round
  /// @return totalAmount Total staked BTC hash values on all candidates in the round
  function getStakeAmounts(address[] calldata candidates, uint256 round) external override onlyStakeHub returns (uint256[] memory amounts, uint256 totalAmount) {
    // fetch hash power delegated on list of candidates
    // which is used to calculate hybrid score for validators in the new round
    (amounts, totalRoundAmount) = ILightClient(LIGHT_CLIENT_ADDR).getRoundPowers(round-7, candidates);
    for (uint256 i = amounts.length; i != 0; --i) {
      totalAmount += amounts[i-1];
    }
    stakedRoundAmount = totalAmount;
    if (totalRoundAmount < totalAmount) {
      totalRoundAmount = totalAmount;
    }
  }

  /// Start new round, this is called by the StakeHub contract
  /// @param validators List of elected validators in this round
  /// @param round The new round tag
  function setNewRound(address[] calldata validators, uint256 round) external override onlyStakeHub {
  }

  /// Claim reward for delegator
  /// @param delegator the delegator address
  /// @return reward Amount claimed
  function claimReward(address delegator, bytes32[] memory /*txIds*/) external override onlyStakeHub returns (uint256 reward) {
    reward = rewardMap[delegator].reward;
    if (reward != 0) {
      if (rewardMap[delegator].stakeWeight == 0) {
        delete rewardMap[delegator];
      } else {
        rewardMap[delegator].stakeWeight = SatoshiPlusHelper.DENOMINATOR - SatoshiPlusHelper.STAKE_WEIGHT_PER_ROUND;
        delete rewardMap[delegator].reward;
      }
      emit claimedHashReward(delegator, reward);
    }
  }

  /// Enable stake weight.
  /// @param delegator the delegator address
  function enableStakeWeight(address delegator) external override onlyStakeHub {
    rewardMap[delegator].stakeWeight = SatoshiPlusHelper.DENOMINATOR - SatoshiPlusHelper.STAKE_WEIGHT_PER_ROUND;
  }

  /// Disable stake weight.
  /// @param delegator the delegator address
  function disableStakeWeight(address delegator) external override onlyStakeHub {
    rewardMap[delegator].stakeWeight = 0;
    rewardMap[delegator].round = 0;
  }

  /*********************** Governance ********************************/
  /// Update parameters through governance vote
  /// @param key The name of the parameter
  /// @param value the new value set to the parameter
  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyCaller(GOV_HUB_ADDR) view {
    revert UnsupportedGovParam(key);
  }
}