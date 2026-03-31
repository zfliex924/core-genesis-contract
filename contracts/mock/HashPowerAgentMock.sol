// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import {HashPowerAgent} from "../HashPowerAgent.sol";

contract HashPowerAgentMock is HashPowerAgent {

    function setPowerRewardMap(address delegator, uint256 reward) external {
        rewardMap[delegator] = reward;
    }

    function setRoundAmounts(uint256 staked, uint256 total) external {
        stakedRoundAmount = staked;
        totalRoundAmount = total;
    }
}
