// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./System.sol";
import "./lib/BytesToTypes.sol";
import "./lib/Memory.sol";
import "./lib/BytesLib.sol";
import "./interface/IParamSubscriber.sol";

interface IBeforeTurnRoundCallBack {
  function beforeTurnRound() external;
}

interface IAfterTurnRoundCallBack {
  function afterTurnRound() external;
}

contract Schedule is System, IParamSubscriber {
  
  uint256 public constant MAX_GAS = 1e6;
  uint256 public constant TASK_SIZE_LIMIT = 5;
  uint256 public constant ENUM_AFTER_TURN_ROUND = 1;
  uint256 public constant ENUM_BEFORE_TURN_ROUND = 2;

  struct ScheduleTask {
    address registerAddr;
    address targetAddr;
    uint256 funcType;
  }

  mapping(address => uint256) public targetMap;
  ScheduleTask[] public taskList;
  uint256 maxGas;

  /*********************** events **************************/
  event paramChange(string key, bytes value);
  event taskState(address registerAddr, address indexed targetAddr, uint256 funcType);
  event beforeTurnRoundResult(address indexed targetAddr, bool success);
  event afterTurnRoundResult(address indexed targetAddr, bool success);
  /*********************** init **************************/
  function init() public onlyNotInit {
    maxGas = MAX_GAS;
    alreadyInit = true;
  }

  /********************* External methods  ****************************/
  function register(address registerAddr, address targetAddr, uint256 funcType) external onlyInit onlyGov {
    require(funcType > 0 && funcType <= (ENUM_AFTER_TURN_ROUND | ENUM_BEFORE_TURN_ROUND), "funcType not exsit");
    require(taskList.length < TASK_SIZE_LIMIT, "task size limit");
    uint256 index = targetMap[targetAddr];
    if (index == 0) {
      taskList.push(ScheduleTask(registerAddr, targetAddr, funcType));
      targetMap[targetAddr] = taskList.length;
      emit taskState(registerAddr, targetAddr, funcType);
    } else {
      taskList[index - 1].registerAddr = registerAddr;
      taskList[index - 1].funcType |= funcType;
      emit taskState(registerAddr, targetAddr, taskList[index - 1].funcType);
    }
  }

  function unregister(address targetAddr, uint256 funcType) external onlyInit {
    require(funcType > 0 && funcType <= (ENUM_AFTER_TURN_ROUND | ENUM_BEFORE_TURN_ROUND), "funcType not exsit");
    uint256 index = targetMap[targetAddr];
    require(index != 0, "target not exists");
    require(msg.sender == GOV_HUB_ADDR || msg.sender == taskList[index-1].registerAddr, "not allow to unregister");
    taskList[index - 1].funcType &= ~funcType;
    funcType =  taskList[index - 1].funcType;
    emit taskState(taskList[index - 1].registerAddr, targetAddr, funcType);
    if(funcType == 0) {
      if (index != taskList.length) {
        taskList[index-1] = taskList[taskList.length-1];
      }
      taskList.pop();
      delete targetMap[targetAddr];
    }
  }

  function beforeTurnRound() external onlyCoinbase onlyZeroGasPrice {
    if(!alreadyInit){
      init();
    }

    uint256 length = taskList.length;
    for(uint256 i = 0; i < length; ++i) {
      ScheduleTask storage st = taskList[i];
      if ((st.funcType & ENUM_BEFORE_TURN_ROUND) != 0) {
        try IBeforeTurnRoundCallBack(st.targetAddr).beforeTurnRound{ gas: maxGas }() {
          emit beforeTurnRoundResult(st.targetAddr, true);
        } catch {
          emit beforeTurnRoundResult(st.targetAddr, false);
        }
      }
    }
  }

  function afterTurnRound() external onlyCoinbase onlyZeroGasPrice {
    if(!alreadyInit){
      init();
    }

    uint256 length = taskList.length;
    for(uint256 i = 0; i < length; ++i) {
      ScheduleTask storage st = taskList[i];
      if ((st.funcType & ENUM_AFTER_TURN_ROUND) != 0) {
        try IAfterTurnRoundCallBack(st.targetAddr).afterTurnRound{ gas: maxGas }() {
          emit afterTurnRoundResult(st.targetAddr, true);
        } catch {
          emit afterTurnRoundResult(st.targetAddr, false);
        }
      }
    }
  }

  /*********************** Param update ********************************/
  /// Update parameters through governance vote
  /// @param key The name of the parameter
  /// @param value the new value set to the parameter
  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov {
    if (value.length != 32) {
      revert MismatchParamLength(key);
    }
    if (Memory.compareStrings(key, "maxGas")) {
      uint256 newMaxGas = BytesToTypes.bytesToUint256(32, value);
      if (newMaxGas > 1e6 || newMaxGas < 1e5) {
        revert OutOfBounds(key, newMaxGas, 1e5, 1e6);
      }
      maxGas = newMaxGas;
    } else {
      require(false, "unknown param");
    }
    emit paramChange(key, value);
  }
}
