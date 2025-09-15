// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";
import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";
import {MultisigProposal} from "@fps/src/proposals/MultisigProposal.sol";

/**
 * @title WhitelistNewStrategyImplementation
 * @notice Multisig proposal to whitelist a new strategy implementation for token type 1
 * @dev This script will deploy a new ERC20MoonwellMorphoStrategy implementation and whitelist it
 *      for strategy type ID 1, which is used for both USDC and cbBTC strategies.
 */
contract WhitelistNewStrategyImplementation is MultisigProposal {
    uint256 public constant STRATEGY_TYPE_ID = 1; // Token type 1 for USDC/cbBTC strategies

    constructor() {
        // Initialize addresses
        string memory addressesFolderPath = "./addresses";
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = block.chainid;
        addresses = new Addresses(addressesFolderPath, chainIds);
    }

    function name() public pure override returns (string memory) {
        return "009_WhitelistNewStrategyImplementation";
    }

    function description() public pure override returns (string memory) {
        return "Deploy and whitelist new ERC20MoonwellMorphoStrategy implementation for token type 1";
    }

    function deploy() public override {
        // Deploy new strategy implementation
        address newImplementation = address(new ERC20MoonwellMorphoStrategy());

        // Store the new implementation address
        addresses.addAddress("NEW_STRATEGY_IMPLEMENTATION", newImplementation, true);
    }

    function build() public override buildModifier(addresses.getAddress("MAMO_MULTISIG")) {
        // Get the strategy registry
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));

        // Get the new implementation address
        address newImplementation = addresses.getAddress("NEW_STRATEGY_IMPLEMENTATION");

        // Whitelist the new implementation for strategy type ID 1
        // This will update latestImplementationById[1] to point to the new implementation
        registry.whitelistImplementation(newImplementation, STRATEGY_TYPE_ID);
    }

    function simulate() public override {
        address multisig = addresses.getAddress("MAMO_MULTISIG");

        _simulateActions(multisig);
    }

    function validate() public override {
        // Get addresses
        MamoStrategyRegistry registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
        address newImplementation = addresses.getAddress("NEW_STRATEGY_IMPLEMENTATION");

        // Validate that the new implementation is whitelisted
        assertTrue(registry.whitelistedImplementations(newImplementation), "New implementation should be whitelisted");

        // Validate that the new implementation is registered for strategy type 1
        assertEq(
            registry.implementationToId(newImplementation),
            STRATEGY_TYPE_ID,
            "Implementation should have correct strategy type ID"
        );

        // Validate that strategy type 1 now points to the new implementation
        assertEq(
            registry.latestImplementationById(STRATEGY_TYPE_ID),
            newImplementation,
            "Latest implementation for type 1 should be updated"
        );
    }
}
