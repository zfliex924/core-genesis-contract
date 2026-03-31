// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "../StakeHub.sol";
import "../interface/IAgent.sol";

contract StakeHubMock is StakeHub {

    function developmentInit() external {
    }

    function setOperators(address delegator, bool value) external {
        operators[delegator] = value;
    }

    function setStateMapDiscount(address agent, uint256 value, uint256 value1) external {
        stateMap[agent] = AssetState(value, value1);
    }

    function coreAgentDistributeReward(address[] calldata validators, uint256[] calldata rewardList, uint256 round) external {
        IAgent(CORE_AGENT_ADDR).distributeReward(validators, rewardList, round);
    }
}
