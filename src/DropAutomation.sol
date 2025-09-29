// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAerodromeGauge} from "./interfaces/IAerodromeGauge.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IQuoter} from "@interfaces/IQuoter.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

/**
 * @notice Interface for the rewards distributor safe module
 */
interface IRewardsDistributorSafeModule {
    /**
     * @notice Adds reward amounts to be distributed
     * @param amountToken1 Amount of MAMO tokens to distribute
     * @param amountToken2 Amount of cbBTC tokens to distribute
     */
    function addRewards(uint256 amountToken1, uint256 amountToken2) external;
}

/**
 * @title DropAutomation
 * @notice Automates weekly reward drops by swapping rewards into MAMO via Aerodrome and
 *         forwarding the resulting MAMO/cbBTC balances to the F-MAMO Safe rewards module.
 */
contract DropAutomation is Ownable {
    using SafeERC20 for IERC20;

    /// @dev MAMO token
    IERC20 public immutable MAMO_TOKEN;

    /// @dev cbBTC token
    IERC20 public immutable CBBTC_TOKEN;

    /// @dev F-MAMO Safe multisig address receiving reward tokens
    address public immutable F_MAMO_SAFE;

    /// @dev Safe module responsible for staging reward distributions
    IRewardsDistributorSafeModule public immutable SAFE_REWARDS_DISTRIBUTOR_MODULE;

    /// @dev Aerodrome CL router used to swap earned rewards into MAMO
    ISwapRouter public immutable AERODROME_CL_ROUTER;

    /// @dev Aerodrome quoter used to fetch swap estimates for slippage protection
    IQuoter public immutable AERODROME_QUOTER;

    /// @notice List of configured Aerodrome gauges for earning rewards
    IAerodromeGauge[] public aerodromeGauges;

    /// @notice Mapping to check if a gauge is configured
    mapping(address => bool) public isConfiguredGauge;

    /// @notice Mapping from gauge address to its index in the aerodromeGauges array
    mapping(address => uint256) public gaugeIndex;

    /// @notice Address authorized to trigger reward drops
    address public dedicatedMsgSender;

    /// @notice Tokens that must be swapped to MAMO before calling addRewards
    address[] private swapTokens;

    /// @notice Helper mapping to check if a token is part of the swap set
    mapping(address => bool) public isSwapToken;

    /// @notice Tick spacing for each swap token's pool with MAMO
    mapping(address => int24) public swapTickSpacing;

    /// @notice Maximum slippage tolerance in basis points applied to each swap
    uint256 public maxSlippageBps;

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant MAX_SLIPPAGE_CAP_BPS = 500; // 5% maximum allowed slippage
    uint256 private constant DEFAULT_SLIPPAGE_BPS = 100; // 1% default slippage
    uint256 private constant SWAP_DEADLINE_BUFFER = 300; // 5 minutes deadline buffer for MEV protection
    int24 private constant MAMO_CBBTC_TICK_SPACING = 200; // Tick spacing for MAMO/cbBTC CL pool
    int24 private constant AERO_CBBTC_TICK_SPACING = 200; // Tick spacing for AERO/cbBTC CL pool

    event DropCreated(uint256 mamoAmount, uint256 cbBtcAmount);
    event DedicatedMsgSenderUpdated(address indexed oldSender, address indexed newSender);
    event SwapTokenAdded(address indexed token, int24 tickSpacing);
    event SwapTokenRemoved(address indexed token);
    event SwapRouteUpdated(address indexed token, int24 tickSpacing);
    event TokensSwapped(address indexed token, uint256 amountIn, uint256 amountOut);
    event MaxSlippageUpdated(uint256 oldValueBps, uint256 newValueBps);
    event GaugeAdded(address indexed gauge, address indexed rewardToken, address indexed stakingToken);
    event GaugeRemoved(address indexed gauge);
    event GaugeRewardsHarvested(address indexed gauge, uint256 rewardAmount, uint256 cbBtcAmount);
    event GaugeWithdrawn(address indexed gauge, address indexed recipient, uint256 amount);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    error NotDedicatedSender();
    error InvalidSlippage();
    error GaugeNotConfigured();

    /**
     * @notice Restricts function access to the dedicated message sender
     * @dev Reverts with NotDedicatedSender if called by any other address
     */
    modifier onlyDedicatedMsgSender() {
        if (msg.sender != dedicatedMsgSender) {
            revert NotDedicatedSender();
        }
        _;
    }

    /**
     * @notice Initializes the DropAutomation contract
     * @param owner_ Address of the contract owner
     * @param dedicatedMsgSender_ Address authorized to trigger reward drops
     * @param mamoToken_ Address of the MAMO token
     * @param cbBtcToken_ Address of the cbBTC token
     * @param fMamoSafe_ Address of the F-MAMO Safe multisig
     * @param safeRewardsDistributorModule_ Address of the rewards distributor module
     * @param aerodromeRouter_ Address of the Aerodrome CL swap router
     * @param aerodromeQuoter_ Address of the Aerodrome quoter for price estimates
     */
    constructor(
        address owner_,
        address dedicatedMsgSender_,
        address mamoToken_,
        address cbBtcToken_,
        address fMamoSafe_,
        address safeRewardsDistributorModule_,
        address aerodromeRouter_,
        address aerodromeQuoter_
    ) Ownable(owner_) {
        require(owner_ != address(0), "Invalid owner");
        require(dedicatedMsgSender_ != address(0), "Invalid dedicated sender");
        require(mamoToken_ != address(0), "Invalid MAMO token");
        require(cbBtcToken_ != address(0), "Invalid cbBTC token");
        require(fMamoSafe_ != address(0), "Invalid F-MAMO safe");
        require(safeRewardsDistributorModule_ != address(0), "Invalid rewards module");
        require(aerodromeRouter_ != address(0), "Invalid Aerodrome router");
        require(aerodromeQuoter_ != address(0), "Invalid Aerodrome quoter");

        dedicatedMsgSender = dedicatedMsgSender_;
        MAMO_TOKEN = IERC20(mamoToken_);
        CBBTC_TOKEN = IERC20(cbBtcToken_);
        F_MAMO_SAFE = fMamoSafe_;
        SAFE_REWARDS_DISTRIBUTOR_MODULE = IRewardsDistributorSafeModule(safeRewardsDistributorModule_);
        AERODROME_CL_ROUTER = ISwapRouter(aerodromeRouter_);
        AERODROME_QUOTER = IQuoter(aerodromeQuoter_);
        maxSlippageBps = DEFAULT_SLIPPAGE_BPS;
    }

    /**
     * @notice Returns the list of tokens configured for MAMO swaps
     * @return Array of token addresses that will be swapped to MAMO
     */
    function getSwapTokens() external view returns (address[] memory) {
        return swapTokens;
    }

    /**
     * @notice Harvests gauge rewards and converts to cbBTC (public for testing)
     * @dev Anyone can call this to test gauge reward harvesting without executing full drop
     */
    function harvestGaugeRewards() external {
        _harvestGaugeRewardsToCbBtc();
    }

    /**
     * @notice Main automation entry point
     * @dev Executes earn cycle, swaps configured tokens to MAMO, and forwards rewards to the Safe
     */
    function createDrop() external onlyDedicatedMsgSender {
        _harvestGaugeRewardsToCbBtc();
        _swapTokensToMamoAndCbBtc();

        uint256 mamoBalance = MAMO_TOKEN.balanceOf(address(this));
        uint256 cbBtcBalance = CBBTC_TOKEN.balanceOf(address(this));

        require(mamoBalance > 0 || cbBtcBalance > 0, "No rewards to distribute");

        if (mamoBalance > 0) {
            MAMO_TOKEN.safeTransfer(F_MAMO_SAFE, mamoBalance);
        }

        if (cbBtcBalance > 0) {
            CBBTC_TOKEN.safeTransfer(F_MAMO_SAFE, cbBtcBalance);
        }

        SAFE_REWARDS_DISTRIBUTOR_MODULE.addRewards(mamoBalance, cbBtcBalance);

        emit DropCreated(mamoBalance, cbBtcBalance);
    }

    /**
     * @notice Adds a new token to the swap list
     * @param token Address of the token to add
     * @param tickSpacing Tick spacing for the token's pool with MAMO
     * @dev Only callable by owner. Token must not be MAMO, cbBTC, or already added
     */
    function addSwapToken(address token, int24 tickSpacing) external onlyOwner {
        require(token != address(0), "Invalid token");
        require(token != address(MAMO_TOKEN), "MAMO excluded");
        require(token != address(CBBTC_TOKEN), "CBBTC excluded");
        require(!isSwapToken[token], "Token already added");
        require(tickSpacing > 0, "Invalid tick spacing");

        swapTokens.push(token);
        isSwapToken[token] = true;
        swapTickSpacing[token] = tickSpacing;

        emit SwapTokenAdded(token, tickSpacing);
    }

    /**
     * @notice Updates the tick spacing for a configured swap token
     * @param token Address of the token to update
     * @param tickSpacing New tick spacing for the token's pool with MAMO
     * @dev Only callable by owner. Token must already be configured
     */
    function setSwapTickSpacing(address token, int24 tickSpacing) external onlyOwner {
        require(isSwapToken[token], "Token not configured");
        require(tickSpacing > 0, "Invalid tick spacing");
        swapTickSpacing[token] = tickSpacing;
        emit SwapRouteUpdated(token, tickSpacing);
    }

    /**
     * @notice Removes a token from the swap list
     * @param token Address of the token to remove
     * @dev Only callable by owner. Token must be currently configured
     */
    function removeSwapToken(address token) external onlyOwner {
        require(isSwapToken[token], "Token not configured");

        uint256 length = swapTokens.length;
        for (uint256 i = 0; i < length; i++) {
            if (swapTokens[i] == token) {
                swapTokens[i] = swapTokens[length - 1];
                swapTokens.pop();
                break;
            }
        }

        isSwapToken[token] = false;
        delete swapTickSpacing[token];

        emit SwapTokenRemoved(token);
    }

    /**
     * @notice Updates the dedicated automation sender address
     * @param newSender Address of the new dedicated sender
     */
    function setDedicatedMsgSender(address newSender) external onlyOwner {
        require(newSender != address(0), "Invalid dedicated sender");
        emit DedicatedMsgSenderUpdated(dedicatedMsgSender, newSender);
        dedicatedMsgSender = newSender;
    }

    /**
     * @notice Updates the maximum allowed slippage for swaps
     * @param newSlippageBps New slippage tolerance in basis points (1-500)
     * @dev Only callable by owner. Must be between 1 and 500 bps (0.01% - 5%)
     */
    function setMaxSlippageBps(uint256 newSlippageBps) external onlyOwner {
        if (newSlippageBps == 0 || newSlippageBps > MAX_SLIPPAGE_CAP_BPS) {
            revert InvalidSlippage();
        }

        emit MaxSlippageUpdated(maxSlippageBps, newSlippageBps);
        maxSlippageBps = newSlippageBps;
    }

    /**
     * @notice Adds an Aerodrome gauge for reward harvesting
     * @param gauge_ Address of the Aerodrome gauge contract
     */
    function addGauge(address gauge_) external onlyOwner {
        require(gauge_ != address(0), "Invalid gauge");
        require(gauge_.code.length > 0, "Gauge not deployed");
        require(!isConfiguredGauge[gauge_], "Gauge already configured");

        // Read tokens directly from gauge contract
        address rewardToken = IAerodromeGauge(gauge_).rewardToken();
        address stakingToken = IAerodromeGauge(gauge_).stakingToken();
        require(rewardToken != address(0), "Invalid reward token");
        require(stakingToken != address(0), "Invalid staking token");

        // Add gauge to array and mappings
        gaugeIndex[gauge_] = aerodromeGauges.length;
        aerodromeGauges.push(IAerodromeGauge(gauge_));
        isConfiguredGauge[gauge_] = true;

        emit GaugeAdded(gauge_, rewardToken, stakingToken);
    }

    /**
     * @notice Removes an Aerodrome gauge from reward harvesting
     * @param gauge_ Address of the Aerodrome gauge contract to remove
     */
    function removeGauge(address gauge_) external onlyOwner {
        require(isConfiguredGauge[gauge_], "Gauge not configured");

        uint256 index = gaugeIndex[gauge_];
        uint256 lastIndex = aerodromeGauges.length - 1;

        // Move last gauge to the index of gauge being removed
        if (index != lastIndex) {
            IAerodromeGauge lastGauge = aerodromeGauges[lastIndex];
            aerodromeGauges[index] = lastGauge;
            gaugeIndex[address(lastGauge)] = index;
        }

        // Remove last element and clean mappings
        aerodromeGauges.pop();
        delete gaugeIndex[gauge_];
        isConfiguredGauge[gauge_] = false;

        emit GaugeRemoved(gauge_);
    }

    /**
     * @notice Returns the number of configured gauges
     * @return Number of gauges in the array
     */
    function getGaugeCount() external view returns (uint256) {
        return aerodromeGauges.length;
    }

    /**
     * @notice Withdraws staked LP tokens from a specific Aerodrome gauge
     * @param gauge_ Address of the gauge to withdraw from
     * @param amount Amount of LP tokens to withdraw
     * @param recipient Address receiving the withdrawn LP tokens
     */
    function withdrawGauge(address gauge_, uint256 amount, address recipient) external onlyOwner {
        require(isConfiguredGauge[gauge_], "Gauge not configured");
        require(amount > 0, "Amount must be greater than 0");
        require(recipient != address(0), "Invalid recipient");

        IAerodromeGauge gauge = IAerodromeGauge(gauge_);
        uint256 stakedBalance = gauge.balanceOf(address(this));
        require(amount <= stakedBalance, "Insufficient gauge balance");

        gauge.withdraw(amount);

        // Get staking token from gauge and transfer
        address stakingToken = gauge.stakingToken();
        IERC20(stakingToken).safeTransfer(recipient, amount);

        emit GaugeWithdrawn(gauge_, recipient, amount);
    }

    /**
     * @notice Recovers arbitrary ERC20 tokens held by the contract
     * @param token Address of the token to recover
     * @param to Recipient of the recovered tokens
     * @param amount Amount of tokens to recover (0 = withdraw all)
     * @dev Only callable by owner. If amount is 0, withdraws entire balance
     */
    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(0), "Invalid token");
        require(to != address(0), "Invalid recipient");

        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(address(this));
        require(balance > 0, "No balance to withdraw");

        uint256 transferAmount = amount == 0 ? balance : amount;
        require(transferAmount <= balance, "Insufficient balance");

        tokenContract.safeTransfer(to, transferAmount);

        emit TokensRecovered(token, to, transferAmount);
    }

    /**
     * @notice Harvests rewards from all configured gauges and converts to cbBTC
     * @dev Iterates through all configured gauges, harvests rewards, and swaps to cbBTC
     */
    function _harvestGaugeRewardsToCbBtc() internal {
        uint256 gaugeCount = aerodromeGauges.length;
        if (gaugeCount == 0) {
            return;
        }

        for (uint256 i = 0; i < gaugeCount; i++) {
            IAerodromeGauge gauge = aerodromeGauges[i];
            address rewardTokenAddress = gauge.rewardToken();
            IERC20 rewardToken = IERC20(rewardTokenAddress);

            uint256 rewardBalanceBefore = rewardToken.balanceOf(address(this));
            uint256 cbBtcBalanceBefore = CBBTC_TOKEN.balanceOf(address(this));

            gauge.getReward(address(this));

            uint256 rewardBalanceAfter = rewardToken.balanceOf(address(this));
            if (rewardBalanceAfter == 0) {
                continue;
            }

            _swapRewardTokenToCbBtc(rewardBalanceAfter, rewardTokenAddress);

            uint256 cbBtcBalanceAfter = CBBTC_TOKEN.balanceOf(address(this));
            uint256 harvested = rewardBalanceAfter > rewardBalanceBefore ? rewardBalanceAfter - rewardBalanceBefore : 0;
            emit GaugeRewardsHarvested(address(gauge), harvested, cbBtcBalanceAfter - cbBtcBalanceBefore);
        }
    }

    function _swapRewardTokenToCbBtc(uint256 amountIn, address rewardTokenAddress) internal {
        if (amountIn == 0) {
            return;
        }

        IERC20 rewardToken = IERC20(rewardTokenAddress);
        rewardToken.forceApprove(address(AERODROME_CL_ROUTER), amountIn);

        IQuoter.QuoteExactInputSingleParams memory params = IQuoter.QuoteExactInputSingleParams({
            tokenIn: rewardTokenAddress,
            tokenOut: address(CBBTC_TOKEN),
            amountIn: amountIn,
            tickSpacing: AERO_CBBTC_TICK_SPACING,
            sqrtPriceLimitX96: 0
        });

        (uint256 quotedAmountOut,,,) = AERODROME_QUOTER.quoteExactInputSingle(params);
        require(quotedAmountOut > 0, "Invalid quote");

        uint256 minAmountOut = (quotedAmountOut * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
        require(minAmountOut > 0, "Slippage too high");

        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: rewardTokenAddress,
            tokenOut: address(CBBTC_TOKEN),
            tickSpacing: AERO_CBBTC_TICK_SPACING,
            recipient: address(this),
            deadline: block.timestamp + SWAP_DEADLINE_BUFFER,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = AERODROME_CL_ROUTER.exactInputSingle(swapParams);

        require(amountOut >= minAmountOut, "Received less than min amount");
    }

    /**
     * @notice Swaps all configured tokens to MAMO and then to cbBTC
     * @dev Iterates through swap tokens, converts each to MAMO, then swaps the received MAMO to cbBTC
     */
    function _swapTokensToMamoAndCbBtc() internal {
        uint256 length = swapTokens.length;
        for (uint256 i = 0; i < length; i++) {
            address token = swapTokens[i];
            uint256 amountIn = IERC20(token).balanceOf(address(this));
            if (amountIn == 0) {
                continue;
            }

            IERC20(token).forceApprove(address(AERODROME_CL_ROUTER), amountIn);

            int24 tickSpacing = swapTickSpacing[token];
            require(tickSpacing > 0, "Tick spacing not configured");

            IQuoter.QuoteExactInputSingleParams memory params = IQuoter.QuoteExactInputSingleParams({
                tokenIn: token,
                tokenOut: address(MAMO_TOKEN),
                amountIn: amountIn,
                tickSpacing: tickSpacing,
                sqrtPriceLimitX96: 0
            });

            (uint256 quotedAmountOut,,,) = AERODROME_QUOTER.quoteExactInputSingle(params);
            require(quotedAmountOut > 0, "Invalid quote");

            uint256 minAmountOut = (quotedAmountOut * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
            require(minAmountOut > 0, "Slippage too high");

            ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: address(MAMO_TOKEN),
                tickSpacing: tickSpacing,
                recipient: address(this),
                deadline: block.timestamp + SWAP_DEADLINE_BUFFER,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            });

            uint256 amountOut = AERODROME_CL_ROUTER.exactInputSingle(swapParams);

            require(amountOut >= minAmountOut, "Received less than min amount");

            emit TokensSwapped(token, amountIn, amountOut);

            _swapMamoToCbBtc(amountOut);
        }
    }

    /**
     * @notice Swaps MAMO tokens to cbBTC
     * @param amountIn Amount of MAMO tokens to swap
     * @dev Uses Aerodrome CL router with slippage protection
     */
    function _swapMamoToCbBtc(uint256 amountIn) internal {
        MAMO_TOKEN.forceApprove(address(AERODROME_CL_ROUTER), amountIn);

        IQuoter.QuoteExactInputSingleParams memory params = IQuoter.QuoteExactInputSingleParams({
            tokenIn: address(MAMO_TOKEN),
            tokenOut: address(CBBTC_TOKEN),
            amountIn: amountIn,
            tickSpacing: MAMO_CBBTC_TICK_SPACING,
            sqrtPriceLimitX96: 0
        });

        (uint256 quotedAmountOut,,,) = AERODROME_QUOTER.quoteExactInputSingle(params);
        require(quotedAmountOut > 0, "Invalid quote");

        uint256 minAmountOut = (quotedAmountOut * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
        require(minAmountOut > 0, "Slippage too high");

        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(MAMO_TOKEN),
            tokenOut: address(CBBTC_TOKEN),
            tickSpacing: MAMO_CBBTC_TICK_SPACING,
            recipient: address(this),
            deadline: block.timestamp + SWAP_DEADLINE_BUFFER,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = AERODROME_CL_ROUTER.exactInputSingle(swapParams);

        require(amountOut >= minAmountOut, "Received less than min amount");
    }
}
