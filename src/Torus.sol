// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
contract Torus {
    using SafeERC20 for IERC20;
    uint24 public n;
    uint256 minLiquidity = 1e6;
    uint256 fee;
    mapping(address => uint256) public liquidity;
    mapping(address => uint256) public x;
    mapping(address => uint256) public a;
    mapping(address => uint256) public fees;
    mapping(address => mapping(address => uint256)) public price;
    mapping(address => bool) public supportedTokens;
    mapping(address => bool) public minSurpassed;

    modifier validToken(address token) {
        require(token != address(0), "Invalid token address");
        require(supportedTokens[token], "Token not supported");
        _;
    }

    constructor(uint256 fee_) {
        fee = fee_;
    }

    function addLiquidity(address token, uint128 amount) public validToken(token) {

        liquidity[token] += amount;
        minSurpassed[token] = liquidity[token] > minLiquidity;
        // recalculate a
    }

    function addLiquidity(address token, uint256 amount) public validToken(token) {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        liquidity[token] += amount;
        minSurpassed[token] = liquidity[token] > minLiquidity;
        // recalculate a
    }

    function removeLiquidity(address token, uint256 amount) public validToken(token) {
        require(liquidity[token] >= amount, "Insufficient liquidity");
        liquidity[token] -= amount;
        // recalculate a
        // a[token] = calculateA(token);
    }

    function addToken(address token) public {
        require(token != address(0), "Invalid token address");
        supportedTokens[token] = true;
    }
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function sq(uint256 x) internal pure returns (uint256) {
        return x * x / 1e18;
    }

    function getTotalSum() public view returns (uint256 sum) {
        for (uint256 i = 0; i < x.length; i++) {
            sum += sq(1e18 - 1e18 * x[i] / a[i]);
        }
    }


    function getSingleSum(address token) public view returns (uint256 sum) {
        uint24 token_ = tokenIndex[token];
        sum = sq(1e18 - 1e18 * x[token_] / a[token_]);
    }

    function getAmountOut(address fromToken, address toToken, uint256 amountIn) public view validToken(fromToken) validToken(toToken) returns (uint256) {
        uint256 totalSum = getTotalSum();

        price = (1e36 - 1e36 * x[fromToken] / a[fromToken])/(1e18 - 1e18 * x[toToken] / a[toToken]);
        uint256 amountOut = (amountIn * price) / 1e18;
        return amountOut;
    }

    function swap(address fromToken, address toToken, uint256 amountIn) public validToken(fromToken) validToken(toToken) {
        require(liquidity[fromToken] >= amountIn, "Insufficient liquidity for swap");

        uint256 price = price[fromToken][toToken];
        price = (1e36 - 1e36 * x[fromToken] / a[fromToken])/(1e18 - 1e18 * x[toToken] / a[toToken]);
        uint256 amountOut = sqrt()
        // calculate fees
        // fees[fromToken] += fee;
        // uint256 amountAfterFee = amountIn - fee;
        // calculate output amount based on x and a
        // uint256 outputAmount = (amountAfterFee * a[toToken]) / (x[fromToken] + amountAfterFee);
        require(liquidity[toToken] >= outputAmount, "Insufficient liquidity for output token");
        // update liquidity
        liquidity[fromToken] += amountAfterFee;
        liquidity[toToken] -= outputAmount;
        // update x values
        x[fromToken] += amountAfterFee;
        x[toToken] -= outputAmount;
        // update prices
        price[fromToken] = (liquidity[toToken] * 1e18) / liquidity[fromToken];
        price[toToken] = (liquidity[fromToken] * 1e18) / liquidity[toToken];
    }
}
