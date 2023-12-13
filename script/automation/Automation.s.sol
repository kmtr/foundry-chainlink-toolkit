// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "forge-std/Script.sol";
import "forge-std/Vm.sol";

import "../helpers/BaseScript.s.sol";
import "../helpers/TypeAndVersion.s.sol";
import "src/interfaces/LinkTokenInterface.sol";
import "src/interfaces/automation/CronUpkeepFactoryInterface.sol";
import { KeeperRegistrar1_2Interface } from "src/interfaces/automation/KeeperRegistrar1_2Interface.sol";
import { KeeperRegistrar2_0Interface } from "src/interfaces/automation/KeeperRegistrar2_0Interface.sol";
import { AutomationRegistrar2_1Interface, TriggerRegistrationStorage } from "src/interfaces/automation/AutomationRegistrar2_1Interface.sol";
import "src/interfaces/automation/KeeperRegistryInterface.sol";
import { KeeperRegistry1_3Interface, State as StateV1_0, Config as ConfigV1_0 } from "src/interfaces/automation/KeeperRegistry1_3Interface.sol";
import { KeeperRegistry2_0Interface, State as StateV2_0, OnchainConfig as ConfigV2_0, UpkeepInfo as UpkeepInfoV2_0 } from "src/interfaces/automation/KeeperRegistry2_0Interface.sol";
import { KeeperRegistry2_1Interface, State as StateV2_1, OnchainConfig as ConfigV2_1, UpkeepInfo as UpkeepInfoV2_1 } from "src/interfaces/automation/KeeperRegistry2_1Interface.sol";
import "src/interfaces/automation/KeeperRegistrarInterface.sol";
import "src/libraries/AutomationUtils.sol";
import "src/libraries/TypesAndVersions.sol";
import "src/libraries/Utils.sol";

library RegistryGeneration {
  string public constant v1_0 = "v1_0";
  string public constant v2_0 = "v2_0";
  string public constant v2_1 = "v2_1";

  // Pick registry generation based on typeAndVersion
  function pickRegistryGeneration(string memory typeAndVersion) public pure returns (string memory) {
    if (Utils.compareStrings(typeAndVersion, TypesAndVersions.KeeperRegistry1_0) ||
    Utils.compareStrings(typeAndVersion, TypesAndVersions.KeeperRegistry1_1) ||
    Utils.compareStrings(typeAndVersion, TypesAndVersions.KeeperRegistry1_2) ||
      Utils.compareStrings(typeAndVersion, TypesAndVersions.KeeperRegistry1_3)) {
      return v1_0;
    } else if (Utils.compareStrings(typeAndVersion, TypesAndVersions.KeeperRegistry2_0) ||
    Utils.compareStrings(typeAndVersion, TypesAndVersions.KeeperRegistry2_0_1) ||
      Utils.compareStrings(typeAndVersion, TypesAndVersions.KeeperRegistry2_0_2)) {
      return v2_0;
    } else if (Utils.compareStrings(typeAndVersion, TypesAndVersions.KeeperRegistry2_1)) {
      return v2_1;
    } else {
      revert("Unsupported KeeperRegistry typeAndVersion");
    }
  }

  // check if registry generation is v1_0
  function isV1_0(string memory typeAndVersion) public pure returns (bool) {
    return Utils.compareStrings(pickRegistryGeneration(typeAndVersion), v1_0);
  }

  // check if registry generation is v2_0
  function isV2_0(string memory typeAndVersion) public pure returns (bool) {
    return Utils.compareStrings(pickRegistryGeneration(typeAndVersion), v2_0);
  }

  // check if registry generation is v2_1
  function isV2_1(string memory typeAndVersion) public pure returns (bool) {
    return Utils.compareStrings(pickRegistryGeneration(typeAndVersion), v2_1);
  }
}

struct RegistryState {
  string registryGeneration;
  RegistryStateV1_0 stateV1_0;
  RegistryStateV2_0 stateV2_0;
  RegistryStateV2_1 stateV2_1;
}

struct RegistryStateV1_0 {
  StateV1_0 state;
  ConfigV1_0 config;
  address[] keepers;
}

struct RegistryStateV2_0 {
  StateV2_0 state;
  ConfigV2_0 config;
  address[] signers;
  address[] transmitters;
  uint8 f;
}

struct RegistryStateV2_1 {
  StateV2_1 state;
  ConfigV2_1 config;
  address[] signers;
  address[] transmitters;
  uint8 f;
}

contract AutomationScript is BaseScript, TypeAndVersionScript {
  event NewCronUpkeepCreated(address upkeep, address owner);

  uint8 private constant REGISTRATION_SOURCE = 0;
  bytes private constant EMPTY_BYTES = new bytes(0);

  address public keeperRegistryAddress;
  address public keeperRegistrarAddress;
  string public keeperRegistryTypeAndVersion;
  string public keeperRegistrarTypeAndVersion;

  constructor (address _keeperRegistryAddress) {
    keeperRegistryAddress = _keeperRegistryAddress;
    keeperRegistryTypeAndVersion = TypeAndVersionInterface(keeperRegistryAddress).typeAndVersion();

    if (RegistryGeneration.isV1_0(keeperRegistryTypeAndVersion)) {
      (,ConfigV1_0 memory config,) = KeeperRegistry1_3Interface(keeperRegistryAddress).getState();
      keeperRegistrarAddress = config.registrar;
    }
    else if (RegistryGeneration.isV2_0(keeperRegistryTypeAndVersion)) {
      (,ConfigV2_0 memory config,,,) = KeeperRegistry2_0Interface(keeperRegistryAddress).getState();
      keeperRegistrarAddress = config.registrar;
    }
    else if (RegistryGeneration.isV2_1(keeperRegistryTypeAndVersion)) {
      (,ConfigV2_1 memory config,,,) = KeeperRegistry2_1Interface(keeperRegistryAddress).getState();
      keeperRegistrarAddress = config.registrars[0];
    }
    else {
      revert("Unsupported KeeperRegistry typeAndVersion");
    }
    keeperRegistrarTypeAndVersion = TypeAndVersionInterface(keeperRegistrarAddress).typeAndVersion();
  }

  /**
   * @notice Keeper Registrar functions
   */

  /**
   * @notice registerUpkeep function to register upkeep
   * @param linkTokenAddress address of the LINK token
   * @param amountInJuels quantity of LINK upkeep is funded with (specified in Juels)
   * @param upkeepName string of the upkeep to be registered
   * @param upkeepAddress address to perform upkeep on
   * @param gasLimit amount of gas to provide the target contract when performing upkeep
   * @param checkData data passed to the contract when checking for upkeep
   */
  function registerUpkeep(
    address linkTokenAddress,
    uint96 amountInJuels,
    string calldata upkeepName,
    string calldata email,
    address upkeepAddress,
    uint32 gasLimit,
    bytes calldata checkData
  ) nestedScriptContext public returns (bytes32 requestHash) {

    LinkTokenInterface linkToken = LinkTokenInterface(linkTokenAddress);

    bytes memory encryptedEmail = bytes(email);

    // Reference: https://docs.chain.link/chainlink-automation/guides/register-upkeep-in-contract
    bytes memory offchainConfig = EMPTY_BYTES; // Leave as 0x, placeholder parameter for future use

    bytes memory additionalData;
    if (Utils.compareStrings(keeperRegistrarTypeAndVersion, TypesAndVersions.KeeperRegistrar1_2)) {
      bytes4 registerSelector = KeeperRegistrar1_2Interface.register.selector;
      additionalData = abi.encodeWithSelector(
        registerSelector,
        upkeepName,
        encryptedEmail,
        upkeepAddress,
        gasLimit,
        msg.sender,
        checkData,
        amountInJuels,
        REGISTRATION_SOURCE,
        msg.sender
      );
    } else if (Utils.compareStrings(keeperRegistrarTypeAndVersion, TypesAndVersions.KeeperRegistrar2_0)) {
      bytes4 registerSelector = KeeperRegistrar2_0Interface.register.selector;
      additionalData = abi.encodeWithSelector(
        registerSelector,
        upkeepName,
        encryptedEmail,
        upkeepAddress,
        gasLimit,
        msg.sender,
        checkData,
        offchainConfig,
        amountInJuels,
        msg.sender
      );
    } else if (Utils.compareStrings(keeperRegistrarTypeAndVersion, TypesAndVersions.KeeperRegistrar2_1)) {
      bytes4 registerSelector = AutomationRegistrar2_1Interface.register.selector;
      AutomationUtils.Trigger triggerType = AutomationUtils.Trigger.CONDITION;
      bytes memory triggerConfig = EMPTY_BYTES;
      additionalData = abi.encodeWithSelector(
        registerSelector,
        upkeepName,
        encryptedEmail,
        upkeepAddress,
        gasLimit,
        msg.sender,
        uint8(triggerType),
        checkData,
        triggerConfig,
        offchainConfig,
        amountInJuels,
        msg.sender
      );
    } else {
      revert("Unsupported KeeperRegistrar typeAndVersion");
    }

    vm.recordLogs();
    linkToken.transferAndCall(keeperRegistrarAddress, amountInJuels, additionalData);
    Vm.Log[] memory logEntries = vm.getRecordedLogs();

    return logEntries[2].topics[1];
  }

  /**
   * @notice registerUpkeep_logTrigger function to register upkeep with Log Trigger
   * @param linkTokenAddress address of the LINK token
   * @param amountInJuels quantity of LINK upkeep is funded with (specified in Juels)
   * @param upkeepName string of the upkeep to be registered
   * @param upkeepAddress address to perform upkeep on
   * @param gasLimit amount of gas to provide the target contract when performing upkeep
   * @param checkData data passed to the contract when checking for upkeep
   * @param triggerConfig the config for the trigger
   */
  function registerUpkeep_logTrigger(
    address linkTokenAddress,
    uint96 amountInJuels,
    string calldata upkeepName,
    string calldata email,
    address upkeepAddress,
    uint32 gasLimit,
    bytes calldata checkData,
    bytes memory triggerConfig
  ) nestedScriptContext public returns (bytes32 requestHash) {
    require(Utils.compareStrings(keeperRegistrarTypeAndVersion, TypesAndVersions.KeeperRegistrar2_1), "This function is only supported for KeeperRegistrar2_1");

    LinkTokenInterface linkToken = LinkTokenInterface(linkTokenAddress);
    AutomationRegistrar2_1Interface keeperRegistrar = AutomationRegistrar2_1Interface(keeperRegistrarAddress);

    AutomationUtils.Trigger triggerType = AutomationUtils.Trigger.LOG;

    // Encrypt email
    bytes memory encryptedEmail = bytes(email);
    // Reference: https://docs.chain.link/chainlink-automation/guides/register-upkeep-in-contract
    bytes memory offchainConfig = EMPTY_BYTES; // Leave as 0x, placeholder parameter for future use.

    bytes4 registerSelector = keeperRegistrar.register.selector;

    bytes memory additionalData = abi.encodeWithSelector(
      registerSelector,
      upkeepName,
      encryptedEmail,
      upkeepAddress,
      gasLimit,
      msg.sender,
      uint8(triggerType),
      checkData,
      triggerConfig,
      offchainConfig,
      amountInJuels,
      msg.sender
    );

    vm.recordLogs();
    linkToken.transferAndCall(keeperRegistrarAddress, amountInJuels, additionalData);
    Vm.Log[] memory logEntries = vm.getRecordedLogs();

    return logEntries[2].topics[0];
  }

  /**
   * @notice registerUpkeep_timeBased function to register upkeep with Time Based Trigger
   * @param linkTokenAddress address of the LINK token
   * @param amountInJuels quantity of LINK upkeep is funded with (specified in Juels)
   * @param upkeepName string of the upkeep to be registered
   * @param upkeepAddress address to perform upkeep on
   * @param gasLimit amount of gas to provide the target contract when performing upkeep
   * @param checkData data passed to the contract when checking for upkeep
   * @param cronUpkeepFactoryAddress address of the upkeep cron factory contract
   * @param upkeepFunctionSelector function signature on the target contract to call
   * @param cronString cron string to convert and encode
   */
  function registerUpkeep_timeBased(
    address linkTokenAddress,
    uint96 amountInJuels,
    string calldata upkeepName,
    string calldata email,
    address upkeepAddress,
    uint32 gasLimit,
    bytes calldata checkData,
    address cronUpkeepFactoryAddress,
    bytes4 upkeepFunctionSelector,
    string calldata cronString
  ) nestedScriptContext public returns (bytes32 requestHash) {
    require(Utils.compareStrings(keeperRegistrarTypeAndVersion, TypesAndVersions.KeeperRegistrar2_1), "This function is only supported for KeeperRegistrar2_1");

    LinkTokenInterface linkToken = LinkTokenInterface(linkTokenAddress);
    AutomationRegistrar2_1Interface keeperRegistrar = AutomationRegistrar2_1Interface(keeperRegistrarAddress);

    AutomationUtils.Trigger triggerType = AutomationUtils.Trigger.CONDITION;

    // Encrypt email
    bytes memory encryptedEmail = bytes(email);
    // Reference: https://docs.chain.link/chainlink-automation/guides/register-upkeep-in-contract
    bytes memory offchainConfig = EMPTY_BYTES; // Leave as 0x, placeholder parameter for future use.
    bytes memory triggerConfig = EMPTY_BYTES;

    bytes4 registerSelector = keeperRegistrar.register.selector;

    CronUpkeepFactoryInterface cronUpkeepFactory = CronUpkeepFactoryInterface(cronUpkeepFactoryAddress);

    bytes memory encodedJob = cronUpkeepFactory.encodeCronJob(upkeepAddress, abi.encodeWithSelector(upkeepFunctionSelector), cronString);

    // @dev: This is a workaround to get the address of the deployed CronUpkeep contract.
    Vm.Log[] memory logEntries;

    vm.recordLogs();
    cronUpkeepFactory.newCronUpkeepWithJob(encodedJob);
    logEntries = vm.getRecordedLogs();
    address cronUpkeepAddress = logEntries[0].emitter;

    bytes memory additionalData = abi.encodeWithSelector(
      registerSelector,
      upkeepName,
      encryptedEmail,
      cronUpkeepAddress,
      gasLimit,
      msg.sender,
      uint8(triggerType),
      checkData,
      triggerConfig,
      offchainConfig,
      amountInJuels,
      msg.sender
    );

    vm.recordLogs();
    linkToken.transferAndCall(keeperRegistrarAddress, amountInJuels, additionalData);
    logEntries = vm.getRecordedLogs();

    return logEntries[2].topics[0];
  }

  function getPendingRequest(
    bytes32 requestHash
  ) external view returns(address admin, uint96 balance) {
    KeeperRegistrarInterface keeperRegistrar = KeeperRegistrarInterface(keeperRegistrarAddress);
    return keeperRegistrar.getPendingRequest(requestHash);
  }

  function cancelRequest(
    bytes32 requestHash
  ) nestedScriptContext external {
    KeeperRegistrarInterface keeperRegistrar = KeeperRegistrarInterface(keeperRegistrarAddress);
    keeperRegistrar.cancel(requestHash);
  }

  function getRegistrationConfig() external view returns (
    AutomationUtils.AutoApproveType autoApproveType,
    uint32 autoApproveMaxAllowed,
    uint32 approvedCount,
    address keeperRegistry,
    uint256 minLINKJuels
  ) {
    if (Utils.compareStrings(keeperRegistrarTypeAndVersion, TypesAndVersions.KeeperRegistrar2_1)) {
      revert("'triggerType' must be provided for this typeAndVersion of the KeeperRegistrar");
    }

    if (Utils.compareStrings(keeperRegistrarTypeAndVersion, TypesAndVersions.KeeperRegistrar1_2)) {
      KeeperRegistrar1_2Interface keeperRegistrar = KeeperRegistrar1_2Interface(keeperRegistrarAddress);
      return keeperRegistrar.getRegistrationConfig();
    } else if (Utils.compareStrings(keeperRegistrarTypeAndVersion, TypesAndVersions.KeeperRegistrar2_0)) {
      KeeperRegistrar2_0Interface keeperRegistrar = KeeperRegistrar2_0Interface(keeperRegistrarAddress);
      return keeperRegistrar.getRegistrationConfig();
    } else {
      revert("Unsupported KeeperRegistrar typeAndVersion");
    }
  }

  function getRegistrationConfig(
    AutomationUtils.Trigger triggerType
  ) external view returns (
    AutomationUtils.AutoApproveType autoApproveType,
    uint32 autoApproveMaxAllowed,
    uint32 approvedCount,
    address keeperRegistry,
    uint256 minLINKJuels
  ) {
    if (Utils.compareStrings(keeperRegistrarTypeAndVersion, TypesAndVersions.KeeperRegistrar2_1)) {
      AutomationRegistrar2_1Interface keeperRegistrar = AutomationRegistrar2_1Interface(keeperRegistrarAddress);
      TriggerRegistrationStorage memory triggerRegistrationStorage = keeperRegistrar.getTriggerRegistrationDetails(uint8(triggerType));
      (keeperRegistry, minLINKJuels) = keeperRegistrar.getConfig();
      return (
        triggerRegistrationStorage.autoApproveType,
        triggerRegistrationStorage.autoApproveMaxAllowed,
        triggerRegistrationStorage.approvedCount,
        keeperRegistry,
        minLINKJuels
      );
    } else {
      return this.getRegistrationConfig();
    }
  }

  /**
   * @notice Keeper Registry functions
   */

  function addFunds(
    uint256 upkeepId,
    uint96 amountInJuels
  ) nestedScriptContext external {
    KeeperRegistryInterface keeperRegistry = KeeperRegistryInterface(keeperRegistryAddress);
    keeperRegistry.addFunds(upkeepId, amountInJuels);
  }

  function pauseUpkeep(
    uint256 upkeepId
  ) nestedScriptContext external {
    KeeperRegistryInterface keeperRegistry = KeeperRegistryInterface(keeperRegistryAddress);
    keeperRegistry.pauseUpkeep(upkeepId);
  }

  function unpauseUpkeep(
    uint256 upkeepId
  ) nestedScriptContext external {
    KeeperRegistryInterface keeperRegistry = KeeperRegistryInterface(keeperRegistryAddress);
    keeperRegistry.unpauseUpkeep(upkeepId);
  }

  function cancelUpkeep(
    uint256 upkeepId
  ) nestedScriptContext external {
    KeeperRegistryInterface keeperRegistry = KeeperRegistryInterface(keeperRegistryAddress);
    keeperRegistry.cancelUpkeep(upkeepId);
  }

  function setUpkeepGasLimit(
    uint256 upkeepId,
    uint32 gasLimit
  ) nestedScriptContext external {
    KeeperRegistryInterface keeperRegistry = KeeperRegistryInterface(keeperRegistryAddress);
    keeperRegistry.setUpkeepGasLimit(upkeepId, gasLimit);
  }

  function getMinBalanceForUpkeep(
    uint256 upkeepId
  ) external view returns (uint96 minBalance) {
    KeeperRegistryInterface keeperRegistry = KeeperRegistryInterface(keeperRegistryAddress);
    return keeperRegistry.getMinBalanceForUpkeep(upkeepId);
  }

  function getState() external view returns (RegistryState memory registryState) {
    if (RegistryGeneration.isV1_0(keeperRegistryTypeAndVersion)) {
      (StateV1_0 memory state, ConfigV1_0 memory config, address[] memory keepers) = KeeperRegistry1_3Interface(keeperRegistryAddress).getState();
      registryState.registryGeneration = RegistryGeneration.v1_0;
      registryState.stateV1_0 = RegistryStateV1_0(state, config, keepers);
      return registryState;
    } else if (RegistryGeneration.isV2_0(keeperRegistryTypeAndVersion)) {
      (StateV2_0 memory state, ConfigV2_0 memory config, address[] memory signers, address[] memory transmitters, uint8 f) = KeeperRegistry2_0Interface(keeperRegistryAddress).getState();
      registryState.registryGeneration = RegistryGeneration.v2_0;
      registryState.stateV2_0 = RegistryStateV2_0(state, config, signers, transmitters, f);
      return registryState;
    }  else if (RegistryGeneration.isV2_1(keeperRegistryTypeAndVersion)) {
      (StateV2_1 memory state, ConfigV2_1 memory config, address[] memory signers, address[] memory transmitters, uint8 f) = KeeperRegistry2_1Interface(keeperRegistryAddress).getState();
      registryState.registryGeneration = RegistryGeneration.v2_1;
      registryState.stateV2_1 = RegistryStateV2_1(state, config, signers, transmitters, f);
      return registryState;
    } else {
      revert("Unsupported KeeperRegistry typeAndVersion");
    }
  }

  function getUpkeepTranscoderVersion() external view returns(AutomationUtils.UpkeepFormat) {
    KeeperRegistry1_3Interface keeperRegistry = KeeperRegistry1_3Interface(keeperRegistryAddress);
    return keeperRegistry.upkeepTranscoderVersion();
  }

  function getActiveUpkeepIDs(
    uint256 startIndex,
    uint256 maxCount
  ) external view returns (uint256[] memory) {
    KeeperRegistryInterface keeperRegistry = KeeperRegistryInterface(keeperRegistryAddress);
    return keeperRegistry.getActiveUpkeepIDs(startIndex, maxCount);
  }

  function getUpkeep(
    uint256 upkeepId
  ) external view returns (
    address target,
    uint32 executeGas,
    bytes memory checkData,
    uint96 balance,
    address admin,
    uint64 maxValidBlocknumber,
    uint96 amountSpent,
    bool paused
  ) {
    address lastKeeper;
    if (RegistryGeneration.isV1_0(keeperRegistryTypeAndVersion)) {
      (
        target,
        executeGas,
        checkData,
        balance,
        lastKeeper,
        admin,
        maxValidBlocknumber,
        amountSpent,
        paused
      ) = KeeperRegistry1_3Interface(keeperRegistryAddress).getUpkeep(upkeepId);
      return (
        target,
        executeGas,
        checkData,
        balance,
        admin,
        maxValidBlocknumber,
        amountSpent,
        paused
      );
    } else if (RegistryGeneration.isV2_0(keeperRegistryTypeAndVersion)) {
      UpkeepInfoV2_0 memory upkeepInfo = KeeperRegistry2_0Interface(keeperRegistryAddress).getUpkeep(upkeepId);
      return (
        upkeepInfo.target,
        upkeepInfo.executeGas,
        upkeepInfo.checkData,
        upkeepInfo.balance,
        upkeepInfo.admin,
        upkeepInfo.maxValidBlocknumber,
        upkeepInfo.amountSpent,
        upkeepInfo.paused
      );
    }  else if (RegistryGeneration.isV2_1(keeperRegistryTypeAndVersion)) {
      UpkeepInfoV2_1 memory upkeepInfo = KeeperRegistry2_1Interface(keeperRegistryAddress).getUpkeep(upkeepId);
      return (
        upkeepInfo.target,
        upkeepInfo.performGas,
        upkeepInfo.checkData,
        upkeepInfo.balance,
        upkeepInfo.admin,
        upkeepInfo.maxValidBlocknumber,
        upkeepInfo.amountSpent,
        upkeepInfo.paused
      );
    } else {
      revert("Unsupported KeeperRegistry typeAndVersion");
    }
  }

  function withdrawFunds(
    uint256 upkeepId,
    address receivingAddress
  ) nestedScriptContext external {
    KeeperRegistryInterface keeperRegistry = KeeperRegistryInterface(keeperRegistryAddress);
    keeperRegistry.withdrawFunds(upkeepId, receivingAddress);
  }

  function transferUpkeepAdmin(
    uint256 upkeepId,
    address proposedAdmin
  ) nestedScriptContext external {
    KeeperRegistryInterface keeperRegistry = KeeperRegistryInterface(keeperRegistryAddress);
    keeperRegistry.transferUpkeepAdmin(upkeepId, proposedAdmin);
  }

  function acceptUpkeepAdmin(
    uint256 upkeepId
  ) nestedScriptContext external {
    KeeperRegistryInterface keeperRegistry = KeeperRegistryInterface(keeperRegistryAddress);
    keeperRegistry.acceptUpkeepAdmin(upkeepId);
  }
}
