// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./interface/IRelayerHub.sol";

contract System {

  bool public alreadyInit;

  event paramChange(string key, bytes value);


  address public VALIDATOR_CONTRACT_ADDR;
  address public SLASH_CONTRACT_ADDR;
  address public SYSTEM_REWARD_ADDR;
  address public RELAYER_HUB_ADDR;
  address public CANDIDATE_HUB_ADDR;
  address public GOV_HUB_ADDR;
  address public BURN_ADDR;
  address public FOUNDATION_ADDR;
  address public STAKE_HUB_ADDR;
  address public NATIVE_AGENT_ADDR;
  address public HASH_AGENT_ADDR;
  address public CONFIGURATION_ADDR;
  address public CHANNEL_ADDR;
  address public ZEC_LIGHT_CLIENT_ADDR;
  address public ZEC_AGENT_ADDR;
  address public GRADE_MANAGER_ADDR;

  struct SystemContractAddr {
    address validator;
    address slash;
    address systemReward;
    address relayerHub;
    address candidateHub;
    address govHub;
    address burn;
    address foundation;
    address stakeHub;
    address nativeAgent;
    address hashAgent;
    address configurationContract;
    address channel;
    address zecLightClient;
    address zecAgent;
    address gradeManager;
  }

  function updateContractAddr(bytes memory _systemContractAddr) external {
    SystemContractAddr memory systemContractAddr = abi.decode(_systemContractAddr, (SystemContractAddr));
    VALIDATOR_CONTRACT_ADDR = systemContractAddr.validator;
    SLASH_CONTRACT_ADDR = systemContractAddr.slash;
    SYSTEM_REWARD_ADDR = systemContractAddr.systemReward;
    RELAYER_HUB_ADDR = systemContractAddr.relayerHub;
    CANDIDATE_HUB_ADDR = systemContractAddr.candidateHub;
    GOV_HUB_ADDR = systemContractAddr.govHub;
    BURN_ADDR = systemContractAddr.burn;
    FOUNDATION_ADDR = systemContractAddr.foundation;
    STAKE_HUB_ADDR = systemContractAddr.stakeHub;
    NATIVE_AGENT_ADDR = systemContractAddr.nativeAgent;
    HASH_AGENT_ADDR = systemContractAddr.hashAgent;
    CONFIGURATION_ADDR = systemContractAddr.configurationContract;
    CHANNEL_ADDR = systemContractAddr.channel;
    ZEC_LIGHT_CLIENT_ADDR = systemContractAddr.zecLightClient;
    ZEC_AGENT_ADDR = systemContractAddr.zecAgent;
    GRADE_MANAGER_ADDR = systemContractAddr.gradeManager;
  }
  
  function setAlreadyInit(bool value) external {
    alreadyInit = value;
  }
    
  
  modifier onlyCoinbase() {
  
    _;
  }

  modifier onlyZeroGasPrice() {
    
    _;
  }

  modifier onlyNotInit() {
    require(!alreadyInit, "the contract already init");
    _;
  }

  modifier onlyInit() {
    require(alreadyInit, "the contract not init yet");
    _;
  }

  modifier onlySlash() {
    require(msg.sender == SLASH_CONTRACT_ADDR, "the msg sender must be slash contract");
    _;
  }

  modifier onlyGov() {
    require(msg.sender == GOV_HUB_ADDR, "the msg sender must be governance contract");
    _;
  }

  modifier onlyCandidate() {
    require(msg.sender == CANDIDATE_HUB_ADDR, "the msg sender must be candidate contract");
    _;
  }

  modifier onlyValidator() {
    require(msg.sender == VALIDATOR_CONTRACT_ADDR, "the msg sender must be validatorSet contract");
    _;
  }

  modifier onlyRelayer() {
    require(IRelayerHub(RELAYER_HUB_ADDR).isRelayer(msg.sender), "the msg sender is not a relayer");
    _;
  }

  modifier onlyStakeHub() {
    require(msg.sender == STAKE_HUB_ADDR, "the msg sender must be stake hub contract");
    _;
  }

  modifier onlyCaller(address expected) {
    if (msg.sender != expected) {
      revert NotPermissionalCaller(expected, msg.sender);
    }
    _;
  }

  /// The length of param mismatch. Default is 32 bytes.
  /// @param name the name of param.
  error MismatchParamLength(string name);

  /// The passed param is out of bound. Should be in range [`lowerBound`,
  /// `upperBound`] but the value is `given`.
  /// @param name the name of param.
  /// @param given the value of param.
  /// @param lowerBound requested lower bound of the param.
  /// @param upperBound requested upper bound of the param
  error OutOfBounds(string name, uint256 given, uint256 lowerBound, uint256 upperBound);

  /// The passed param is unsupported.
  /// @param key The name of the parameter
  error UnsupportedGovParam(string key);

  /// The msg sender is not allowed.
  /// @param expected expected caller.
  /// @param actual actual caller.
  error NotPermissionalCaller(address expected, address actual);
}
