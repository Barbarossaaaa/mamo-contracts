// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DropAutomation} from "@contracts/DropAutomation.sol";
import {RewardsDistributorSafeModule} from "@contracts/RewardsDistributorSafeModule.sol";
import {BurnAndEarn} from "@contracts/BurnAndEarn.sol";

import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";
import {DeployDropAutomation} from "@script/DeployDropAutomation.s.sol";

import {console} from "forge-std/console.sol";

/**
 * @title DropAutomationSetup
 * @notice F-MAMO multisig proposal to setup DropAutomation contract
 * @dev This proposal:
 *      1. Deploys the DropAutomation contract (owned by MAMO_MULTISIG)
 *      2. Transfers RewardsDistributorSafeModule admin from F-MAMO to DropAutomation
 *      3. Sets BurnAndEarn fee collector to DropAutomation
 * Note: BurnAndEarn ownership remains with F-MAMO for governance control
 */
contract DropAutomationSetup is MultisigProposal {
    DeployDropAutomation public immutable deployDropAutomation;

    constructor() {
        // Initialize deploy script
        deployDropAutomation = new DeployDropAutomation();
        vm.makePersistent(address(deployDropAutomation));
    }

    function _initializeAddresses() internal {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID

        addresses = new Addresses(addressesFolderPath, chainIds);
        vm.makePersistent(address(addresses));
    }

    function run() public override {
        _initializeAddresses();

        if (DO_DEPLOY) {
            deploy();
            addresses.updateJson();
            addresses.printJSONChanges();
        }

        if (DO_PRE_BUILD_MOCK) preBuildMock();
        if (DO_BUILD) build();
        if (DO_SIMULATE) simulate();
        if (DO_VALIDATE) validate();
        if (DO_PRINT) print();
        if (DO_UPDATE_ADDRESS_JSON) addresses.updateJson();
    }

    function name() public pure override returns (string memory) {
        return "005_DropAutomationSetup";
    }

    function description() public pure override returns (string memory) {
        return "Deploy DropAutomation and transfer admin/feeCollector roles";
    }

    function deploy() public override {
        // Deploy DropAutomation using the deploy script
        address dropAutomationAddress = deployDropAutomation.deploy(addresses);

        console.log("DropAutomation deployed at:", dropAutomationAddress);
    }

    function build() public override buildModifier(addresses.getAddress("F-MAMO")) {
        address dropAutomation = addresses.getAddress("DROP_AUTOMATION");
        address rewardsDistributorModule = addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC");
        address burnAndEarnAddress = addresses.getAddress("BURN_AND_EARN");

        // 1. Transfer RewardsDistributorSafeModule admin to DropAutomation
        RewardsDistributorSafeModule(rewardsDistributorModule).setAdmin(dropAutomation);

        // 2. Set BurnAndEarn fee collector to DropAutomation
        BurnAndEarn burnAndEarn = BurnAndEarn(burnAndEarnAddress);
        burnAndEarn.setFeeCollector(dropAutomation);

        // Note: BurnAndEarn ownership remains with F-MAMO for governance control
    }

    function simulate() public override {
        address multisig = addresses.getAddress("F-MAMO");
        _simulateActions(multisig);
    }

    function validate() public view override {
        // Get contract addresses
        address dropAutomation = addresses.getAddress("DROP_AUTOMATION");
        address rewardsDistributorModule = addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC");
        address burnAndEarnAddress = addresses.getAddress("BURN_AND_EARN");
        address mamoMultisig = addresses.getAddress("MAMO_MULTISIG");
        address gelatoSender = addresses.getAddress("GELATO_SENDER");
        address fMamoSafe = addresses.getAddress("F-MAMO");

        // Validate DropAutomation deployment
        require(dropAutomation.code.length > 0, "DropAutomation not deployed");

        DropAutomation dropAutomationContract = DropAutomation(dropAutomation);

        // Validate DropAutomation configuration
        assertEq(
            dropAutomationContract.owner(),
            mamoMultisig,
            "DropAutomation owner should be MAMO_MULTISIG"
        );
        assertEq(
            dropAutomationContract.dedicatedMsgSender(),
            gelatoSender,
            "DropAutomation dedicatedMsgSender should be GELATO_SENDER"
        );

        // Validate RewardsDistributorSafeModule admin transfer
        RewardsDistributorSafeModule module = RewardsDistributorSafeModule(rewardsDistributorModule);
        assertEq(
            module.admin(),
            dropAutomation,
            "RewardsDistributorSafeModule admin should be DropAutomation"
        );

        // Validate BurnAndEarn configuration
        BurnAndEarn burnAndEarn = BurnAndEarn(burnAndEarnAddress);
        assertEq(
            burnAndEarn.feeCollector(),
            dropAutomation,
            "BurnAndEarn fee collector should be DropAutomation"
        );
        assertEq(
            burnAndEarn.owner(),
            fMamoSafe,
            "BurnAndEarn owner should remain F-MAMO for governance"
        );

        // Validate admin transfers
        assertFalse(
            module.admin() == fMamoSafe,
            "RewardsDistributorSafeModule should no longer have F-MAMO as admin"
        );

        console.log("DropAutomation successfully deployed at:", dropAutomation);
        console.log("RewardsDistributorSafeModule admin transferred to DropAutomation");
        console.log("BurnAndEarn fee collector set to DropAutomation");
        console.log("BurnAndEarn ownership remains with F-MAMO for governance control");
        console.log("");
        console.log("NOTE: Existing factory contracts have immutable feeRecipient addresses.");
        console.log("Future factory deployments should use DropAutomation as the feeRecipient.");
    }
}