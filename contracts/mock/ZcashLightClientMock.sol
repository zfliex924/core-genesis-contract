// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "../ZcashLightClient.sol";

contract ZcashLightClientMock is ZcashLightClient {
    uint32 public mockBlockHeight;
    uint256 public constant MOCK_SCORE = 1000000;

    function developmentInit() external {
        mockBlockHeight = 1;
    }

    function setBlock(bytes32 hash, bytes32 prevHash, address rewardAddr, address candidateAddr) public {
        mockBlockHeight = mockBlockHeight + 1;
        bytes memory baseHeader = new bytes(4);
        // prevHash at offset 4
        bytes memory prevHashBytes = abi.encodePacked(prevHash);
        bytes memory padding = new bytes(104); // pad to 140 bytes total
        bytes memory fullHeader = new bytes(140);
        assembly {
            let dest := add(fullHeader, 0x20)
            // copy 4 bytes version
            let src := add(baseHeader, 0x20)
            mstore(dest, mload(src))
        }
        // Simple encoding: just store with encode()
        blockChain[hash] = encode(fullHeader, rewardAddr, MOCK_SCORE, mockBlockHeight, candidateAddr);
        height2HashMap[mockBlockHeight] = hash;
    }

    function setCandidates(uint256 roundTimeTag, address[] memory candidates) public {
        delete roundPowerMap[roundTimeTag];
        for (uint256 i = 0; i < candidates.length; i++) {
            roundPowerMap[roundTimeTag].candidates.push(candidates[i]);
        }
    }

    function setCheckResult(bool value, uint64 value1) public {
        checkResult = value;
        timesTamp = value1;
    }

    function setMiners(uint256 roundTimeTag, address candidate, address[] memory rewardAddrs) public {
        RoundPower storage r = roundPowerMap[roundTimeTag];
        bool exist;
        for (uint256 i = 0; i < r.candidates.length; i++) {
            if (r.candidates[i] == candidate) {
                exist = true;
                break;
            }
        }
        if (exist == false) {
            r.candidates.push(candidate);
        }
        delete r.powerMap[candidate];
        for (uint256 i = 0; i < rewardAddrs.length; i++) {
            r.powerMap[candidate].miners.push(rewardAddrs[i]);
            r.powerMap[candidate].zecBlocks.push(bytes32(0));
        }
    }
}
