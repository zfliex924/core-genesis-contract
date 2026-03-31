// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "../CandidateHub.sol";
import "../lib/BytesToTypes.sol";
import "../lib/Memory.sol";
import "../interface/IValidatorSet.sol";
import "../interface/ICandidateHub.sol";
import "../interface/IParamSubscriber.sol";
import "../interface/ISlashIndicator.sol";
import "../interface/IStakeHub.sol";
import "../System.sol";
import "../lib/Address.sol";
import "../lib/SatoshiPlusHelper.sol";

contract CandidateHubMock is CandidateHub {
    bool public controlRoundTimeTag = false;
    bool public turnroundFailed = false;

    function developmentInit() external {
        roundInterval = 1;
        requiredMargin = requiredMargin / 1e16;
        dues = dues / 1e16;
        maxCommissionChange = 100;
        roundTag = 7;
    }

    function setControlRoundTimeTag(bool value) external {
        controlRoundTimeTag = value;
    }

    function setRoundTag(uint value) external {
        roundTag = value;
    }

    function setDues(uint value) external {
        dues = value;
    }

    function setValidatorCount(uint256 value) external {
        validatorCount = value;
    }

    function getCanDelegateCandidates() external view returns (address[] memory) {
        uint count;
        for (uint256 i = 0; i < candidateList.length; i++) {
            if (this.canDelegate(candidateList[i])) {
                count++;
            }
        }
        address[] memory opAddrs = new address[](count);
        uint n;
        for (uint256 i = 0; i < candidateList.length; i++) {
            if (this.canDelegate(candidateList[i])) {
                opAddrs[n] = candidateList[i];
                n++;
            }
        }
        return opAddrs;
    }

    function getRefusedCandidates() external view returns (address[] memory) {
        uint count;
        for (uint256 i = 0; i < candidateList.length; i++) {
            if ((candidateMap[candidateList[i]].status & SET_INACTIVE) == SET_INACTIVE) {
                count++;
            }
        }
        address[] memory opAddrs = new address[](count);
        uint n;
        for (uint256 i = 0; i < candidateList.length; i++) {
            if ((candidateMap[candidateList[i]].status & SET_INACTIVE) == SET_INACTIVE) {
                opAddrs[n] = candidateList[i];
                n++;
            }
        }
        return opAddrs;
    }

    function setJailMap(address k, uint256 v) public {
        jailMap[k] = v;
    }

    function setCandidateMargin(address k, uint256 v) public {
        candidateMap[k].margin = v;
    }

    function setCandidateStatus(address k, uint256 v) public {
        candidateMap[k].status = v;
    }

    function setTurnroundFailed(bool value) public {
        turnroundFailed = value;
    }

    function setRoundInterval(uint256 value) public {
        roundInterval = value;
    }

    function getCandidate(address k) public view returns (Candidate memory) {
        return candidateMap[k];
    }

    function getConsensusMap(address consensusAddr) public view returns (address) {
        return consensusMap[consensusAddr];
    }

    function getScoreMock(address[] memory candidates, uint256 round) external returns (uint256[] memory hybridScores) {
        hybridScores = IStakeHub(STAKE_HUB_ADDR).getHybridScore(candidates, round);
        return hybridScores;
    }

    function getValidatorsMock(
        address[] memory candidateList_,
        uint256[] memory scoreList,
        uint256 count,
        uint256 sortedCount
    ) public pure returns (address[] memory validatorList) {
        return getValidators(candidateList_, scoreList, count, sortedCount);
    }

    function getAlternateCountMock(
        uint256 _maxAlternateCount,
        uint256 count,
        uint256 candidateSize
    ) public pure returns (uint256) {
        return getAlternateCount(_maxAlternateCount, count, candidateSize);
    }

    function cleanMock() public {
        ISlashIndicator(SLASH_CONTRACT_ADDR).clean();
    }

    function registerMock(
        address operateAddr,
        address consensusAddr,
        address payable feeAddr,
        uint32 commissionThousandths,
        bytes calldata voteAddr
    ) external payable onlyInit {
        uint32 id = nextCandidateId++;
        candidateMap[operateAddr] = Candidate({
            id: id,
            operateAddr: operateAddr,
            consensusAddr: consensusAddr,
            feeAddr: feeAddr,
            commissionThousandths: commissionThousandths,
            margin: msg.value,
            status: SET_CANDIDATE,
            commissionLastChangeRound: roundTag,
            commissionLastRoundValue: commissionThousandths,
            agent: address(0),
            voteAddr: voteAddr
        });
        candidateList.push(operateAddr);
        operateMap[operateAddr] = true;
        idMap[id] = operateAddr;
        consensusMap[consensusAddr] = operateAddr;

        emit registered(operateAddr, consensusAddr, feeAddr, commissionThousandths, msg.value, voteAddr);
    }

    function turnRound() public virtual override onlyCoinbase onlyInit onlyZeroGasPrice {
        require(!turnroundFailed, "turnRound failed");
        super.turnRound();
    }

    function nextRound() internal virtual override {
        if (controlRoundTimeTag) {
            roundTag++;
        } else {
            super.nextRound();
        }
    }

    function setMaxAlternateCount(uint256 _maxAlternateCount) external {
        maxAlternateCount = _maxAlternateCount;
    }

    function mockGetAlternateCount(uint256 _maxAlternateCount, uint256 count, uint256 candidateSize) public pure returns (uint256) {
        return getAlternateCount(_maxAlternateCount, count, candidateSize);
    }

    receive() external payable {}

    function removeCandidateMock(address operateAddr) external {
        _removeCandidate(operateAddr);
    }

    /// @dev Fill candidateList with dummy addresses to simulate a large candidate set
    function mockFillCandidateList(uint256 count) external {
        for (uint256 i = candidateList.length; i < count; i++) {
            address dummy = address(uint160(0xdead0000 + i));
            candidateList.push(dummy);
            operateMap[dummy] = true;
        }
    }
}
