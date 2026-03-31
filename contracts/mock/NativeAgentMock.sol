// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "../NativeAgent.sol";

contract NativeAgentMock is NativeAgent {

    function developmentInit() external {
        requiredCoinDeposit = requiredCoinDeposit;
    }

    function setRoundTag(uint256 value) external {
        roundTag = value;
    }

    function setRequiredCoinDeposit(uint256 newRequiredCoinDeposit) external {
        requiredCoinDeposit = newRequiredCoinDeposit;
    }

    function setCandidateAmount(address candidate, uint256 staked, uint256 realtime) external {
        candidateMap[candidate].stakedAmount = staked;
        candidateMap[candidate].realtimeAmount = realtime;
    }

    function getAccruedRewardMap(address validator, uint256 round) external view returns (uint256) {
        return accruedRewardMap[validator][round];
    }
}
