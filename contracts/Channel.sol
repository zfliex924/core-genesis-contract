// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./lib/Address.sol";
import "./interface/IChannel.sol";
import "./interface/ICoreAgent.sol";
import "./interface/IParamSubscriber.sol";
import "./lib/Memory.sol";
import "./lib/SatoshiPlusHelper.sol";
import "./System.sol";
import "./lib/BytesLib.sol";
import "./lib/BytesToTypes.sol";

contract Channel is IChannel, System, IParamSubscriber {
  using BytesLib for *;

  uint256 public constant INIT_REQUIRED_MARGIN = 1e22;
  uint256 public constant DEFAULT_COMMISSION_LIMIT = 2000;

  // the refundable deposit
  uint256 public requiredMargin;
  // the unregister feeAddress
  uint256 public dues;
  uint256 public commissionLimit;

  uint32 public partnerIdGenerator;
  mapping(uint256 => Partner) public partners;
  mapping(address => uint32) public partnerIdMap;

  mapping(address => uint32[]) public delegators;

  struct Partner {
    address operator;
    address feeAddress;
    uint16  coreCommissionRate;
    uint16  btcCommissionRate;
    uint8   status;
    uint256 margin;
    uint256 commission;
    mapping(address => uint256) delegatorAmounts;
  }

  modifier exist() {
    uint32 id = partnerIdMap[msg.sender];
    if (partners[id].status == 0) {
      revert NoPartner(id);
    }
    _;
  }

  /// There is insufficient amount
  /// @param required required amount.
  /// @param actual actual amount.
  error InsufficientAmount(uint256 required, uint256 actual);

  /// The msg sender is not allowed.
  /// @param id the partner id.
  error NoPartner(uint32 id);

  /// Register dublicated.
  /// @param addr user who tries to register.
  error DuplicateRegister(address addr);

  function init() external onlyNotInit {
    requiredMargin = INIT_REQUIRED_MARGIN;
    commissionLimit = DEFAULT_COMMISSION_LIMIT;
    alreadyInit = true;
  }

  /*********************** IChannel implementations ***************************/
  /// When claiming reward, user should pay commissions to the channel partner if bind.
  ///
  /// @param partnerId the id of channel partner
  /// @param reward the reward for total staked tx
  /// @return remainingReward the remain reward after pay commission.
  function payCommissionById(uint32 partnerId, uint256 reward) external override onlyCaller(BTC_STAKE_ADDR) returns (uint256 remainingReward) {
    if (partners[partnerId].status == 0) {
      return reward;
    }
    Partner storage p = partners[partnerId];
    uint256 commission = reward * p.btcCommissionRate / SatoshiPlusHelper.DENOMINATOR;
    p.commission += commission;
    remainingReward = reward - commission;
  }

  /// When claiming reward, user should pay commissions to the channel partner if bind.
  ///
  /// @param delegator the delegator address
  /// @param amount the staked amount
  /// @param reward the amount of rewards collected
  /// @return remainingReward the remain reward after pay commission.
  function payCommissions(address delegator, uint256 amount, uint256 reward) external override onlyCaller(CORE_AGENT_ADDR) returns (uint256 remainingReward) {
    if (reward == 0) {
      return reward;
    }
    uint32[] storage ids = delegators[delegator];
    remainingReward = reward;
    for (uint256 i = ids.length; i != 0; i--) {
      Partner storage p = partners[ids[i-1]];
      if (p.status == 0) {
        continue;
      }
      uint256 commission = p.delegatorAmounts[delegator] * p.coreCommissionRate / SatoshiPlusHelper.DENOMINATOR * reward / amount;
      p.commission += commission;
      remainingReward -= commission;
    }
  }

  /// Reset commission for partner
  ///
  /// @param partner the channel partner
  /// @return commission the Amount of commission
  /// @return feeAddress the fee address
  function resetCommission(address partner) external override onlyCaller(STAKE_HUB_ADDR) returns (uint256 commission, address feeAddress) {
    uint32 id = partnerIdMap[partner];
    if (id != 0 && partners[id].status != 0) {
      feeAddress = partners[id].feeAddress;
      commission = partners[id].commission;
      if (commission != 0) {
        partners[id].commission = 0;
      }
    }
  }

  /// This method is a callback when delegate undelegate coin.
  ///
  /// @param delegator the delegator address
  /// @param amount the undelegate amount
  function onUndelegateCoin(address delegator, uint256 amount) external override onlyCaller(CORE_AGENT_ADDR) {
    uint32[] storage ids = delegators[delegator];
    for (uint256 i = ids.length; amount != 0 && i != 0; i--) {
      uint32 tempId = ids[i-1];
      uint256 stakedAmount = partners[tempId].delegatorAmounts[delegator];
      if (stakedAmount > amount) {
        partners[tempId].delegatorAmounts[delegator] = stakedAmount - amount;
        break;
      } else {
        amount -= stakedAmount;
        delete partners[tempId].delegatorAmounts[delegator];
        ids.pop();
      }
    }
  }

  /*********************** External methods ***************************/
  /// Register as a channel partner
  function register(address feeAddress, uint16 coreCommissionRate, uint16 btcCommissionRate) external payable {
    uint32 id = partnerIdMap[msg.sender];
    if (partners[id].status != 0) {
      revert DuplicateRegister(msg.sender);
    }
    if (msg.value < requiredMargin) {
      revert InsufficientAmount(requiredMargin, msg.value);
    }
    if (coreCommissionRate > commissionLimit) {
      revert OutOfBounds('coreCommissionRate', coreCommissionRate, 0, commissionLimit);
    }
    if (btcCommissionRate > commissionLimit) {
      revert OutOfBounds('btcCommissionRate', btcCommissionRate, 0, commissionLimit);
    }
    if (id == 0) {
      id = ++partnerIdGenerator;
      partnerIdMap[msg.sender] = id;
    }
    Partner storage p = partners[id];
    p.operator = msg.sender;
    p.feeAddress = feeAddress;
    p.coreCommissionRate = coreCommissionRate;
    p.btcCommissionRate = btcCommissionRate;
    p.status = 1;
    p.margin = msg.value;
  }

  /// Unregister from a channel partner
  function unregister() external exist {
    Partner storage p = partners[partnerIdMap[msg.sender]];
    p.status = 0;

    uint256 margin = p.margin;
    if (margin > dues) {
      uint256 value = margin - dues;
      Address.sendValue(payable(msg.sender), value);
      if (dues > 0) {
        payable(SYSTEM_REWARD_ADDR).transfer(uint256(dues));
      }
    } else {
      payable(SYSTEM_REWARD_ADDR).transfer(margin);
    }
  }

  /// Set the fee address
  /// @param _feeAddress The new fee address
  function setFeeAddress(address _feeAddress) external exist {
    partners[partnerIdMap[msg.sender]].feeAddress = _feeAddress;
  }

  /// Set the core commission rate
  /// @param coreCommissionRate The new value
  function setCoreCommissionRate(uint16 coreCommissionRate) external exist {
    if (coreCommissionRate > commissionLimit) {
      revert OutOfBounds('coreCommissionRate', coreCommissionRate, 0, commissionLimit);
    }
    partners[partnerIdMap[msg.sender]].coreCommissionRate = coreCommissionRate;
  }

  /// Set the btc commission rate
  /// @param btcCommissionRate The new value
  function setBtcCommissionRate(uint16 btcCommissionRate) external exist {
    if (btcCommissionRate > commissionLimit) {
      revert OutOfBounds('btcCommissionRate', btcCommissionRate, 0, commissionLimit);
    }
    partners[partnerIdMap[msg.sender]].btcCommissionRate = btcCommissionRate;
  }

  /// Get the staking amount of special id & delegator.
  function getDelegatorAmount(uint32 id, address delegator) external view returns (uint256) {
    return partners[id].delegatorAmounts[delegator];
  }

  /// Get the id array for the delegator.
  function getIds(address delegator) external view returns (uint32[] memory) {
    return delegators[delegator];
  }

  /*********************** External methods ***************************/
  /// stake CORE from a partner channel
  /// @param candidate The operator address of validator
  /// @param id The partner id
  function delegateCoin(address candidate, uint32 id) external payable {
    if (partners[id].status == 0) {
      revert NoPartner(id);
    }
    address delegator = msg.sender;
    uint256 amount = msg.value;
    ICoreAgent(CORE_AGENT_ADDR).proxyDelegate{value: amount}(candidate, delegator, id);
    Partner storage p = partners[id];
    uint256 existAmount = p.delegatorAmounts[delegator];
    if (existAmount == 0) {
      delegators[delegator].push(id);
    }
    p.delegatorAmounts[delegator] = existAmount + amount;
  }

  /*********************** Governance ********************************/
  /// Update parameters through governance vote
  /// @param key The name of the parameter
  /// @param value the new value set to the parameter
  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyCaller(GOV_HUB_ADDR) {
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
    } else if (Memory.compareStrings(key, "commissionLimit")) {
      uint256 newRate = BytesToTypes.bytesToUint256(32, value);
      if (newRate > SatoshiPlusHelper.DENOMINATOR) {
        revert OutOfBounds('commissionLimit', newRate, 0, SatoshiPlusHelper.DENOMINATOR);
      }
      commissionLimit = newRate;
    } else {
      revert UnsupportedGovParam(key);
    }

    emit paramChange(key, value);
  }
}