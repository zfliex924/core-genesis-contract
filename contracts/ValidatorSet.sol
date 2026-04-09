// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./System.sol";
import "./lib/BytesToTypes.sol";
import "./lib/Memory.sol";
import "./interface/IParamSubscriber.sol";
import "./interface/IValidatorSet.sol";
import "./interface/ISlashIndicator.sol";
import "./interface/IStakeHub.sol";
import "./interface/ISystemReward.sol";
import "./interface/ICandidateHub.sol";
import "./lib/RLPDecode.sol";

/// This contract manages elected validators in each round
/// All rewards for validators on Core blockchain are minted in genesis block and stored in this contract
contract ValidatorSet is IValidatorSet, System, IParamSubscriber {
  using RLPDecode for bytes;
  using RLPDecode for RLPDecode.Iterator;
  using RLPDecode for RLPDecode.RLPItem;

  uint256 public constant BLOCK_REWARD = 3e18;
  uint256 public constant BLOCK_REWARD_INCENTIVE_PERCENT = 10;
  uint256 public constant REDUCE_FACTOR = 9639;
  uint256 public constant SUBSIDY_REDUCE_INTERVAL = 10512000;
  uint256 public constant INIT_TURN_LENGTH = 1;

  bytes public constant INIT_VALIDATORSET_BYTES = hex"f90573f85b944121f067b0f5135d77c29b2b329e8cb1bd96c96094f8b18cecc98d976ad253d38e4100a73d4e154726b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f85b947f461f8a1c35edecd6816e76eb2e84eb661751ee94f8b18cecc98d976ad253d38e4100a73d4e154726b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f85b94fd806ab93db5742944b7b50ce759e5eee5f6fe5094f8b18cecc98d976ad253d38e4100a73d4e154726b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f85b947ef3a94ad1c443481fb3d86829355ca90477f8b594f8b18cecc98d976ad253d38e4100a73d4e154726b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f85b9467d1ad48f91e131413bd0b04e823f3ae4f81e85394f8b18cecc98d976ad253d38e4100a73d4e154726b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f85b943fb42cab4416024dc1b4c9e21b9acd0dfcef35f694f8b18cecc98d976ad253d38e4100a73d4e154726b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f85b943511e3b8ac7336b99517d324145e9b5bb33e08a494f8b18cecc98d976ad253d38e4100a73d4e154726b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f85b94729f39a54304fcc6ec279684c71491a385d7b9ae94f8b18cecc98d976ad253d38e4100a73d4e154726b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f85b94f44a785fd9f23f0abd443541386e71356ce619dc94f8b18cecc98d976ad253d38e4100a73d4e154726b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f85b942efd3cf0733421aec3e4202480d0a90bd157514994f8b18cecc98d976ad253d38e4100a73d4e154726b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f85b94613b0f519ada008cb99b6130e89122ba416bf15994f8b18cecc98d976ad253d38e4100a73d4e154726b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f85b94c0925eeb800ff6ba4695ded61562a10102152b5f94f8b18cecc98d976ad253d38e4100a73d4e154726b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f85b9419e3c7d7e69f273f3f91c060bb438a007f6fc33c94f8b18cecc98d976ad253d38e4100a73d4e154726b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f85b94e127f110d172a0c4c6209fe045dd71781e8fe9d494f8b18cecc98d976ad253d38e4100a73d4e154726b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f85b94f778dc4a199a440dbe9f16d1e13e185bb179b3b794f8b18cecc98d976ad253d38e4100a73d4e154726b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

  /*********************** state of the contract **************************/
  uint256 public blockReward;
  uint256 public blockRewardIncentivePercent;
  uint256 public totalInCome;

  uint256 public voteRewardPercent;
  uint256 public maintainSlashPercent;
  uint256 public validatorCount;
  uint256 public turnLength;

  address[] public validatorList;
  address[] public rankedValidatorList;

  // key is the `consensusAddress` of `Validator`
  mapping(address => Validator) public currentValidatorSetMap;

  struct Validator {
    address operateAddress;
    address consensusAddress;
    address payable feeAddress;
    uint256 commissionThousandths;
    uint256 income;
    bytes voteAddr;
    uint256 voteWeight;
    uint256 enterMaintenanceHeight;
  }

  /*********************** events **************************/
  event validatorSetUpdated();
  event systemTransfer(uint256 amount);
  event directTransfer(
    address indexed operateAddress,
    address payable indexed validator,
    uint256 amount,
    uint256 totalReward
  );
  event directTransferFail(
    address indexed operateAddress,
    address payable indexed validator,
    uint256 amount,
    uint256 totalReward
  );
  event voteRewardTransfer(
    address indexed operateAddress,
    address payable indexed validator,
    uint256 amount
  );
  event voteRewardTransferFail(
    address indexed operateAddress,
    address payable indexed validator,
    uint256 amount
  );
  event deprecatedDeposit(address indexed validator, uint256 amount);
  event validatorDeposit(address indexed validator, uint256 amount);
  event validatorMisdemeanor(address indexed validator, uint256 amount);
  event validatorFelony(address indexed validator, uint256 amount);
  event received(address indexed from, uint256 amount);
  event validatorEnterMaintenance(address indexed validator);
  event validatorExitMaintenance(address indexed validator);

  /*********************** init **************************/
  function init() external onlyNotInit {
    (bool valid) = decodeValidatorSet(INIT_VALIDATORSET_BYTES);
    require(valid, "failed to parse init validatorSet");

    blockReward = BLOCK_REWARD;
    blockRewardIncentivePercent = BLOCK_REWARD_INCENTIVE_PERCENT;
    turnLength = INIT_TURN_LENGTH;
    alreadyInit = true;
  }

  /*********************** External Functions **************************/
  /// Check whether the input address belongs to an active validator
  /// @param addr The address to check
  /// @return true/false
  function isValidator(address addr) public override view returns (bool) {
    return currentValidatorSetMap[addr].consensusAddress != address(0);
  }

  receive() external payable {
    if (msg.value != 0) {
      emit received(msg.sender, msg.value);
    }
  }

  /// Add block reward on a validator
  /// @dev This method is called by the golang consensus engine every block
  /// @param valAddr The validator address
  function deposit(address valAddr) external payable onlyCoinbase onlyInit onlyZeroGasPrice {
    if (block.number % SUBSIDY_REDUCE_INTERVAL == 0) {
      blockReward = blockReward * REDUCE_FACTOR / 10000;
    }
    uint256 value = msg.value;
    if (address(this).balance >= totalInCome + value + blockReward) {
      value += blockReward;
    }
    Validator storage validator = currentValidatorSetMap[valAddr];
    if (validator.consensusAddress != address(0)) {
      totalInCome = totalInCome + value;
      validator.income = validator.income + value;
      emit validatorDeposit(valAddr, value);
    } else {
      emit deprecatedDeposit(valAddr, value);
    }
  }

  function vote(address[] calldata valAddrs, uint256[] calldata weights) external onlyCoinbase onlyInit onlyZeroGasPrice {
    require(valAddrs.length == weights.length, "length not equal");

    for (uint256 i; i < valAddrs.length; ++i) {
      Validator storage v = currentValidatorSetMap[valAddrs[i]];
      if (v.consensusAddress != address(0)) {
        v.voteWeight += weights[i];
      }
    }
  }

  function exitMaintenanceTurnRound() external override onlyCandidate {
    uint256 len = validatorList.length;
    address[] memory valAddrs = new address[](len);
    uint256 j;
    for (uint256 i; i < len; ++i) {
      if (currentValidatorSetMap[validatorList[i]].enterMaintenanceHeight != 0) {
        valAddrs[j++] = validatorList[i];
      }
    }

    for (uint256 i; i < j; ++i) {
      _exitMaintenance(valAddrs[i]);
    }
  }

  /// Distribute rewards to validators (and delegators through StakeHub)
  /// @dev this method is called by the CandidateHub contract at the beginning of turn round
  /// @dev this is where we deal with reward distribution logics
  function distributeReward(uint256 roundTag) external override onlyCandidate returns (address[] memory operateAddressList) {
    address payable feeAddress;

    uint256 incentiveSum = 0;
    uint256 voteWeightSum;
    uint256 validatorSize = validatorList.length;
    for (uint256 i = 0; i < validatorSize; i++) {
      Validator storage v = currentValidatorSetMap[validatorList[i]];
      uint256 incentiveValue = (v.income * blockRewardIncentivePercent) / 100;
      incentiveSum += incentiveValue;
      v.income -= incentiveValue;
      voteWeightSum += v.voteWeight;
    }
    ISystemReward(SYSTEM_REWARD_ADDR).receiveRewards{ value: incentiveSum }();

    uint256 vrPercent = voteWeightSum == 0 ? 0 : voteRewardPercent;

    operateAddressList = new address[](validatorSize);
    uint256[] memory rewardList = new uint256[](validatorSize);
    uint256 rewardSum;
    uint256 tempIncome;
    uint256 voteRewardSum;
    for (uint256 i = 0; i < validatorSize; i++) {
      Validator storage v = currentValidatorSetMap[validatorList[i]];
      operateAddressList[i] = v.operateAddress;
      tempIncome = v.income;
      if (tempIncome != 0) {
        feeAddress = v.feeAddress;
        uint256 validatorReward = (tempIncome * v.commissionThousandths) / 1000;
        if (tempIncome > validatorReward) {
          rewardList[i] = tempIncome - validatorReward;
          rewardSum += rewardList[i];
        }

        v.income = 0;
        uint256 voteReward = validatorReward * vrPercent / 100;
        validatorReward -= voteReward;
        voteRewardSum += voteReward;
        bool success = feeAddress.send(validatorReward);
        if (success) {
          emit directTransfer(v.operateAddress, feeAddress, validatorReward, tempIncome);
        } else {
          emit directTransferFail(v.operateAddress, feeAddress, validatorReward, tempIncome);
        }
      }
    }

    if (voteRewardSum != 0) {
      for (uint256 i = 0; i < validatorSize; i++) {
        Validator storage v = currentValidatorSetMap[validatorList[i]];
        if (v.voteWeight != 0) {
          uint256 reward = voteRewardSum * v.voteWeight / voteWeightSum;
          bool success = v.feeAddress.send(reward);
          if(success) {
            emit voteRewardTransfer(v.operateAddress, v.feeAddress, reward);
          } else {
            emit voteRewardTransferFail(v.operateAddress, v.feeAddress, reward);
          }
        }
      }
    }

    IStakeHub(STAKE_HUB_ADDR).addRoundReward{ value: rewardSum }(operateAddressList, rewardList, roundTag);
    totalInCome = 0;
    return operateAddressList;
  }

  /// Update validator set of the new round with elected validators
  /// @param operateAddrList List of validator operator addresses
  /// @param consensusAddrList List of validator consensus addresses
  /// @param feeAddrList List of validator fee addresses
  /// @param commissionThousandthsList List of validator commission fees in thousandth
  function updateValidatorSet(
    address[] calldata operateAddrList,
    address[] calldata consensusAddrList,
    address payable[] calldata feeAddrList,
    uint256[] calldata commissionThousandthsList,
    bytes[] calldata voteAddrList,
    uint256 _validatorCount
  ) external override onlyCandidate {
    checkValidatorSet(operateAddrList, consensusAddrList, feeAddrList, commissionThousandthsList, voteAddrList);
    if (consensusAddrList.length == 0) {
      return;
    }

    validatorCount = _validatorCount;
    updateRankedValidatorList(consensusAddrList);

    // Clear old validator set
    uint256 lastLength = validatorList.length;
    for (uint256 i = 0; i < lastLength; i++) {
      delete currentValidatorSetMap[validatorList[i]];
    }

    // Rebuild validatorList
    uint256 currentLength = consensusAddrList.length;
    for (uint256 i = currentLength; i < lastLength; i++) {
      validatorList.pop();
    }

    for (uint256 i = 0; i < currentLength; ++i) {
      Validator storage v = currentValidatorSetMap[consensusAddrList[i]];
      v.operateAddress = operateAddrList[i];
      v.consensusAddress = consensusAddrList[i];
      v.feeAddress = feeAddrList[i];
      v.commissionThousandths = commissionThousandthsList[i];
      v.income = 0;
      v.voteAddr = voteAddrList[i];
      v.voteWeight = 0;
      v.enterMaintenanceHeight = 0;

      if (i >= lastLength) {
        validatorList.push(consensusAddrList[i]);
      } else {
        validatorList[i] = consensusAddrList[i];
      }
    }

    emit validatorSetUpdated();
  }

  function canEnterMaintenance(address consensusAddress) public view returns (bool) {
    if (currentValidatorSetMap[consensusAddress].consensusAddress == address(0)) {
      return false;
    }
    uint256 working = getWorkingCount();
    if (currentValidatorSetMap[consensusAddress].enterMaintenanceHeight != 0 || working <= 1 || validatorCount >= working || validatorCount == 0) {
      return false;
    }
    return true;
  }

  function enterMaintenance() external {
    address consensusAddress = _getConsensusFromOps(msg.sender);
    require(consensusAddress != address(0), "not a validator");
    require(canEnterMaintenance(consensusAddress), "can not enter Temporary Maintenance");
    _enterMaintenance(consensusAddress);
  }

  function enterMaintenance(address val) external override onlySlash {
    if (canEnterMaintenance(val)) {
      _enterMaintenance(val);
    }
  }

  function exitMaintenance() external {
    address consensusAddress = _getConsensusFromOps(msg.sender);
    require(consensusAddress != address(0), "not a validator");
    require(currentValidatorSetMap[consensusAddress].enterMaintenanceHeight != 0, "not in Temporary Maintenance");
    _exitMaintenance(consensusAddress);
  }

  /// Get list of validators in the current round
  /// @return List of validator consensus addresses
  function getValidators() external view returns (address[] memory) {
    return validatorList;
  }

  /// Get ops list of validators in the current round
  /// @return List of validator operate addresses
  function getValidatorOps() external override view returns (address[] memory) {
    uint256 validatorSize = validatorList.length;
    address[] memory opAddrs = new address[](validatorSize);
    for (uint256 i = 0; i < validatorSize; i++) {
      opAddrs[i] = currentValidatorSetMap[validatorList[i]].operateAddress;
    }
    return opAddrs;
  }

  /// Get list of validators and list of voting addresses in the current round
  /// @return (List of validator consensus addresses, List of voting addresses)
  function getValidatorsAndVoteAddresses() external override view returns (address[] memory, bytes[] memory) {
    uint256 validatorSize = validatorList.length;
    uint256 workingRankedValidatorLen;
    address[] memory workingRankedValidatorList;
    if (validatorCount == 0) {
      workingRankedValidatorList = getWorkingValidators();
      workingRankedValidatorLen = workingRankedValidatorList.length;
      validatorSize = workingRankedValidatorLen;
    } else {
      uint256 len = rankedValidatorList.length;
      for (uint256 i = 0; i < len; ++i) {
        address addr = rankedValidatorList[i];
        if (currentValidatorSetMap[addr].consensusAddress != address(0) && currentValidatorSetMap[addr].enterMaintenanceHeight == 0) {
          ++workingRankedValidatorLen;
        }
      }
      workingRankedValidatorList = new address[](workingRankedValidatorLen);
      uint256 j = 0;
      for (uint256 i = 0; i < len; ++i) {
        address addr = rankedValidatorList[i];
        if (currentValidatorSetMap[addr].consensusAddress != address(0) && currentValidatorSetMap[addr].enterMaintenanceHeight == 0) {
          workingRankedValidatorList[j++] = addr;
        }
      }
      validatorSize = validatorCount;
    }

    if (validatorSize > workingRankedValidatorLen) {
      validatorSize = workingRankedValidatorLen;
    }

    address[] memory consensusAddrs = new address[](validatorSize);
    bytes[] memory voteAddrs = new bytes[](validatorSize);

    uint256 pushedCount;
    for (uint256 i; pushedCount < validatorSize && i < workingRankedValidatorLen; ++i) {
      address addr = workingRankedValidatorList[i];
      consensusAddrs[pushedCount] = addr;
      voteAddrs[pushedCount] = currentValidatorSetMap[addr].voteAddr;
      ++pushedCount;
    }

    return (consensusAddrs, voteAddrs);
  }

  /// Get incoming, which is the reward to distribute at the end of the round, of a validator
  /// @param validator The validator address
  /// @return The incoming reward of the validator
  function getIncoming(address validator) external view returns (uint256) {
    return currentValidatorSetMap[validator].income;
  }

  /// Get the complete ranked validator list
  /// @return List of ranked validator consensus addresses
  function getRankedValidatorList() external view returns (address[] memory) {
    return rankedValidatorList;
  }

  /// Get the list of validators that are still in the validator set
  /// @return (List of validator consensus addresses, List of voting addresses)
  function getLivingValidators() external view override returns (address[] memory, bytes[] memory) {
    uint256 len = validatorList.length;
    address[] memory consensusAddrs = new address[](len);
    bytes[] memory voteAddrs = new bytes[](len);

    for (uint256 i = 0; i < len; i++) {
      address addr = validatorList[i];
      consensusAddrs[i] = addr;
      voteAddrs[i] = currentValidatorSetMap[addr].voteAddr;
    }

    return (consensusAddrs, voteAddrs);
  }

  /*********************** For slash **************************/
  /// Slash the validator for misdemeanor behaviors
  /// @param validator The validator to slash
  function misdemeanor(address validator) external override onlySlash {
    Validator storage v = currentValidatorSetMap[validator];
    if (v.consensusAddress == address(0)) {
      return;
    }
    uint256 income = v.income;
    v.income = 0;
    uint256 len = validatorList.length;
    uint256 rest = len - 1;
    emit validatorMisdemeanor(v.operateAddress, income);
    if (rest == 0) {
      return;
    }
    uint256 averageDistribute = income / rest;
    if (averageDistribute != 0) {
      for (uint256 i = 0; i < len; i++) {
        if (validatorList[i] == validator) continue;
        currentValidatorSetMap[validatorList[i]].income += averageDistribute;
      }
    }
  }

  /// Slash the validator for felony behaviors
  /// @param validator The validator to slash
  /// @param felonyRound The number of rounds to jail
  /// @param felonyDeposit The amount of deposits to slash
  function felony(address validator, uint256 felonyRound, uint256 felonyDeposit) external override onlySlash {
    Validator storage v = currentValidatorSetMap[validator];
    if (v.consensusAddress == address(0)) {
      return;
    }
    uint256 income = v.income;
    uint256 rest = validatorList.length - 1;
    if (rest == 0) {
      v.income = 0;
      return;
    }

    address operateAddress = v.operateAddress;
    emit validatorFelony(operateAddress, income);
    delete currentValidatorSetMap[validator];

    // swap-and-pop from validatorList
    uint256 len = validatorList.length;
    for (uint256 i = 0; i < len; i++) {
      if (validatorList[i] == validator) {
        validatorList[i] = validatorList[len - 1];
        validatorList.pop();
        break;
      }
    }

    uint256 averageDistribute = income / rest;
    if (averageDistribute != 0) {
      uint256 n = validatorList.length;
      for (uint256 i = 0; i < n; i++) {
        currentValidatorSetMap[validatorList[i]].income += averageDistribute;
      }
    }
    ICandidateHub(CANDIDATE_HUB_ADDR).jailValidator(operateAddress, felonyRound, felonyDeposit);
  }

  /*********************** Param update ********************************/
  /// Update parameters through governance vote
  /// @param key The name of the parameter
  /// @param value the new value set to the parameter
  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov {
    if (value.length != 32) {
      revert MismatchParamLength(key);
    }
    if (Memory.compareStrings(key, "blockRewardIncentivePercent")) {
      uint256 newBlockRewardIncentivePercent = BytesToTypes.bytesToUint256(32, value);
      if (newBlockRewardIncentivePercent > 100) {
        revert OutOfBounds(key, newBlockRewardIncentivePercent, 0, 100);
      }
      blockRewardIncentivePercent = newBlockRewardIncentivePercent;
    } else if (Memory.compareStrings(key, "voteRewardPercent")) {
      uint256 newVoteRewardPercent = BytesToTypes.bytesToUint256(32, value);
      if (newVoteRewardPercent > 100) {
        revert OutOfBounds(key, newVoteRewardPercent, 0, 100);
      }
      voteRewardPercent = newVoteRewardPercent;
    } else if (Memory.compareStrings(key, "maintainSlashPercent")) {
      uint256 newMaintainSlashPercent = BytesToTypes.bytesToUint256(32, value);
      if (newMaintainSlashPercent > 100) {
        revert OutOfBounds(key, newMaintainSlashPercent, 0, 100);
      }
      maintainSlashPercent = newMaintainSlashPercent;
    } else if (Memory.compareStrings(key, "turnLength")) {
      uint256 newTurnLength = BytesToTypes.bytesToUint256(32, value);
      if (newTurnLength == 0 || newTurnLength > 9) {
        revert OutOfBounds(key, newTurnLength, 1, 9);
      }
      turnLength = newTurnLength;
    } else {
      revert UnsupportedGovParam(key);
    }
    emit paramChange(key, value);
  }

  /*********************** Internal Functions **************************/
  function checkValidatorSet(
    address[] calldata operateAddrList,
    address[] calldata consensusAddrList,
    address payable[] calldata feeAddrList,
    uint256[] calldata commissionThousandthsList,
    bytes[] calldata voteAddrList
  ) private pure {
    require(
      consensusAddrList.length == operateAddrList.length,
      "the numbers of consensusAddresses and operateAddresses should be equal"
    );
    require(
      consensusAddrList.length == feeAddrList.length,
      "the numbers of consensusAddresses and feeAddresses should be equal"
    );
    require(
      consensusAddrList.length == commissionThousandthsList.length,
      "the numbers of consensusAddresses and commissionThousandthss should be equal"
    );
    require(
      consensusAddrList.length == voteAddrList.length,
      "the numbers of consensusAddresses and voteAddressed should be equal"
    );
    for (uint256 i = 0; i < consensusAddrList.length; i++) {
      for (uint256 j = 0; j < i; j++) {
        require(consensusAddrList[i] != consensusAddrList[j], "duplicate consensus address");
      }
      require(commissionThousandthsList[i] <= 1000, "commissionThousandths out of bound");
    }
  }

  function updateRankedValidatorList(address[] calldata consensusAddrList) internal {
    uint256 currentLength = consensusAddrList.length;
    uint256 lastRankedValLength = rankedValidatorList.length;

    for (uint256 i = currentLength; i < lastRankedValLength; i++) {
      rankedValidatorList.pop();
    }

    for (uint256 i = 0; i < currentLength; ++i) {
      if (i >= lastRankedValLength) {
        rankedValidatorList.push(consensusAddrList[i]);
      } else {
        rankedValidatorList[i] = consensusAddrList[i];
      }
    }
  }

  function getWorkingCount() public view returns (uint256) {
    uint256 len = validatorList.length;
    uint256 working;
    for (uint256 i; i < len; ++i) {
      if (currentValidatorSetMap[validatorList[i]].enterMaintenanceHeight == 0) {
        ++working;
      }
    }
    return working;
  }

  function getWorkingValidators() public view returns (address[] memory) {
    uint256 len = validatorList.length;
    uint256 working = getWorkingCount();
    address[] memory workingValidators = new address[](working);
    uint256 j;
    for (uint256 i; i < len; ++i) {
      address addr = validatorList[i];
      if (currentValidatorSetMap[addr].enterMaintenanceHeight == 0) {
        workingValidators[j++] = addr;
      }
    }
    return workingValidators;
  }

  /// Get turn length
  /// @return The turn length, returns INIT_TURN_LENGTH if turnLength is 0
  function getTurnLength() public view returns (uint256) {
    if (turnLength == 0) {
      return INIT_TURN_LENGTH;
    }
    return turnLength;
  }

  function _getConsensusFromOps(address ops) internal view returns (address) {
    uint256 len = validatorList.length;
    for (uint256 i = 0; i < len; i++) {
      address addr = validatorList[i];
      if (currentValidatorSetMap[addr].operateAddress == ops) {
        return addr;
      }
    }
    return address(0);
  }

  function decodeValidatorSet(bytes memory msgBytes) internal returns (bool) {
    RLPDecode.RLPItem[] memory items = msgBytes.toRLPItem().toList();
    uint256 itemSize = items.length;
    for (uint256 i = 0; i < itemSize; i++) {
      (Validator memory val, bool ok) = decodeValidator(items[i]);
      if (!ok) {
        return false;
      }
      currentValidatorSetMap[val.consensusAddress] = val;
      validatorList.push(val.consensusAddress);
    }
    return itemSize != 0;
  }

  function decodeValidator(RLPDecode.RLPItem memory itemValidator) internal pure returns (Validator memory validator, bool) {
    RLPDecode.Iterator memory iter = itemValidator.iterator();
    bool success = iter.hasNext();
    while (iter.hasNext() && success) {
      validator.consensusAddress = iter.next().toAddress();
      validator.feeAddress = payable(iter.next().toAddress());
      validator.operateAddress = validator.feeAddress;
      validator.voteAddr = iter.next().toBytes();
      validator.commissionThousandths = 1000;
      if (validator.voteAddr.length != 48) {
        success = false;
      }
    }
    return (validator, success);
  }

  function _enterMaintenance(address validator) internal {
    currentValidatorSetMap[validator].enterMaintenanceHeight = block.number;
    emit validatorEnterMaintenance(validator);
  }

  function _exitMaintenance(address validator) internal {
    uint256 working = validatorList.length;
    if (working > validatorCount) {
      working = validatorCount;
    }
    uint256 slashCount = (block.number - currentValidatorSetMap[validator].enterMaintenanceHeight) / working * maintainSlashPercent / 100;
    currentValidatorSetMap[validator].enterMaintenanceHeight = 0;

    if (slashCount != 0) {
      ISlashIndicator(SLASH_CONTRACT_ADDR).exitMaintenanceSlash(validator, slashCount);
    }
    emit validatorExitMaintenance(validator);
  }
}
