// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;
import "./lib/Address.sol";
import "./lib/BytesLib.sol";
import "./lib/BytesToTypes.sol";
import "./lib/Memory.sol";
import "./interface/IValidatorSet.sol";
import "./interface/ICandidateHub.sol";
import "./interface/IParamSubscriber.sol";
import "./interface/ISlashIndicator.sol";
import "./interface/IStakeHub.sol";
import "./System.sol";
import "./lib/SatoshiPlusHelper.sol";

/// This contract manages all validator candidates on Z Protocol blockchain
/// It also exposes the method `turnRound` for the consensus engine to execute the `turn round` workflow
contract CandidateHub is ICandidateHub, System, IParamSubscriber {

  uint256 public constant INIT_REQUIRED_MARGIN = 1e22;
  uint256 public constant INIT_DUES = 1e20;
  uint256 public constant INIT_VALIDATOR_COUNT = 21;
  uint256 public constant MAX_COMMISSION_CHANGE = 10;
  uint256 public constant CANDIDATE_COUNT_LIMIT = 1000;

  uint256 public constant SET_CANDIDATE = 1;
  uint256 public constant SET_INACTIVE = 2;
  uint256 public constant DEL_INACTIVE = 0xFF-SET_INACTIVE;
  uint256 public constant SET_JAIL = 4;
  uint256 public constant DEL_JAIL = 0xFF-SET_JAIL;
  uint256 public constant SET_MARGIN = 8;
  uint256 public constant DEL_MARGIN = 0xFF-SET_MARGIN;
  uint256 public constant SET_VALIDATOR = 16;
  uint256 public constant DEL_VALIDATOR = 0xFF-SET_VALIDATOR;
  uint256 public constant ACTIVE_STATUS = SET_CANDIDATE | SET_VALIDATOR;
  uint256 public constant UNREGISTER_STATUS = SET_CANDIDATE | SET_INACTIVE | SET_MARGIN;

  uint256 public requiredMargin;
  uint256 public dues;
  uint256 public roundInterval;
  uint256 public validatorCount;
  uint256 public maxCommissionChange;
  uint256 public maxAlternateCount;
  uint256 public roundTag;

  /// @dev Unified candidate struct (replaces old Candidate + CandidateEx)
  struct Candidate {
    address operateAddr;
    address consensusAddr;
    address payable feeAddr;
    uint256 commissionThousandths;
    uint256 margin;
    uint256 status;
    uint256 commissionLastChangeRound;
    uint256 commissionLastRoundValue;
    address agent;
    bytes voteAddr;
  }

  // Primary storage: operator address → Candidate
  mapping(address => Candidate) public candidateMap;
  // Address list for enumeration
  address[] public candidateList;

  // Reverse lookups
  mapping(address => bool) public operateMap;       // operator exists?
  mapping(address => address) public consensusMap;   // consensus addr → operator addr
  mapping(address => address) public agentMap;       // agent addr → operator addr
  mapping(address => uint256) public jailMap;        // operator addr → release round

  modifier onlyOperator() {
    require(operateMap[msg.sender], "candidate does not exist");
    _;
  }

  /*********************** events **************************/
  event registered(address indexed operateAddr, address indexed consensusAddr, address indexed feeAddress, uint256 commissionThousandths, uint256 margin, bytes voteAddr);
  event unregistered(address indexed operateAddr, address indexed consensusAddr);
  event addedMargin(address indexed operateAddr, uint256 margin, uint256 totalMargin);
  event deductedMargin(address indexed operateAddr, uint256 margin, uint256 totalMargin);
  event statusChanged(address indexed operateAddr, uint256 oldStatus, uint256 newStatus);
  event turnedRound(uint256 round);
  event AgentUpdated(address indexed operateAddr, address newAgent);
  event ConsensusAddressEdited(address indexed operateAddr, address newConsensusAddr);
  event CommissionRateEdited(address indexed operateAddr, uint256 newRate);
  event VoteAddressEdited(address indexed operateAddr, bytes newVoteAddr);
  event FeeAddressEdited(address indexed operateAddr, address newFeeAddr);

  /*********************** init **************************/
  function init() external onlyNotInit {
    requiredMargin = INIT_REQUIRED_MARGIN;
    dues = INIT_DUES;
    validatorCount = INIT_VALIDATOR_COUNT;
    maxCommissionChange = MAX_COMMISSION_CHANGE;
    roundTag = block.timestamp / SatoshiPlusHelper.ROUND_INTERVAL;
    alreadyInit = true;
  }

  /********************* ICandidateHub interface ****************************/
  function canDelegate(address candidate) external override view returns(bool) {
    if (!operateMap[candidate]) return false;
    uint256 status = candidateMap[candidate].status;
    return status == (status & ACTIVE_STATUS);
  }

  function isValidator(address candidate) external override view returns(bool) {
    if (!operateMap[candidate]) return false;
    return SET_VALIDATOR == (candidateMap[candidate].status & SET_VALIDATOR);
  }

  function isCandidateByOperate(address operateAddr) external override view returns (bool) {
    return operateMap[operateAddr];
  }

  function jailValidator(address operateAddress, uint256 round, uint256 fine) external override onlyValidator {
    if (!operateMap[operateAddress]) return;

    Candidate storage c = candidateMap[operateAddress];
    uint256 margin = c.margin;
    if (margin >= dues && margin - dues >= fine) {
      uint256 status = c.status | SET_JAIL;
      if (jailMap[operateAddress] > 0) {
        jailMap[operateAddress] = jailMap[operateAddress] + round;
      } else {
        jailMap[operateAddress] = roundTag + round;
      }
      uint256 totalMargin = margin - fine;
      c.margin = totalMargin;
      emit deductedMargin(operateAddress, fine, totalMargin);
      if (totalMargin < requiredMargin) {
        status = status | SET_MARGIN;
      }
      _changeStatus(operateAddress, status);
      if (fine != 0) {
        payable(SYSTEM_REWARD_ADDR).transfer(fine);
      }
    } else {
      _removeCandidate(operateAddress);
      payable(SYSTEM_REWARD_ADDR).transfer(margin);
      emit deductedMargin(operateAddress, margin, 0);
    }
  }

  function getRoundTag() external override view returns(uint256) {
    return roundTag;
  }

  /********************* External methods  ****************************/
  function turnRound() public virtual onlyCoinbase onlyInit onlyZeroGasPrice {
    IValidatorSet(VALIDATOR_CONTRACT_ADDR).exitMaintenanceTurnRound();
    IValidatorSet(VALIDATOR_CONTRACT_ADDR).distributeReward(roundTag);
    nextRound();

    // Reset validator flags and collect valid candidates
    uint256 candidateSize = candidateList.length;
    uint256 validCount = 0;
    uint256[] memory statusList = new uint256[](candidateSize);
    for (uint256 i = 0; i < candidateSize; i++) {
      statusList[i] = candidateMap[candidateList[i]].status & DEL_VALIDATOR;
      if (statusList[i] == SET_CANDIDATE) validCount++;
    }

    address[] memory candidates = new address[](validCount);
    uint256 j = 0;
    for (uint256 i = 0; i < candidateSize; i++) {
      if (statusList[i] == SET_CANDIDATE) {
        candidates[j++] = candidateList[i];
      }
    }

    (uint256[] memory scores) =
      IStakeHub(STAKE_HUB_ADDR).getHybridScore(candidates, roundTag);
    uint256 sortedCount = getAlternateCount(maxAlternateCount, validatorCount, candidates.length);
    address[] memory validatorList = getValidators(candidates, scores, validatorCount + sortedCount, sortedCount);

    address[] memory consensusAddrList = new address[](validatorList.length);
    address payable[] memory feeAddrList = new address payable[](validatorList.length);
    uint256[] memory commissionThousandthsList = new uint256[](validatorList.length);
    bytes[] memory voteAddrList = new bytes[](validatorList.length);

    for (uint256 i = 0; i < validatorList.length; ++i) {
      Candidate storage c = candidateMap[validatorList[i]];
      consensusAddrList[i] = c.consensusAddr;
      feeAddrList[i] = c.feeAddr;
      voteAddrList[i] = c.voteAddr;
      if (scores[i] == 0) {
        commissionThousandthsList[i] = 1000;
      } else {
        commissionThousandthsList[i] = c.commissionThousandths;
      }
      // Find index in candidateList for status update
      for (uint256 k = 0; k < candidateSize; k++) {
        if (candidateList[k] == validatorList[i]) {
          statusList[k] |= SET_VALIDATOR;
          break;
        }
      }
    }

    IValidatorSet(VALIDATOR_CONTRACT_ADDR).updateValidatorSet(validatorList, consensusAddrList, feeAddrList, commissionThousandthsList, voteAddrList, validatorCount);
    ISlashIndicator(SLASH_CONTRACT_ADDR).clean();
    IStakeHub(STAKE_HUB_ADDR).setNewRound(validatorList, roundTag);

    // Update jail status
    for (uint256 i = 0; i < candidateSize; i++) {
      address opAddr = candidateList[i];
      uint256 jailedRound = jailMap[opAddr];
      if (jailedRound != 0 && jailedRound <= roundTag) {
        statusList[i] = statusList[i] & DEL_JAIL;
        delete jailMap[opAddr];
      }
    }

    // Sync status changes
    for (uint256 i = 0; i < candidateSize; i++) {
      _changeStatus(candidateList[i], statusList[i]);
    }
    emit turnedRound(roundTag);
  }

  /****************** register/unregister ***************************/
  function register(address consensusAddr, address payable feeAddr, uint32 commissionThousandths, bytes calldata voteAddr)
    external payable
    onlyInit
  {
    require(candidateList.length <= CANDIDATE_COUNT_LIMIT, "maximum candidate size reached");
    require(!operateMap[msg.sender], "candidate already exists");
    require(msg.value >= requiredMargin, "deposit is not enough");
    require(commissionThousandths != 0 && commissionThousandths < 1000, "commissionThousandths should be in (0, 1000)");
    require(consensusMap[consensusAddr] == address(0), "consensus already exists");
    require(consensusAddr != address(0), "consensus address should not be zero");
    require(feeAddr != address(0), "fee address should not be zero");
    require(jailMap[msg.sender] < roundTag, "it is in jail");
    require(voteAddr.length == 48, "vote address length should be 48");

    // Check vote address uniqueness
    for (uint256 i = 0; i < candidateList.length; i++) {
      require(!BytesLib.equal(candidateMap[candidateList[i]].voteAddr, voteAddr), "vote address already exists");
    }

    candidateMap[msg.sender] = Candidate({
      operateAddr: msg.sender,
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
    candidateList.push(msg.sender);
    operateMap[msg.sender] = true;
    consensusMap[consensusAddr] = msg.sender;

    emit registered(msg.sender, consensusAddr, feeAddr, commissionThousandths, msg.value, voteAddr);
  }

  function unregister() external onlyInit onlyOperator {
    Candidate storage c = candidateMap[msg.sender];
    require(c.status == (c.status & UNREGISTER_STATUS), "candidate status is not cleared");
    uint256 margin = c.margin;

    _removeCandidate(msg.sender);

    if (margin > dues) {
      uint256 value = margin - dues;
      Address.sendValue(payable(msg.sender), value);
      payable(SYSTEM_REWARD_ADDR).transfer(uint256(dues));
    } else {
      payable(SYSTEM_REWARD_ADDR).transfer(margin);
    }
  }

  function updateAgent(address newAgent) external onlyOperator {
    require(newAgent != address(0), "agent address cannot be zero");
    require(agentMap[newAgent] == address(0), "agent address already exists");

    Candidate storage c = candidateMap[msg.sender];
    if (c.agent != address(0)) {
      delete agentMap[c.agent];
    }
    agentMap[newAgent] = msg.sender;
    c.agent = newAgent;
    emit AgentUpdated(msg.sender, newAgent);
  }

  function removeAgent() external onlyOperator {
    Candidate storage c = candidateMap[msg.sender];
    require(c.agent != address(0), "agent address does not exist");
    delete agentMap[c.agent];
    c.agent = address(0);
  }

  function editConsensusAddress(address newConsensusAddr) external {
    Candidate storage c = _getCandidate();
    require(consensusMap[newConsensusAddr] == address(0), "consensus already exists");
    consensusMap[newConsensusAddr] = c.operateAddr;
    delete consensusMap[c.consensusAddr];
    c.consensusAddr = newConsensusAddr;
    emit ConsensusAddressEdited(c.operateAddr, newConsensusAddr);
  }

  function editCommissionRate(uint32 newRate) external {
    Candidate storage c = _getCandidate();
    require(newRate != 0 && newRate < 1000, "commissionThousandths should in range (0, 1000)");
    uint256 commissionLastRoundValue = roundTag == c.commissionLastChangeRound
      ? c.commissionLastRoundValue
      : c.commissionThousandths;
    require(
      newRate + maxCommissionChange >= commissionLastRoundValue &&
        commissionLastRoundValue + maxCommissionChange >= newRate,
      "commissionThousandths out of adjustment range"
    );
    if (roundTag != c.commissionLastChangeRound) {
      c.commissionLastChangeRound = roundTag;
      c.commissionLastRoundValue = c.commissionThousandths;
    }
    c.commissionThousandths = newRate;
    emit CommissionRateEdited(c.operateAddr, newRate);
  }

  function editVoteAddress(bytes calldata voteAddr) external {
    Candidate storage c = _getCandidate();
    require(voteAddr.length == 48, "vote address length should be 48");
    for (uint256 i = 0; i < candidateList.length; i++) {
      require(!BytesLib.equal(candidateMap[candidateList[i]].voteAddr, voteAddr), "vote address already exists");
    }
    c.voteAddr = voteAddr;
    emit VoteAddressEdited(c.operateAddr, voteAddr);
  }

  function editFeeAddress(address payable newFeeAddr) external onlyOperator {
    require(newFeeAddr != address(0), "fee address cannot be zero");
    candidateMap[msg.sender].feeAddr = newFeeAddr;
    emit FeeAddressEdited(msg.sender, newFeeAddr);
  }

  function refuseDelegate() external onlyInit onlyOperator {
    uint256 status = candidateMap[msg.sender].status | SET_INACTIVE;
    _changeStatus(msg.sender, status);
  }

  function acceptDelegate() external onlyInit onlyOperator {
    uint256 status = candidateMap[msg.sender].status & DEL_INACTIVE;
    _changeStatus(msg.sender, status);
  }

  function addMargin() external payable onlyInit onlyOperator {
    require(msg.value != 0, "value should not be zero");
    Candidate storage c = candidateMap[msg.sender];
    uint256 totalMargin = c.margin + msg.value;
    c.margin = totalMargin;
    emit addedMargin(msg.sender, msg.value, totalMargin);
    if (totalMargin >= requiredMargin) {
      _changeStatus(msg.sender, c.status & DEL_MARGIN);
    }
  }

  /*************************** internal methods ******************************/

  function _getCandidate() internal view returns (Candidate storage) {
    if (operateMap[msg.sender]) {
      return candidateMap[msg.sender];
    }
    address operator = agentMap[msg.sender];
    require(operator != address(0), "candidate does not exist");
    return candidateMap[operator];
  }

  function _changeStatus(address operateAddr, uint256 newStatus) internal {
    Candidate storage c = candidateMap[operateAddr];
    uint256 oldStatus = c.status;
    if (oldStatus != newStatus) {
      c.status = newStatus;
      emit statusChanged(operateAddr, oldStatus, newStatus);
    }
  }

  function _removeCandidate(address operateAddr) internal {
    Candidate storage c = candidateMap[operateAddr];
    emit unregistered(operateAddr, c.consensusAddr);

    if (c.agent != address(0)) {
      delete agentMap[c.agent];
    }
    delete consensusMap[c.consensusAddr];
    delete operateMap[operateAddr];

    // Swap and pop from candidateList
    uint256 len = candidateList.length;
    for (uint256 i = 0; i < len; i++) {
      if (candidateList[i] == operateAddr) {
        candidateList[i] = candidateList[len - 1];
        candidateList.pop();
        break;
      }
    }

    delete candidateMap[operateAddr];
  }

  function getValidators(address[] memory candidateList_, uint256[] memory scoreList, uint256 count, uint256 sortedCount) internal pure returns (address[] memory validatorList){
    require(count > sortedCount, "count should be greater than sortedCount");
    uint256 candidateSize = candidateList_.length;
    if (candidateSize == 0) {
      return validatorList;
    }
    uint256 l = 0;
    uint256 r = 0;
    if (count < candidateSize) {
      r = candidateSize - 1;
    } else {
      count = candidateSize;
    }
    while (l < r) {
      uint256 ll = l;
      uint256 rr = r;
      address back = candidateList_[ll];
      uint256 p = scoreList[ll];
      while (ll < rr) {
        while (ll < rr && scoreList[rr] < p) {
          rr = rr - 1;
        }
        candidateList_[ll] = candidateList_[rr];
        scoreList[ll] = scoreList[rr];
        while (ll < rr && scoreList[ll] >= p) {
          ll = ll + 1;
        }
        candidateList_[rr] = candidateList_[ll];
        scoreList[rr] = scoreList[ll];
      }
      candidateList_[ll] = back;
      scoreList[ll] = p;
      uint256 mid = ll;
      if (mid < count) {
        l = mid + 1;
      } else if (mid > count) {
        r = mid - 1;
      } else {
        break;
      }
    }

    for (uint256 i = count - 1; i >= count - sortedCount; i--) {
      uint256 minIndex;
      for (uint256 j = 1; j <= i; j++) {
        if (scoreList[j] < scoreList[minIndex]) {
            minIndex = j;
        }
      }
      if (minIndex != i) {
          (candidateList_[i], candidateList_[minIndex]) = (candidateList_[minIndex], candidateList_[i]);
          (scoreList[i], scoreList[minIndex]) = (scoreList[minIndex], scoreList[i]);
      }
    }

    uint256 d = candidateSize - count;
    if (d != 0) {
      assembly {
        mstore(candidateList_, sub(mload(candidateList_), d))
      }
    }
    return candidateList_;
  }

  function nextRound() internal virtual {
    uint256 roundTimestamp = block.timestamp / SatoshiPlusHelper.ROUND_INTERVAL;
    require(roundTimestamp > roundTag, "not allowed to turn round, wait for more time");
    roundTag = roundTimestamp;
  }

  /*********************** Param update ********************************/
  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov {
    if (value.length != 32) {
      revert MismatchParamLength(key);
    }
    if (Memory.compareStrings(key, "requiredMargin")) {
      uint256 newRequiredMargin = BytesToTypes.bytesToUint256(32, value);
      if (newRequiredMargin <= dues) {
        revert OutOfBounds(key, newRequiredMargin, dues+1, type(uint256).max);
      }
      requiredMargin = newRequiredMargin;
    } else if (Memory.compareStrings(key, "dues")) {
      uint256 newDues = BytesToTypes.bytesToUint256(32, value);
      if (newDues == 0 || newDues >= requiredMargin) {
        revert OutOfBounds(key, newDues, 1, requiredMargin - 1);
      }
      dues = newDues;
    } else if (Memory.compareStrings(key, "validatorCount")) {
      uint256 newValidatorCount = BytesToTypes.bytesToUint256(32, value);
      if (newValidatorCount <= 5 || newValidatorCount >= 42) {
        revert OutOfBounds(key, newValidatorCount, 6, 41);
      }
      if (maxAlternateCount > newValidatorCount / 3) {
        revert OutOfBounds("maxAlternateCount", maxAlternateCount, 0, newValidatorCount / 3);
      }
      validatorCount = newValidatorCount;
    } else if (Memory.compareStrings(key, "maxCommissionChange")) {
      uint256 newMaxCommissionChange = BytesToTypes.bytesToUint256(32, value);
      if (newMaxCommissionChange == 0) {
        revert OutOfBounds(key, newMaxCommissionChange, 1, type(uint256).max);
      }
      maxCommissionChange = newMaxCommissionChange;
    } else if (Memory.compareStrings(key, "maxAlternateCount")) {
      uint256 newAlternateValidatorCount = BytesToTypes.bytesToUint256(32, value);
      if (newAlternateValidatorCount > validatorCount / 3) {
        revert OutOfBounds(key, newAlternateValidatorCount, 0, validatorCount / 3);
      }
      maxAlternateCount = newAlternateValidatorCount;
    } else {
      revert UnsupportedGovParam(key);
    }
    emit paramChange(key, value);
  }

  /*********************** View methods ********************************/
  function getCandidates() external view returns (address[] memory) {
    return candidateList;
  }

  function isCandidateByConsensus(address consensusAddr) external view returns (bool) {
    return consensusMap[consensusAddr] != address(0);
  }

  function isJailed(address operateAddr) external view returns (bool) {
    return jailMap[operateAddr] >= roundTag;
  }

  function getRoundInterval() external pure returns(uint256) {
    return SatoshiPlusHelper.ROUND_INTERVAL;
  }

  function getAlternateCount(uint256 _maxAlternateCount, uint256 _validatorCount, uint256 _candidateSize) internal pure returns (uint256) {
    if (_candidateSize <= _validatorCount) {
      _maxAlternateCount = 0;
    } else if (_candidateSize < _validatorCount + _maxAlternateCount) {
      _maxAlternateCount = _candidateSize - _validatorCount;
    }
    return _maxAlternateCount;
  }
}
