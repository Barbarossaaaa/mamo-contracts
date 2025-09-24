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

contract ERC20StrategyV2Test is BaseTest {
    address public owner;
    address public backend;
    ERC1967Proxy public strategyProxy;
    ERC20MoonwellMorphoStrategy public strategy;
    ERC20MoonwellMorphoStrategy public newImplementation;
    MamoStrategyRegistry public registry;

    function setUp() public override {
        vm.createSelectFork({urlOrAlias: "base", blockNumber: 35963655}); // Forked at 2025-09-24
        super.setUp();

        // create account with old implementation
        string memory factoryName = "USDC_STRATEGY_FACTORY";
        StrategyFactory factory = StrategyFactory(payable(addresses.getAddress(factoryName)));

        owner = makeAddr("owner");
        backend = addresses.getAddress("STRATEGY_MULTICALL");

        vm.startPrank(owner);
        strategyProxy = ERC1967Proxy(payable(factory.createStrategyForUser(owner)));
        strategy = ERC20MoonwellMorphoStrategy(payable(address(strategyProxy)));
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

    function testBackendCanClaimRewards() public {
        testUpgrade();

        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = addresses.getAddress("xWELL_PROXY");
        uint256[] memory rewardAmounts = new uint256[](1);
        rewardAmounts[0] = 1000000000000000000;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = bytes32(0);

        address merkleDistributor = addresses.getAddress("MERKLE_PROTOCOL_DISTRIBUTOR");

        vm.mockCall(
            merkleDistributor,
            abi.encodeWithSignature("claim(address[],address[],uint256[],bytes32[][])"),
            abi.encode(true)
        );

        vm.expectCall(merkleDistributor, abi.encodeWithSignature("claim(address[],address[],uint256[],bytes32[][])"));
        vm.expectEmit(true, true, true, true);
        emit ERC20MoonwellMorphoStrategy.RewardsClaimed(rewardTokens, rewardAmounts);

        vm.startPrank(backend);
        strategy.claimRewards(rewardTokens, rewardAmounts, proofs);
        vm.stopPrank();
    }

    function test_RevertIfNotBackend() public {
        testUpgrade();

        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = addresses.getAddress("xWELL_PROXY");
        uint256[] memory rewardAmounts = new uint256[](1);
        rewardAmounts[0] = 1000000000000000000;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = bytes32(0);

        vm.expectRevert("Not backend");

        vm.startPrank(makeAddr("not_backend"));
        strategy.claimRewards(rewardTokens, rewardAmounts, proofs);
        vm.stopPrank();
    }

    function test_RevertIfRewardTokensAndAmountsLengthMismatch() public {
        testUpgrade();

        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = addresses.getAddress("xWELL_PROXY");
        rewardTokens[1] = addresses.getAddress("xWELL_PROXY");
        uint256[] memory rewardAmounts = new uint256[](1);
        rewardAmounts[0] = 1000000000000000000;
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = bytes32(0);
        proofs[1] = new bytes32[](1);
        proofs[1][0] = bytes32(0);

        vm.expectRevert("Reward tokens and amounts length mismatch");

        vm.startPrank(backend);
        strategy.claimRewards(rewardTokens, rewardAmounts, proofs);
        vm.stopPrank();
    }

    function test_RevertIfRewardTokensAndProofsLengthMismatch() public {
        testUpgrade();

        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = addresses.getAddress("xWELL_PROXY");
        rewardTokens[1] = addresses.getAddress("xWELL_PROXY");
        uint256[] memory rewardAmounts = new uint256[](2);
        rewardAmounts[0] = 1000000000000000000;
        rewardAmounts[1] = 1000000000000000000;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = bytes32(0);

        vm.expectRevert("Reward tokens and proofs length mismatch");

        vm.startPrank(backend);
        strategy.claimRewards(rewardTokens, rewardAmounts, proofs);
        vm.stopPrank();
    }
}
