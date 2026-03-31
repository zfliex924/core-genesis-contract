// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "../ZecAgent.sol";

contract ZecAgentMock is ZecAgent {

    function developmentInit() external {
    }

    function setRoundTag(uint256 value) external {
        roundTag = value;
    }

    function setCandidateState(address candidate, uint256 staked, uint256 realtime) external {
        candidateMap[candidate].stakedAmount = staked;
        candidateMap[candidate].realtimeAmount = realtime;
    }
}
