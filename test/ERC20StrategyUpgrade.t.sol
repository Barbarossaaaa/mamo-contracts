// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.t.sol";

import {WhitelistNewStrategyImplementation} from "../multisig/mamo-multisig/009_WhitelistNewStrategyImplementation.sol";

import {ERC20MoonwellMorphoStrategy} from "@contracts/ERC20MoonwellMorphoStrategy.sol";

import {StrategyFactory} from "@contracts/StrategyFactory.sol";
import {Addresses} from "@fps/addresses/Addresses.sol";

import {ERC1967Proxy} from "@contracts/ERC1967Proxy.sol";

import {MamoStrategyRegistry} from "@contracts/MamoStrategyRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ERC20StrategyUpgradeTest is BaseTest {
    address public owner;
    ERC1967Proxy public strategyProxy;
    ERC20MoonwellMorphoStrategy public newImplementation;
    MamoStrategyRegistry public registry;

    function setUp() public override {
        super.setUp();

        // create account with old implementation
        string memory factoryName = "USDC_STRATEGY_FACTORY";
        StrategyFactory factory = StrategyFactory(payable(addresses.getAddress(factoryName)));

        owner = makeAddr("owner");

        vm.startPrank(owner);
        strategyProxy = ERC1967Proxy(payable(factory.createStrategyForUser(owner)));
        vm.stopPrank();

        vm.warp(block.timestamp + 1 minutes);

        assertEq(strategyProxy.getImplementation(), addresses.getAddress("MOONWELL_MORPHO_STRATEGY_IMPL_DEPRECATED"));

        WhitelistNewStrategyImplementation whitelistNewStrategyImplementation = new WhitelistNewStrategyImplementation();
        whitelistNewStrategyImplementation.setAddresses(addresses);
        whitelistNewStrategyImplementation.deploy();
        whitelistNewStrategyImplementation.build();
        whitelistNewStrategyImplementation.simulate();
        whitelistNewStrategyImplementation.validate();

        newImplementation = ERC20MoonwellMorphoStrategy(payable(addresses.getAddress("MOONWELL_MORPHO_STRATEGY_IMPL")));

        registry = MamoStrategyRegistry(addresses.getAddress("MAMO_STRATEGY_REGISTRY"));
    }

    function testUpgrade() public {
        vm.startPrank(owner);
        registry.upgradeStrategy(address(strategyProxy), address(newImplementation));
        vm.stopPrank();

        assertEq(strategyProxy.getImplementation(), address(newImplementation), "Implementation should be upgraded");
    }
}
