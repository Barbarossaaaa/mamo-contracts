// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DropAutomation} from "@contracts/DropAutomation.sol";
import {Script} from "@forge-std/Script.sol";
import {console} from "@forge-std/console.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

/**
 * @title DeployDropAutomation
 * @notice Script to deploy and manage DropAutomation contract
 */
contract DeployDropAutomation is Script {
    function run() public {
        // Load the addresses from the JSON file
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid; // Use the current chain ID
        Addresses addresses = new Addresses(addressesFolderPath, chainIds);

        vm.startBroadcast();
        address dropAutomation = deploy(addresses);
        vm.stopBroadcast();

        // Check if the drop automation address already exists
        string memory dropAutomationName = "DROP_AUTOMATION";
        if (addresses.isAddressSet(dropAutomationName)) {
            // Update the existing address
            addresses.changeAddress(dropAutomationName, dropAutomation, true);
        } else {
            // Add the drop automation address to the addresses contract
            addresses.addAddress(dropAutomationName, dropAutomation, true);
        }

        addresses.updateJson();
        addresses.printJSONChanges();
    }

    function deploy(Addresses addresses) public returns (address) {
        // Get the addresses for the initialization parameters
        address owner = addresses.getAddress("F-MAMO");
        address dedicatedMsgSender = addresses.getAddress("GELATO_SENDER");
        address mamoToken = addresses.getAddress("MAMO");
        address cbBtcToken = addresses.getAddress("cbBTC");
        address fMamoSafe = addresses.getAddress("F-MAMO");
        address safeRewardsDistributorModule = addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC");
        address aerodromeRouter = addresses.getAddress("AERODROME_ROUTER");
        address aerodromeQuoter = addresses.getAddress("AERODROME_QUOTER");
        address gauge = addresses.getAddress("AERODROME_USDC_AERO_GAUGE");
        address aeroToken = addresses.getAddress("AERO");
        address stakingToken = addresses.getAddress("AERO_STAKING_TOKEN");

        // Deploy the DropAutomation
        DropAutomation dropAutomation = new DropAutomation(
            owner,
            dedicatedMsgSender,
            mamoToken,
            cbBtcToken,
            fMamoSafe,
            safeRewardsDistributorModule,
            aerodromeRouter,
            aerodromeQuoter
        );

        console.log("DropAutomation deployed at:", address(dropAutomation));
        console.log("  Owner:", owner);
        console.log("  Dedicated Sender:", dedicatedMsgSender);
        console.log("  MAMO Token:", mamoToken);
        console.log("  cbBTC Token:", cbBtcToken);
        console.log("  F-MAMO Safe:", fMamoSafe);
        console.log("  Safe Rewards Module:", safeRewardsDistributorModule);
        console.log("  Aerodrome Router:", aerodromeRouter);
        console.log("  Aerodrome Quoter:", aerodromeQuoter);
        console.log("");
        console.log("  Gauge Configuration (to be set by owner post-deployment):");
        console.log("    Gauge:", gauge);
        console.log("    AERO Token:", aeroToken);
        console.log("    Staking Token:", stakingToken);

        return address(dropAutomation);
    }
}
