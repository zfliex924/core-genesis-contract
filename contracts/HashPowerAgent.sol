// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./interface/IAgent.sol";
import "./interface/IParamSubscriber.sol";
import "./interface/ILightClient.sol";
import "./System.sol";

/// This contract handles Zcash hash power staking (measured in ZEC blocks).
/// Rewards are distributed proportionally to staked (bound) miners only.
/// Unbound miner power still contributes to hybrid score but their
/// share of rewards is returned as undistributed (for burning).
contract HashPowerAgent is IAgent, System, IParamSubscriber {

  // key: delegator address, value: claimable reward
  mapping(address => uint256) public rewardMap;

  // Staked (bound) power total from getStakeAmounts
  uint256 public stakedRoundAmount;
  // Total power across all candidates (bound + unbound)
  uint256 public totalRoundAmount;

  /*********************** events **************************/
  event claimedHashReward(address indexed delegator, uint256 amount);
  event validatorAvgReward(address indexed validator, uint256 avgReward);

  /*********************** Init ********************************/
  function init() external onlyNotInit {
    alreadyInit = true;
  }

  /*********************** IAgent implementations ***************************/

  /// Get staked hash power for each candidate
  /// Records stakedRoundAmount per candidate and totalRoundAmount for reward scaling
  function getStakeAmounts(address[] calldata candidates, uint256 roundTag) external override returns (uint256[] memory amounts, uint256 totalAmount) {
    (amounts, totalAmount) = ILightClient(ZEC_LIGHT_CLIENT_ADDR).getRoundPowers(roundTag - 7, candidates);
    totalRoundAmount = totalAmount;
    uint256 staked;
    for (uint256 i = 0; i < candidates.length; ++i) {
      staked += amounts[i];
    }
    stakedRoundAmount = staked;
  }

  /// Distribute rewards to bound miners
  /// Each miner gets: rewardList[i] / minerSize * stakedRoundAmount / totalRoundAmount
  /// The unbound portion is returned as undistributed
  function distributeReward(address[] calldata validators, uint256[] calldata rewardList, uint256 round) external override onlyStakeHub
    returns (uint256 undistributed)
  {
    uint256 validatorSize = validators.length;
    require(validatorSize == rewardList.length, "the length of validatorList and rewardList should be equal");

    for (uint256 i = 0; i < validatorSize; ++i) {
      if (rewardList[i] == 0) continue;

      address[] memory miners = ILightClient(ZEC_LIGHT_CLIENT_ADDR).getRoundMiners(round - 7, validators[i]);
      uint256 minerSize = miners.length;
      if (minerSize == 0) {
        undistributed += rewardList[i];
        continue;
      }

      // Scale reward by staked/total ratio (bound miners vs all power)
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

  /// Start new round
  function setNewRound(address[] calldata validators, uint256 round) external override onlyStakeHub {
  }

  /// Claim reward for delegator
  function claimReward(address delegator) external override onlyStakeHub returns (uint256 reward) {
    reward = rewardMap[delegator];
    if (reward != 0) {
      delete rewardMap[delegator];
      emit claimedHashReward(delegator, reward);
    }
  }

  /*********************** Governance ********************************/
  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov view {
    revert UnsupportedGovParam(key);
  }
}
