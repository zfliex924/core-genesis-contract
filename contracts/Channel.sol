// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./lib/Address.sol";
import "./interface/IChannel.sol";
import "./interface/INativeAgent.sol";
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

  struct Partner {
    uint256 status;           // 0: inactive, 1: active
    address payable feeAddr;  // commission receiver
    uint32 coreCommissionRate; // commission rate for native coin (thousandths)
    uint32 zecCommissionRate;  // commission rate for ZEC staking (thousandths)
    uint256 commission;        // accumulated commission
  }

  // partner ID → Partner
  mapping(uint32 => Partner) public partners;
  uint32 public nextPartnerId;

  // ZEC stake tracking: txid → real delegator (for stakes through Channel)
  mapping(bytes32 => address) public zecStakeDelegator;
  // real delegator → txid list (for enumeration)
  mapping(address => bytes32[]) public zecStakeTxids;
  // real delegator → partner ID
  mapping(address => uint32) public delegatorPartner;

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
    alreadyInit = true;
  }

  /*********************** Partner Management **************************/

  /// Register as a channel partner
  function registerPartner(address payable feeAddr, uint32 coreCommissionRate, uint32 zecCommissionRate) external onlyInit {
    require(feeAddr != address(0), "zero fee address");
    require(coreCommissionRate < 1000, "core rate too high");
    require(zecCommissionRate < 1000, "zec rate too high");

    uint32 id = nextPartnerId++;
    partners[id] = Partner({
      status: 1,
      feeAddr: feeAddr,
      coreCommissionRate: coreCommissionRate,
      zecCommissionRate: zecCommissionRate,
      commission: 0
    });
    emit PartnerRegistered(id, feeAddr);
  }

  /// Unregister a channel partner
  function unregisterPartner(uint32 partnerId) external onlyInit {
    Partner storage p = partners[partnerId];
    require(p.status == 1, "partner not active");
    require(p.feeAddr == msg.sender, "not partner owner");
    p.status = 0;
    emit PartnerUnregistered(partnerId);
  }

  /*********************** Native Coin Delegation (Channel as Delegator) **************************/

  /// Delegate native coin through Channel (Channel becomes the delegator in NativeAgent)
  /// @param candidate The validator candidate
  /// @param partnerId The channel partner ID
  function delegateCoin(address candidate, uint32 partnerId, uint256 lockRound) external payable {
    if (partners[partnerId].status == 0) {
      revert NoPartner(partnerId);
    }
    INativeAgent(NATIVE_AGENT_ADDR).delegateCoin{value: msg.value}(candidate, lockRound);
    delegatorPartner[msg.sender] = partnerId;
    emit DelegatedCoin(msg.sender, candidate, partnerId, msg.value);
  }

  /// Undelegate a native coin stake through Channel
  /// @param stakeId The stake ID to undelegate
  function undelegateCoin(bytes32 stakeId) external {
    INativeAgent(NATIVE_AGENT_ADDR).undelegateCoin(stakeId);
  }

  /// Transfer a native coin stake to a different candidate through Channel
  /// @param targetCandidate The target validator candidate
  /// @param stakeId The stake ID to transfer
  function transferCoin(address targetCandidate, bytes32 stakeId) external {
    INativeAgent(NATIVE_AGENT_ADDR).transferCoin(targetCandidate, stakeId);
  }

  /*********************** ZEC Stake Tracking **************************/

  /// Called by ZecAgent when version == SATOSHI_STAKE_CHANNEL_VERSION
  /// The ZecAgent sets Channel as the delegator; Channel tracks the real user
  function onZecStake(
    address realDelegator,
    bytes32 txid,
    address candidate
  ) external override {
    require(msg.sender == ZEC_AGENT_ADDR, "only ZecAgent");
    zecStakeDelegator[txid] = realDelegator;
    zecStakeTxids[realDelegator].push(txid);

    // Find partner ID from delegator's history
    uint32 partnerId = delegatorPartner[realDelegator];
    emit ZecStakeRecorded(txid, realDelegator, candidate, partnerId);
  }

  /*********************** Governance **************************/
  function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov {
    revert UnsupportedGovParam(key);
  }

  /*********************** View **************************/
  function getZecStakeTxids(address delegator) external view returns (bytes32[] memory) {
    return zecStakeTxids[delegator];
  }
}
