// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
contract Torus {
    using SafeERC20 for IERC20;
    uint24 public n;
    uint256 minLiquidity = 1e6;
    uint256 fee;
    address[] public tokens;
    mapping(address => uint256) public liquidity;
    mapping(address => uint256) public reserves;
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

        modifier liquidToken(address token) {
        require(token != address(0), "Invalid token address");
        require(supportedTokens[token], "Token not supported");
        require(minSurpassed[token], "Minimum liquidity not surpassed");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    address public owner;

    constructor(uint256 fee_, address tokenA, address tokenB, uint256 amountA, uint256 amountB) {
        fee = fee_;
        owner = msg.sender;
        addToken(tokenA);
        addToken(tokenB);


        for (uint i = 0; i < tokens.length; i++) {
            uint a2 = 0;
            for (uint j = 0; j < tokens.length; j++) {
                // uint256 p = getPrice(tokens[i], tokens[j]);
                a2 += mul(liquidity[tokens[j]], liquidity[tokens[j]]);
            }
            a[tokens[i]] = sqrt(a2);
        }
    }

    function setMinLiquidity(uint256 minLiq) public onlyOwner {
        minLiquidity = minLiq;
    }

    function addFreshLiquidity(address token, uint256 amount) public validToken(token) {
        require(liquidity[token] == 0, "Token already has liquidity");
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        liquidity[token] += amount;
        reserves[token] += amount;
        minSurpassed[token] = liquidity[token] > minLiquidity;



    }

    function largestLiqudity() public view returns (address token) {
        uint256 maxLiq = 0;
        for (uint i = 0; i < tokens.length; i++) {
            if (liquidity[tokens[i]] > maxLiq) {
                maxLiq = liquidity[tokens[i]];
                token = tokens[i];
            }
        }
    }


    // Price between tokenA and tokenB depends on the ratio of [(a-x)/a] /[(b-y)/b]. 
    // This is from the partial derivative of the invariant function.
    function getPrice(address tokenA, address tokenB) public view validToken(tokenA) validToken(tokenB) returns (uint256) {
        return mul(
            div(a[tokenA] - reserves[tokenA], a[tokenB] - reserves[tokenB]), 
            div(a[tokenB], a[tokenA])
            );
    }

    function calculateFresh() internal{
        for (uint i = 0; i < tokens.length; i++) {
            uint a2 = 0;
            for (uint j = 0; j < tokens.length; j++) {
                uint256 p = getPrice(tokens[i], tokens[j]);
                a2 += mul(mul(liquidity[tokens[j]], liquidity[tokens[j]]), p);
            }
            a[tokens[i]] = sqrt(a2);
        }

    }


    function calculateA() internal{
        for (uint i = 0; i < tokens.length; i++) {
            uint a2 = 0;
            for (uint j = 0; j < tokens.length; j++) {
                uint256 p = getPrice(tokens[i], tokens[j]);
                a2 += mul(mul(liquidity[tokens[j]], liquidity[tokens[j]]), p);
            }
            a[tokens[i]] = sqrt(a2);
        }

    }

    function addLiquidity(address token, uint128 amount) public validToken(token) {

        liquidity[token] += amount;
        minSurpassed[token] = liquidity[token] > minLiquidity;
        calculateA();
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        reserves[token] += amount;
        // recalculate a
    }

    function addLiquidity(address token, uint256 amount) public validToken(token) {
        bool freshToken = liquidity[token] == 0;
        liquidity[token] += amount;
        minSurpassed[token] = liquidity[token] > minLiquidity;
        if(!freshToken) calculateA();
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        reserves[token] += amount;
        // recalculate a
    }

    function removeLiquidity(address token, uint256 amount) public validToken(token) {
        require(liquidity[token] >= amount, "Insufficient liquidity");
        liquidity[token] -= amount;

        minSurpassed[token] = liquidity[token] > minLiquidity;
        calculateA();
        IERC20(token).transferFrom(address(this), msg.sender, amount);
        reserves[token] -= amount;
    }

    function addToken(address token) public {
        require(token != address(0), "Invalid token address");
        supportedTokens[token] = true;
    }
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        y = y * 1e18;
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

    function mul(uint256 x, uint256 y) internal pure returns (uint256) {
        return x * y / 1e18;
    }
    function div(uint256 x, uint256 y) internal pure returns (uint256) {
        return x * 1e18 / y;
    }

    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn) public view validToken(tokenIn) validToken(tokenOut) returns (uint256 amountOut) {
        uint c = a[tokenOut];
        uint z = reserves[tokenOut];
        uint b = a[tokenIn];
        uint y = reserves[tokenIn];
        uint256 s_ = 1e18 + sq(div(c, b)) * (2*mul(div(amountIn, c-z), div(b-y, c-z) - sq(div(amountIn, c-z))));
        amountOut = mul(c-z, 1 - sqrt(s_));

    }

    function swap(address fromToken, address toToken, uint256 amountIn) public validToken(fromToken) validToken(toToken) {
        require(liquidity[fromToken] >= amountIn, "Insufficient liquidity for swap");

        uint256 amountOut = getAmountOut(fromToken, toToken, amountIn);
        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(toToken).safeTransfer(msg.sender, amountOut);
        require(liquidity[toToken] >= amountOut, "Insufficient liquidity for output token");

        reserves[fromToken] += amountIn;
        reserves[toToken] -= amountOut;
    }
}
