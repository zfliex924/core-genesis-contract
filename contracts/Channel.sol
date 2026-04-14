// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./lib/Address.sol";
import "./interface/IChannel.sol";
import "./interface/INativeAgent.sol";
import "./interface/IZecAgent.sol";
import "./interface/IParamSubscriber.sol";
import "./lib/Memory.sol";
import "./lib/SatoshiPlusHelper.sol";
import "./System.sol";
import "./lib/BytesLib.sol";
import "./lib/BytesToTypes.sol";

/// Channel acts as a special delegator — users delegate through Channel,
/// which tracks partner relationships and deducts commission on claim.
/// For ZEC staking, Channel is notified when version == SATOSHI_STAKE_CHANNEL_VERSION
/// and records the real delegator → txid mapping.
contract Channel is IChannel, System, IParamSubscriber {

  using BytesLib for *;

  uint256 public constant INIT_REQUIRED_PARTNER_MARGIN = 1e20;
  uint256 public constant UNREGISTER_FEE_RATE = 100; // 1% = 100 / DENOMINATOR

  struct Partner {
    uint8 status;                // 0: inactive, 1: active
    address operatorAddr;        // partner operator (msg.sender on register)
    address payable feeAddr;     // commission receiver
    uint32 nativeCommissionRate; // commission rate for native coin (DENOMINATOR = 10000)
    uint32 zecCommissionRate;    // commission rate for ZEC staking (DENOMINATOR = 10000)
    uint256 commission;          // accumulated commission
    uint256 margin;              // refundable deposit
  }

  // partner ID → Partner
  mapping(uint32 => Partner) public partners;
  uint32 public nextPartnerId;
  uint256 public requiredPartnerMargin;

  uint8 public constant STAKE_TYPE_NATIVE = 1;
  uint8 public constant STAKE_TYPE_ZEC = 2;

  struct StakeInfo {
    address delegator;     // real delegator
    uint32 partnerId;      // channel partner
    uint8 stakeType;       // STAKE_TYPE_NATIVE or STAKE_TYPE_ZEC
  }

  struct Delegator {
    bytes32[] stakeIds;    // all stake IDs (native + ZEC)
  }

  // stakeId/txid → stake info
  mapping(bytes32 => StakeInfo) public stakeInfoMap;
  // real delegator → aggregated stake records
  mapping(address => Delegator) delegatorMap;

  /*********************** errors **************************/
  error NoPartner(uint32 partnerId);

  /*********************** events **************************/
  event PartnerRegistered(uint32 indexed partnerId, address indexed feeAddr);
  event PartnerUnregistered(uint32 indexed partnerId);
  event DelegatedCoin(address indexed delegator, address indexed candidate, uint32 indexed partnerId, uint256 amount);
  event ZecStakeRecorded(bytes32 indexed txid, address indexed realDelegator, address indexed candidate, uint32 partnerId);

  /*********************** Init **************************/
  function init() external onlyNotInit {
    nextPartnerId = 1;
    requiredPartnerMargin = INIT_REQUIRED_PARTNER_MARGIN;
    alreadyInit = true;
  }

  /*********************** Partner Management **************************/

  /// Register as a channel partner
  function registerPartner(address payable feeAddr, uint32 nativeCommissionRate, uint32 zecCommissionRate) external payable onlyInit {
    require(feeAddr != address(0), "zero fee address");
    require(msg.value >= requiredPartnerMargin, "insufficient margin");
    require(nativeCommissionRate < SatoshiPlusHelper.DENOMINATOR, "native rate too high");
    require(zecCommissionRate < SatoshiPlusHelper.DENOMINATOR, "zec rate too high");

    uint32 id = nextPartnerId++;
    partners[id] = Partner({
      status: 1,
      operatorAddr: msg.sender,
      feeAddr: feeAddr,
      nativeCommissionRate: nativeCommissionRate,
      zecCommissionRate: zecCommissionRate,
      commission: 0,
      margin: msg.value
    });
    emit PartnerRegistered(id, feeAddr);
  }

  /// Unregister a channel partner
  function unregisterPartner(uint32 partnerId) external onlyInit {
    Partner storage p = partners[partnerId];
    require(p.status == 1, "partner not active");
    require(p.operatorAddr == msg.sender, "not partner operator");
    p.status = 0;

    uint256 margin = p.margin;
    p.margin = 0;
    if (margin > 0) {
      uint256 fee = margin * UNREGISTER_FEE_RATE / SatoshiPlusHelper.DENOMINATOR;
      payable(FOUNDATION_ADDR).transfer(fee);
      Address.sendValue(p.feeAddr, margin - fee);
    }
    emit PartnerUnregistered(partnerId);
  }

  /// Update partner fee address (only operator can call)
  function editPartnerFeeAddr(uint32 partnerId, address payable newFeeAddr) external {
    Partner storage p = partners[partnerId];
    require(p.operatorAddr == msg.sender, "not partner operator");
    require(newFeeAddr != address(0), "zero fee address");
    p.feeAddr = newFeeAddr;
  }

  /*********************** Native Coin Delegation (Channel as Delegator) **************************/

  /// Delegate native coin through Channel (Channel becomes the delegator in NativeAgent)
  /// @param candidate The validator candidate
  /// @param partnerId The channel partner ID
  function delegateCoin(address candidate, uint32 partnerId, uint256 lockRound) external payable {
    if (partners[partnerId].status == 0) {
      revert NoPartner(partnerId);
    }
    bytes32 stakeId = INativeAgent(NATIVE_AGENT_ADDR).delegateCoin{value: msg.value}(candidate, lockRound);
    stakeInfoMap[stakeId] = StakeInfo(msg.sender, partnerId, STAKE_TYPE_NATIVE);
    delegatorMap[msg.sender].stakeIds.push(stakeId);
    emit DelegatedCoin(msg.sender, candidate, partnerId, msg.value);
  }

  /// Undelegate a native coin stake through Channel
  /// Receives ETH from NativeAgent, deducts partner commission, forwards to real delegator
  function undelegateCoin(bytes32 stakeId) external {
    StakeInfo storage info = stakeInfoMap[stakeId];
    require(info.delegator == msg.sender, "not the delegator");

    (uint256 amount, uint256 reward) = INativeAgent(NATIVE_AGENT_ADDR).undelegateCoin(stakeId);

    // Partner commission on reward
    uint256 commission;
    uint32 partnerId = info.partnerId;
    if (partnerId != 0 && reward > 0) {
      Partner storage p = partners[partnerId];
      if (p.status == 1) {
        commission = reward * p.nativeCommissionRate / SatoshiPlusHelper.DENOMINATOR;
        p.commission += commission;
      }
    }

    // Clean up records
    _removeStake(msg.sender, stakeId);
    delete stakeInfoMap[stakeId];

    // Forward principal + reward - commission to real delegator
    uint256 payout = amount + reward - commission;
    if (payout > 0) {
      Address.sendValue(payable(msg.sender), payout);
    }
  }

  /// Transfer a native coin stake to a different candidate through Channel
  /// @param targetCandidate The target validator candidate
  /// @param stakeId The stake ID to transfer
  function transferCoin(address targetCandidate, bytes32 stakeId) external {
    require(stakeInfoMap[stakeId].delegator == msg.sender, "not the delegator");
    INativeAgent(NATIVE_AGENT_ADDR).transferCoin(targetCandidate, stakeId);
  }

  /// Transfer a ZEC stake to a different candidate through Channel
  function transferZec(address targetCandidate, bytes32 txid) external {
    require(stakeInfoMap[txid].delegator == msg.sender, "not the delegator");
    IZecAgent(ZEC_AGENT_ADDR).transferZec(txid, targetCandidate);
  }

  /*********************** ZEC Stake Tracking **************************/

  /// Called by ZecAgent when version == SATOSHI_STAKE_CHANNEL_VERSION
  /// The ZecAgent sets Channel as the delegator; Channel tracks the real user
  function onZecStake(
    address realDelegator,
    bytes32 txid,
    uint32 partnerId
  ) external override {
    require(msg.sender == ZEC_AGENT_ADDR, "only ZecAgent");
    stakeInfoMap[txid] = StakeInfo(realDelegator, partnerId, STAKE_TYPE_ZEC);
    delegatorMap[realDelegator].stakeIds.push(txid);

    emit ZecStakeRecorded(txid, realDelegator, address(0), partnerId);
  }

  /// Partner claims accumulated commission
  function claimCommission(uint32 partnerId) external {
    Partner storage p = partners[partnerId];
    require(p.operatorAddr == msg.sender, "not partner operator");
    uint256 amount = p.commission;
    require(amount > 0, "no commission");
    p.commission = 0;
    uint256 half = amount / 2;
    Address.sendValue(payable(FOUNDATION_ADDR), half);
    Address.sendValue(p.feeAddr, amount - half);
  }

  /*********************** Internal **************************/

  function _removeStake(address delegator, bytes32 stakeId) internal {
    bytes32[] storage ids = delegatorMap[delegator].stakeIds;
    for (uint256 i = 0; i < ids.length; i++) {
      if (ids[i] == stakeId) {
        ids[i] = ids[ids.length - 1];
        ids.pop();
        break;
      }
    }
  }

  /// Accept ETH from NativeAgent (undelegateCoin sends ETH here)
  receive() external payable {}

  /*********************** Governance **************************/
  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov {
    if (Memory.compareStrings(key, "requiredPartnerMargin")) {
      require(value.length == 32, "length mismatch");
      requiredPartnerMargin = BytesToTypes.bytesToUint256(32, value);
    } else {
      revert UnsupportedGovParam(key);
    }
  }

  /*********************** View **************************/
  function getStakeIds(address delegator) external view returns (bytes32[] memory) {
    return delegatorMap[delegator].stakeIds;
  }
}
