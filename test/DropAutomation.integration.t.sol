// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.t.sol";

import {DropAutomation} from "@contracts/DropAutomation.sol";
import {RewardsDistributorSafeModule} from "@contracts/RewardsDistributorSafeModule.sol";

import {IAerodromeGauge} from "@contracts/interfaces/IAerodromeGauge.sol";
import {DeployDropAutomation} from "@script/DeployDropAutomation.s.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ISafe} from "@contracts/interfaces/ISafe.sol";

contract DropAutomationIntegrationTest is BaseTest, DeployDropAutomation {
    DropAutomation public dropAutomation;
    RewardsDistributorSafeModule public rewardsModule;

    IERC20 public mamoToken;
    IERC20 public cbBtcToken;
    IERC20 public wethToken;

    ISafe public fMamoSafe;
    address public owner;
    address public dedicatedSender;

    uint256 internal constant MAMO_TOP_UP = 5_000e18;
    uint256 internal constant CBBTC_TOP_UP = 1e7; // 0.1 cbBTC (8 decimals)
    uint256 internal constant WETH_TOP_UP = 1e15; // 0.001 WETH
    uint256 internal constant EXTRA_TOKEN_TOP_UP = 1e18;

    // Additional swap tokens collected during earn (all volatile CL-200 pools vs MAMO)
    address internal constant ZORA_TOKEN = 0x1111111111166b7FE7bd91427724B487980aFc69;
    address internal constant EDGE_TOKEN = 0xED6E000dEF95780fb89734c07EE2ce9F6dcAf110;
    address internal constant VIRTUALS_TOKEN = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;

    // Events to test
    event DedicatedMsgSenderUpdated(address indexed oldSender, address indexed newSender);
    event SwapTokenAdded(address indexed token, int24 tickSpacing);
    event SwapTokenRemoved(address indexed token);
    event SwapRouteUpdated(address indexed token, int24 tickSpacing);
    event MaxSlippageUpdated(uint256 oldValueBps, uint256 newValueBps);
    event DropCreated(uint256 mamoAmount, uint256 cbBtcAmount);

    function setUp() public override {
        super.setUp();

        // Check if DropAutomation already exists, otherwise deploy it
        if (addresses.isAddressSet("DROP_AUTOMATION")) {
            dropAutomation = DropAutomation(addresses.getAddress("DROP_AUTOMATION"));
        } else {
            // Deploy DropAutomation via the deploy script
            dropAutomation = DropAutomation(deploy(addresses));
        }

        // Get addresses from the deployed contract
        owner = addresses.getAddress("F-MAMO");
        dedicatedSender = addresses.getAddress("GELATO_SENDER");

        mamoToken = IERC20(dropAutomation.MAMO_TOKEN());
        cbBtcToken = IERC20(dropAutomation.CBBTC_TOKEN());
        wethToken = IERC20(addresses.getAddress("WETH"));

        rewardsModule = RewardsDistributorSafeModule(address(dropAutomation.SAFE_REWARDS_DISTRIBUTOR_MODULE()));
        fMamoSafe = ISafe(payable(dropAutomation.F_MAMO_SAFE()));

        _ensureModuleReady();
        _configureSwapTokens();
    }

    function testInitialization() public view {
        assertEq(address(dropAutomation.MAMO_TOKEN()), addresses.getAddress("MAMO"), "incorrect MAMO token");
        assertEq(address(dropAutomation.CBBTC_TOKEN()), addresses.getAddress("cbBTC"), "incorrect cbBTC token");
        assertEq(dropAutomation.F_MAMO_SAFE(), addresses.getAddress("F-MAMO"), "incorrect F-MAMO safe");
        assertEq(
            address(dropAutomation.SAFE_REWARDS_DISTRIBUTOR_MODULE()),
            addresses.getAddress("REWARDS_DISTRIBUTOR_MAMO_CBBTC"),
            "incorrect rewards module"
        );
        assertEq(dropAutomation.dedicatedMsgSender(), dedicatedSender, "incorrect dedicated sender");
        assertEq(dropAutomation.owner(), addresses.getAddress("F-MAMO"), "incorrect owner");
        assertEq(dropAutomation.maxSlippageBps(), 100, "incorrect default slippage");
    }

    function testOwnerFunctions() public {
        // Test setDedicatedMsgSender
        address newSender = makeAddr("newSender");
        vm.expectEmit(true, true, false, false);
        emit DedicatedMsgSenderUpdated(dedicatedSender, newSender);

        vm.prank(owner);
        dropAutomation.setDedicatedMsgSender(newSender);
        assertEq(dropAutomation.dedicatedMsgSender(), newSender, "sender should be updated");

        // Test setMaxSlippageBps
        vm.expectEmit(false, false, false, true);
        emit MaxSlippageUpdated(100, 300);

        vm.prank(owner);
        dropAutomation.setMaxSlippageBps(300);
        assertEq(dropAutomation.maxSlippageBps(), 300, "slippage should be updated");

        // Test addSwapToken
        address testToken = makeAddr("testToken");
        vm.expectEmit(true, false, false, true);
        emit SwapTokenAdded(testToken, 200);

        vm.prank(owner);
        dropAutomation.addSwapToken(testToken, 200);
        assertTrue(dropAutomation.isSwapToken(testToken), "token should be added");
        assertEq(dropAutomation.swapTickSpacing(testToken), 200, "tick spacing should be set");

        // Test setSwapTickSpacing
        vm.expectEmit(true, false, false, true);
        emit SwapRouteUpdated(testToken, 100);

        vm.prank(owner);
        dropAutomation.setSwapTickSpacing(testToken, 100);
        assertEq(dropAutomation.swapTickSpacing(testToken), 100, "tick spacing should be updated");

        // Test removeSwapToken
        vm.expectEmit(true, false, false, false);
        emit SwapTokenRemoved(testToken);

        vm.prank(owner);
        dropAutomation.removeSwapToken(testToken);
        assertFalse(dropAutomation.isSwapToken(testToken), "token should be removed");
        assertEq(dropAutomation.swapTickSpacing(testToken), 0, "tick spacing should be cleared");

        // Test recoverERC20
        address recipient = makeAddr("recipient");
        deal(address(mamoToken), address(dropAutomation), 100e18);

        vm.prank(owner);
        dropAutomation.recoverERC20(address(mamoToken), recipient, 100e18);
        assertEq(mamoToken.balanceOf(recipient), 100e18, "tokens should be recovered");
    }

    function testAccessControl() public {
        address attacker = makeAddr("attacker");
        address testToken = makeAddr("testToken");

        // Test only owner can call setDedicatedMsgSender
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        dropAutomation.setDedicatedMsgSender(attacker);

        // Test only owner can call setMaxSlippageBps
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        dropAutomation.setMaxSlippageBps(100);

        // Test only owner can call addSwapToken
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        dropAutomation.addSwapToken(testToken, 200);

        // Test only owner can call removeSwapToken
        vm.prank(owner);
        dropAutomation.addSwapToken(testToken, 200);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        dropAutomation.removeSwapToken(testToken);

        // Test only owner can call setSwapTickSpacing
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        dropAutomation.setSwapTickSpacing(testToken, 100);

        // Test only owner can call recoverERC20
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        dropAutomation.recoverERC20(address(mamoToken), attacker, 100e18);

        // Test only dedicatedMsgSender can call createDrop
        vm.prank(attacker);
        vm.expectRevert(DropAutomation.NotDedicatedSender.selector);
        dropAutomation.createDrop();
    }

    function testValidationErrors() public {
        // Test invalid dedicated sender
        vm.prank(owner);
        vm.expectRevert("Invalid dedicated sender");
        dropAutomation.setDedicatedMsgSender(address(0));

        // Test invalid slippage
        vm.prank(owner);
        vm.expectRevert(DropAutomation.InvalidSlippage.selector);
        dropAutomation.setMaxSlippageBps(0);

        vm.prank(owner);
        vm.expectRevert(DropAutomation.InvalidSlippage.selector);
        dropAutomation.setMaxSlippageBps(501); // Over 5% cap

        // Test adding invalid swap token
        vm.prank(owner);
        vm.expectRevert("Invalid token");
        dropAutomation.addSwapToken(address(0), 200);

        vm.prank(owner);
        vm.expectRevert("MAMO excluded");
        dropAutomation.addSwapToken(address(mamoToken), 200);

        vm.prank(owner);
        vm.expectRevert("CBBTC excluded");
        dropAutomation.addSwapToken(address(cbBtcToken), 200);

        // Test adding duplicate token
        address testToken = makeAddr("testToken");
        vm.prank(owner);
        dropAutomation.addSwapToken(testToken, 200);

        vm.prank(owner);
        vm.expectRevert("Token already added");
        dropAutomation.addSwapToken(testToken, 200);

        // Test invalid tick spacing
        address newToken = makeAddr("newToken");
        vm.prank(owner);
        vm.expectRevert("Invalid tick spacing");
        dropAutomation.addSwapToken(newToken, 0);

        // Test removing non-existent token
        address nonExistentToken = makeAddr("nonExistentToken");
        vm.prank(owner);
        vm.expectRevert("Token not configured");
        dropAutomation.removeSwapToken(nonExistentToken);

        // Test setting tick spacing for non-configured token
        vm.prank(owner);
        vm.expectRevert("Token not configured");
        dropAutomation.setSwapTickSpacing(nonExistentToken, 100);

        // Test recoverERC20 with invalid params
        vm.prank(owner);
        vm.expectRevert("Invalid token");
        dropAutomation.recoverERC20(address(0), owner, 100e18);

        vm.prank(owner);
        vm.expectRevert("Invalid recipient");
        dropAutomation.recoverERC20(address(mamoToken), address(0), 100e18);
    }

    function testGetSwapTokens() public {
        // Initially should have configured tokens from _configureSwapTokens
        address[] memory tokens = dropAutomation.getSwapTokens();
        assertEq(tokens.length, 4, "should have 4 tokens initially");

        // Add a new token
        address newToken = makeAddr("newToken");
        vm.prank(owner);
        dropAutomation.addSwapToken(newToken, 200);

        tokens = dropAutomation.getSwapTokens();
        assertEq(tokens.length, 5, "should have 5 tokens after adding");
        assertEq(tokens[4], newToken, "new token should be at the end");

        // Remove a token
        vm.prank(owner);
        dropAutomation.removeSwapToken(tokens[0]);

        tokens = dropAutomation.getSwapTokens();
        assertEq(tokens.length, 4, "should have 4 tokens after removing");
    }

    function test_createDrop_endToEnd() public {
        // Top up DropAutomation with tokens that would normally be collected by earn
        deal(address(mamoToken), address(dropAutomation), MAMO_TOP_UP);
        deal(address(cbBtcToken), address(dropAutomation), CBBTC_TOP_UP);
        deal(address(wethToken), address(dropAutomation), WETH_TOP_UP);
        deal(ZORA_TOKEN, address(dropAutomation), EXTRA_TOKEN_TOP_UP);
        deal(EDGE_TOKEN, address(dropAutomation), EXTRA_TOKEN_TOP_UP);
        deal(VIRTUALS_TOKEN, address(dropAutomation), EXTRA_TOKEN_TOP_UP);

        // Configure gauge so AERO rewards can be processed
        address gauge = addresses.getAddress("AERODROME_USDC_AERO_GAUGE");
        address aeroToken = addresses.getAddress("AERO");
        address stakingToken = addresses.getAddress("AERO_STAKING_TOKEN");

        vm.prank(owner);
        dropAutomation.addGauge(gauge);

        // Add AERO tokens to simulate gauge rewards
        deal(aeroToken, address(dropAutomation), EXTRA_TOKEN_TOP_UP);

        uint256 safeMamoBefore = mamoToken.balanceOf(address(fMamoSafe));
        uint256 safeCbBtcBefore = cbBtcToken.balanceOf(address(fMamoSafe));

        vm.prank(dedicatedSender);
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
        assertEq(IERC20(aeroToken).balanceOf(address(dropAutomation)), 0, "Drop should swap AERO balance");
    }

    function _ensureModuleReady() internal {
        // Make DropAutomation the admin so it can call addRewards
        vm.startPrank(address(fMamoSafe));
        if (rewardsModule.admin() != address(dropAutomation)) {
            rewardsModule.setAdmin(address(dropAutomation));
        }
        vm.stopPrank();

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

        vm.startPrank(owner);
        if (!dropAutomation.isSwapToken(address(wethToken))) {
            dropAutomation.addSwapToken(address(wethToken), volatileTickSpacing);
        }
        if (!dropAutomation.isSwapToken(ZORA_TOKEN)) {
            dropAutomation.addSwapToken(ZORA_TOKEN, volatileTickSpacing);
        }
        if (!dropAutomation.isSwapToken(EDGE_TOKEN)) {
            dropAutomation.addSwapToken(EDGE_TOKEN, volatileTickSpacing);
        }
        if (!dropAutomation.isSwapToken(VIRTUALS_TOKEN)) {
            dropAutomation.addSwapToken(VIRTUALS_TOKEN, volatileTickSpacing);
        }
        vm.stopPrank();
    }

    function testGaugeConfiguration() public {
        address gauge = addresses.getAddress("AERODROME_USDC_AERO_GAUGE");
        address aeroToken = addresses.getAddress("AERO");
        address stakingToken = addresses.getAddress("AERO_STAKING_TOKEN");

        // Initially no gauges should be configured
        assertEq(dropAutomation.getGaugeCount(), 0, "should have no gauges initially");
        assertFalse(dropAutomation.isConfiguredGauge(gauge), "gauge should not be configured initially");

        // Only owner can add gauge
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        dropAutomation.addGauge(gauge);

        // Owner adds gauge
        vm.prank(owner);
        dropAutomation.addGauge(gauge);

        // Verify configuration
        assertEq(dropAutomation.getGaugeCount(), 1, "should have 1 gauge configured");
        assertTrue(dropAutomation.isConfiguredGauge(gauge), "gauge should be configured");
        assertEq(address(dropAutomation.aerodromeGauges(0)), gauge, "first gauge should be the configured gauge");
    }

    function testTransferGaugePositionFromFMamo() public {
        // Configure gauge first
        address gauge = addresses.getAddress("AERODROME_USDC_AERO_GAUGE");
        address aeroToken = addresses.getAddress("AERO");
        address stakingToken = addresses.getAddress("AERO_STAKING_TOKEN");

        vm.prank(owner);
        dropAutomation.addGauge(gauge);

        // Check F-MAMO's current gauge balance
        IAerodromeGauge gaugeContract = IAerodromeGauge(gauge);
        uint256 fMamoBalance = gaugeContract.balanceOf(addresses.getAddress("F-MAMO"));

        if (fMamoBalance > 0) {
            // F-MAMO withdraws from gauge
            vm.startPrank(addresses.getAddress("F-MAMO"));
            gaugeContract.withdraw(fMamoBalance);

            // Get the LP token and transfer to DropAutomation
            IERC20 lpToken = IERC20(stakingToken);
            uint256 lpBalance = lpToken.balanceOf(addresses.getAddress("F-MAMO"));
            assertGt(lpBalance, 0, "F-MAMO should have LP tokens after withdrawal");

            // Re-deposit LP tokens to gauge with DropAutomation as recipient
            lpToken.approve(gauge, lpBalance);
            gaugeContract.deposit(lpBalance, address(dropAutomation));
            vm.stopPrank();

            // Verify staking
            assertEq(
                gaugeContract.balanceOf(address(dropAutomation)),
                lpBalance,
                "DropAutomation should have staked LP tokens"
            );
        }
    }

    function testHarvestGaugeRewards() public {
        // Setup gauge configuration
        address gauge = addresses.getAddress("AERODROME_USDC_AERO_GAUGE");
        address aeroToken = addresses.getAddress("AERO");
        address stakingToken = addresses.getAddress("AERO_STAKING_TOKEN");

        vm.prank(owner);
        dropAutomation.addGauge(gauge);

        // Transfer gauge position from F-MAMO to DropAutomation
        IAerodromeGauge gaugeContract = IAerodromeGauge(gauge);
        uint256 fMamoBalance = gaugeContract.balanceOf(addresses.getAddress("F-MAMO"));

        if (fMamoBalance > 0) {
            // F-MAMO withdraws and re-deposits with DropAutomation as recipient
            vm.startPrank(addresses.getAddress("F-MAMO"));
            gaugeContract.withdraw(fMamoBalance);

            IERC20 lpToken = IERC20(stakingToken);
            uint256 lpBalance = lpToken.balanceOf(addresses.getAddress("F-MAMO"));

            // Re-deposit LP tokens to gauge with DropAutomation as recipient
            lpToken.approve(gauge, lpBalance);
            gaugeContract.deposit(lpBalance, address(dropAutomation));
            vm.stopPrank();

            // Move time forward to accumulate rewards
            vm.warp(block.timestamp + 7 days);
            vm.roll(block.number + 50400); // ~7 days of blocks

            // Record balances before harvest
            IERC20 aero = IERC20(aeroToken);
            IERC20 cbBtc = IERC20(addresses.getAddress("cbBTC"));
            uint256 aeroBefore = aero.balanceOf(address(dropAutomation));
            uint256 cbBtcBefore = cbBtc.balanceOf(address(dropAutomation));

            // Anyone can call harvestGaugeRewards
            dropAutomation.harvestGaugeRewards();

            // Check if rewards were harvested and converted to cbBTC
            uint256 aeroAfter = aero.balanceOf(address(dropAutomation));
            uint256 cbBtcAfter = cbBtc.balanceOf(address(dropAutomation));

            // AERO should be swapped away (balance should be same or less)
            assertLe(aeroAfter, aeroBefore, "AERO should be swapped to cbBTC");

            // cbBTC balance should increase if there were rewards
            if (aeroAfter < aeroBefore || gaugeContract.earned(address(dropAutomation)) > 0) {
                assertGt(cbBtcAfter, cbBtcBefore, "cbBTC balance should increase from AERO swap");
            }
        }
    }

    function testWithdrawGauge() public {
        // Setup gauge with staked position
        address gauge = addresses.getAddress("AERODROME_USDC_AERO_GAUGE");
        address aeroToken = addresses.getAddress("AERO");
        address stakingToken = addresses.getAddress("AERO_STAKING_TOKEN");

        vm.prank(owner);
        dropAutomation.addGauge(gauge);

        IAerodromeGauge gaugeContract = IAerodromeGauge(gauge);
        IERC20 lpToken = IERC20(stakingToken);

        // Deal and stake LP tokens directly to gauge for DropAutomation
        uint256 amount = 1e18;
        deal(stakingToken, address(this), amount);

        lpToken.approve(gauge, amount);
        gaugeContract.deposit(amount, address(dropAutomation));

        uint256 stakedBalance = gaugeContract.balanceOf(address(dropAutomation));
        assertEq(stakedBalance, amount, "Should have staked balance");

        // Only owner can withdraw
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        dropAutomation.withdrawGauge(gauge, amount, makeAddr("recipient"));

        // Owner withdraws
        address recipient = makeAddr("recipient");
        vm.prank(owner);
        dropAutomation.withdrawGauge(gauge, amount, recipient);

        // Verify withdrawal
        assertEq(gaugeContract.balanceOf(address(dropAutomation)), 0, "Staked balance should be 0");
        assertEq(lpToken.balanceOf(recipient), amount, "Recipient should receive LP tokens");
    }

    function testRecoverERC20WithZeroAmount() public {
        address testToken = address(wethToken);
        uint256 testAmount = 5e18;
        address recipient = makeAddr("emergencyRecipient");

        // Deal some tokens to the contract
        deal(testToken, address(dropAutomation), testAmount);

        // Verify initial balance
        assertEq(IERC20(testToken).balanceOf(address(dropAutomation)), testAmount, "Contract should have test tokens");
        assertEq(IERC20(testToken).balanceOf(recipient), 0, "Recipient should start with 0 tokens");

        // Only owner can call recover
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        dropAutomation.recoverERC20(testToken, recipient, 0);

        // Test invalid token address
        vm.prank(owner);
        vm.expectRevert("Invalid token");
        dropAutomation.recoverERC20(address(0), recipient, 0);

        // Test invalid recipient address
        vm.prank(owner);
        vm.expectRevert("Invalid recipient");
        dropAutomation.recoverERC20(testToken, address(0), 0);

        // Test withdraw all (amount = 0)
        vm.prank(owner);
        dropAutomation.recoverERC20(testToken, recipient, 0); // This should withdraw all

        // Now test with no balance (should revert)
        vm.prank(owner);
        vm.expectRevert("No balance to withdraw");
        dropAutomation.recoverERC20(testToken, recipient, 0);

        // Verify the successful withdrawal
        assertEq(
            IERC20(testToken).balanceOf(address(dropAutomation)), 0, "Contract should have 0 tokens after withdrawal"
        );
        assertEq(IERC20(testToken).balanceOf(recipient), testAmount, "Recipient should receive all tokens");
    }

    function testRecoverERC20EmitsEvent() public {
        address testToken = address(mamoToken);
        uint256 testAmount = 10e18;
        address recipient = makeAddr("eventRecipient");

        // Deal some tokens to the contract
        deal(testToken, address(dropAutomation), testAmount);

        // Expect the event to be emitted
        vm.expectEmit(true, true, true, true);
        emit TokensRecovered(testToken, recipient, testAmount);

        // Execute recovery with specific amount
        vm.prank(owner);
        dropAutomation.recoverERC20(testToken, recipient, testAmount);
    }

    function testRecoverERC20PartialAmount() public {
        address token1 = address(wethToken);
        address token2 = address(mamoToken);
        uint256 amount1 = 10e18;
        uint256 amount2 = 20e18;
        uint256 withdrawAmount1 = 3e18;
        uint256 withdrawAmount2 = 7e18;
        address recipient = makeAddr("multiTokenRecipient");

        // Deal multiple tokens to the contract
        deal(token1, address(dropAutomation), amount1);
        deal(token2, address(dropAutomation), amount2);

        // Withdraw partial amount from first token
        vm.prank(owner);
        dropAutomation.recoverERC20(token1, recipient, withdrawAmount1);

        // Withdraw partial amount from second token
        vm.prank(owner);
        dropAutomation.recoverERC20(token2, recipient, withdrawAmount2);

        // Verify partial withdrawals
        assertEq(
            IERC20(token1).balanceOf(address(dropAutomation)),
            amount1 - withdrawAmount1,
            "Contract should have remaining token1"
        );
        assertEq(
            IERC20(token2).balanceOf(address(dropAutomation)),
            amount2 - withdrawAmount2,
            "Contract should have remaining token2"
        );
        assertEq(IERC20(token1).balanceOf(recipient), withdrawAmount1, "Recipient should receive partial token1");
        assertEq(IERC20(token2).balanceOf(recipient), withdrawAmount2, "Recipient should receive partial token2");
    }

    function testAddAndRemoveGauge() public {
        address gauge = addresses.getAddress("AERODROME_USDC_AERO_GAUGE");
        address aeroToken = addresses.getAddress("AERO");
        address stakingToken = addresses.getAddress("AERO_STAKING_TOKEN");

        // Initially no gauges
        assertEq(dropAutomation.getGaugeCount(), 0, "should start with 0 gauges");

        // Add gauge
        vm.expectEmit(true, true, true, true);
        emit GaugeAdded(gauge, aeroToken, stakingToken);

        vm.prank(owner);
        dropAutomation.addGauge(gauge);

        // Verify addition
        assertEq(dropAutomation.getGaugeCount(), 1, "should have 1 gauge after adding");
        assertTrue(dropAutomation.isConfiguredGauge(gauge), "gauge should be configured");
        assertEq(address(dropAutomation.aerodromeGauges(0)), gauge, "gauge should be at index 0");

        // Cannot add same gauge twice
        vm.prank(owner);
        vm.expectRevert("Gauge already configured");
        dropAutomation.addGauge(gauge);

        // Remove gauge
        vm.prank(owner);
        dropAutomation.removeGauge(gauge);

        // Verify removal
        assertEq(dropAutomation.getGaugeCount(), 0, "should have 0 gauges after removal");
        assertFalse(dropAutomation.isConfiguredGauge(gauge), "gauge should not be configured after removal");
    }

    // Update event definitions for the test
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event GaugeAdded(address indexed gauge, address indexed rewardToken, address indexed stakingToken);
}
