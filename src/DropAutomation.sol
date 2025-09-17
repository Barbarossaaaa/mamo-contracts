// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IQuoter} from "@interfaces/IQuoter.sol";
import {ISwapRouter} from "@interfaces/ISwapRouter.sol";

interface IRewardsDistributorSafeModule {
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
    ISwapRouter private constant AERODROME_CL_ROUTER = ISwapRouter(0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5);

    /// @dev Aerodrome quoter used to fetch swap estimates for slippage protection
    IQuoter private constant AERODROME_QUOTER = IQuoter(0x254cF9E1E6e233aa1AC962CB9B05b2cfeAaE15b0);

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

    event DropCreated(uint256 mamoAmount, uint256 cbBtcAmount);
    event DedicatedMsgSenderUpdated(address indexed oldSender, address indexed newSender);
    event SwapTokenAdded(address indexed token, int24 tickSpacing);
    event SwapTokenRemoved(address indexed token);
    event SwapRouteUpdated(address indexed token, int24 tickSpacing);
    event TokensSwapped(address indexed token, uint256 amountIn, uint256 amountOut);
    event MaxSlippageUpdated(uint256 oldValueBps, uint256 newValueBps);

    error NotDedicatedSender();
    error InvalidSlippage();

    modifier onlyDedicatedMsgSender() {
        if (msg.sender != dedicatedMsgSender) {
            revert NotDedicatedSender();
        }
        _;
    }

    constructor(
        address owner_,
        address dedicatedMsgSender_,
        address mamoToken_,
        address cbBtcToken_,
        address fMamoSafe_,
        address safeRewardsDistributorModule_
    ) Ownable(owner_) {
        require(owner_ != address(0), "Invalid owner");
        require(dedicatedMsgSender_ != address(0), "Invalid dedicated sender");
        require(mamoToken_ != address(0), "Invalid MAMO token");
        require(cbBtcToken_ != address(0), "Invalid cbBTC token");
        require(fMamoSafe_ != address(0), "Invalid F-MAMO safe");
        require(safeRewardsDistributorModule_ != address(0), "Invalid rewards module");

        dedicatedMsgSender = dedicatedMsgSender_;
        MAMO_TOKEN = IERC20(mamoToken_);
        CBBTC_TOKEN = IERC20(cbBtcToken_);
        F_MAMO_SAFE = fMamoSafe_;
        SAFE_REWARDS_DISTRIBUTOR_MODULE = IRewardsDistributorSafeModule(safeRewardsDistributorModule_);
        maxSlippageBps = DEFAULT_SLIPPAGE_BPS;
    }

    /**
     * @notice Returns the list of tokens configured for MAMO swaps
     */
    function getSwapTokens() external view returns (address[] memory) {
        return swapTokens;
    }

    /**
     * @notice Main automation entry point
     * @dev Executes earn cycle, swaps configured tokens to MAMO, and forwards rewards to the Safe
     */
    function createDrop() external onlyDedicatedMsgSender {
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

    function addSwapToken(address token, int24 tickSpacing) external onlyOwner {
        require(token != address(0), "Invalid token");
        require(token != address(MAMO_TOKEN), "Token already MAMO");
        require(token != address(CBBTC_TOKEN), "cbBTC excluded");
        require(!isSwapToken[token], "Token already added");
        require(tickSpacing > 0, "Invalid tick spacing");

        swapTokens.push(token);
        isSwapToken[token] = true;
        swapTickSpacing[token] = tickSpacing;

        emit SwapTokenAdded(token, tickSpacing);
    }

    function setSwapTickSpacing(address token, int24 tickSpacing) external onlyOwner {
        require(isSwapToken[token], "Token not configured");
        require(tickSpacing > 0, "Invalid tick spacing");
        swapTickSpacing[token] = tickSpacing;
        emit SwapRouteUpdated(token, tickSpacing);
    }

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

    function setMaxSlippageBps(uint256 newSlippageBps) external onlyOwner {
        if (newSlippageBps == 0 || newSlippageBps > MAX_SLIPPAGE_CAP_BPS) {
            revert InvalidSlippage();
        }

        emit MaxSlippageUpdated(maxSlippageBps, newSlippageBps);
        maxSlippageBps = newSlippageBps;
    }

    /**
     * @notice Recovers arbitrary ERC20 tokens held by the contract
     * @param token Address of the token to recover
     * @param to Recipient of the recovered tokens
     * @param amount Amount of tokens to recover
     */
    function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(0), "Invalid token");
        require(to != address(0), "Invalid recipient");
        IERC20(token).safeTransfer(to, amount);
    }

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

            if (amountOut > 0) {
                _swapMamoToCbBtc(amountOut);
            }
        }
    }

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
