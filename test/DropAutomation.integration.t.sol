// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.t.sol";

import {DropAutomation} from "@contracts/DropAutomation.sol";
import {RewardsDistributorSafeModule} from "@contracts/RewardsDistributorSafeModule.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ISafe} from "@contracts/interfaces/ISafe.sol";

contract DropAutomationIntegrationTest is BaseTest {
    DropAutomation public dropAutomation;
    RewardsDistributorSafeModule public rewardsModule;

    IERC20 public mamoToken;
    IERC20 public cbBtcToken;
    IERC20 public wethToken;

    ISafe public fMamoSafe;

    uint256 internal constant MAMO_TOP_UP = 5_000e18;
    uint256 internal constant CBBTC_TOP_UP = 1e7; // 0.1 cbBTC (8 decimals)
    uint256 internal constant WETH_TOP_UP = 1e15; // 0.001 WETH
    uint256 internal constant EXTRA_TOKEN_TOP_UP = 1e18;

    // Additional swap tokens collected during earn (all volatile CL-200 pools vs MAMO)
    address internal constant ZORA_TOKEN = 0x1111111111166b7FE7bd91427724B487980aFc69;
    address internal constant EDGE_TOKEN = 0xED6E000dEF95780fb89734c07EE2ce9F6dcAf110;
    address internal constant VIRTUALS_TOKEN = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;

    function setUp() public override {
        super.setUp();

        dropAutomation = new DropAutomation(address(this), address(this));

        mamoToken = IERC20(addresses.getAddress("MAMO"));
        cbBtcToken = IERC20(addresses.getAddress("cbBTC"));
        wethToken = IERC20(addresses.getAddress("WETH"));

        rewardsModule = RewardsDistributorSafeModule(addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC"));
        fMamoSafe = ISafe(payable(addresses.getAddress("F-MAMO")));

        _ensureModuleReady();
        _configureSwapTokens();
    }

    function test_createDrop_endToEnd() public {
        // Top up DropAutomation with tokens that would normally be collected by earn
        deal(address(mamoToken), address(dropAutomation), MAMO_TOP_UP);
        deal(address(cbBtcToken), address(dropAutomation), CBBTC_TOP_UP);
        deal(address(wethToken), address(dropAutomation), WETH_TOP_UP);
        deal(ZORA_TOKEN, address(dropAutomation), EXTRA_TOKEN_TOP_UP);
        deal(EDGE_TOKEN, address(dropAutomation), EXTRA_TOKEN_TOP_UP);
        deal(VIRTUALS_TOKEN, address(dropAutomation), EXTRA_TOKEN_TOP_UP);

        uint256 safeMamoBefore = mamoToken.balanceOf(address(fMamoSafe));
        uint256 safeCbBtcBefore = cbBtcToken.balanceOf(address(fMamoSafe));

        vm.prank(address(this));
        dropAutomation.createDrop();

        uint256 safeMamoAfter = mamoToken.balanceOf(address(fMamoSafe));
        uint256 safeCbBtcAfter = cbBtcToken.balanceOf(address(fMamoSafe));

        assertGe(safeMamoAfter - safeMamoBefore, MAMO_TOP_UP, "Safe should receive MAMO rewards");
        assertGt(safeCbBtcAfter - safeCbBtcBefore, 0, "Safe should receive cbBTC rewards");

        (uint256 pendingToken1, uint256 pendingToken2,, bool isNotified) = rewardsModule.pendingRewards();
        assertGe(pendingToken1, MAMO_TOP_UP, "Module should stage MAMO amount");
        assertGe(pendingToken2, CBBTC_TOP_UP, "Module should stage at least the seeded cbBTC");
        assertFalse(isNotified, "Rewards should be pending execution");

        // Drop contract should not retain tokens post distribution
        assertEq(mamoToken.balanceOf(address(dropAutomation)), 0, "Drop should not retain MAMO");
        assertEq(cbBtcToken.balanceOf(address(dropAutomation)), 0, "Drop should not retain cbBTC");
        assertEq(wethToken.balanceOf(address(dropAutomation)), 0, "Drop should swap WETH balance");
        assertEq(IERC20(ZORA_TOKEN).balanceOf(address(dropAutomation)), 0, "Drop should swap ZORA balance");
        assertEq(IERC20(EDGE_TOKEN).balanceOf(address(dropAutomation)), 0, "Drop should swap EDGE balance");
        assertEq(IERC20(VIRTUALS_TOKEN).balanceOf(address(dropAutomation)), 0, "Drop should swap Virtuals balance");
    }

    function _ensureModuleReady() internal {
        // Make DropAutomation the admin so it can call addRewards
        vm.prank(address(fMamoSafe));
        rewardsModule.setAdmin(address(dropAutomation));

        // Ensure previous round (if any) is executed so addRewards doesn't revert
        (uint256 amountToken1, uint256 amountToken2, uint256 notifyAfter, bool isNotified) =
            rewardsModule.pendingRewards();

        if (notifyAfter != 0 && !isNotified) {
            // Execute the pending round so the module transitions to EXECUTED, which is mandatory
            // before addRewards can be called again.
            if (block.timestamp <= notifyAfter) {
                vm.warp(notifyAfter + 1);
            }

            if (amountToken1 > 0) {
                deal(address(mamoToken), address(fMamoSafe), amountToken1);
            }
            if (amountToken2 > 0) {
                deal(address(cbBtcToken), address(fMamoSafe), amountToken2);
            }

            rewardsModule.notifyRewards();
        }
    }

    function _configureSwapTokens() internal {
        // CL pools on Aerodrome use 200 tick spacing for volatile assets
        int24 volatileTickSpacing = 200;

        dropAutomation.addSwapToken(address(wethToken), volatileTickSpacing);
        dropAutomation.addSwapToken(ZORA_TOKEN, volatileTickSpacing);
        dropAutomation.addSwapToken(EDGE_TOKEN, volatileTickSpacing);
        dropAutomation.addSwapToken(VIRTUALS_TOKEN, volatileTickSpacing);
    }
}
