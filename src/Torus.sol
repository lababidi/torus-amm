// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract Torus {
    using SafeERC20 for IERC20;
    uint24 public n;
    uint256 minLiq = 1e6;
    uint256 fee;
    address[] public tokens;
    uint16[] public order;
    mapping(uint16 => uint16) public pos; // position of token in order array
    mapping(address => uint256) public liquidity;
    mapping(address => uint256) public minLiquidity;
    mapping(address => uint16) public decimals;
    mapping(address => uint256) public liquidityNorm;
    mapping(address => uint256) public tokenPos; // position of token in tokens array
    mapping(address => uint256) public reserves;
    mapping(address => uint256) public a;
    mapping(address => uint256) public w;
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

        address token1 = amountA > amountB ? tokenA : tokenB;
        address token2 = amountA > amountB ? tokenB : tokenA;
        uint256 amt1 = amountA > amountB ? amountA : amountB;
        uint256 amt2 = amountA > amountB ? amountB : amountA;
        addToken(tokenA);
        addToken(tokenB);

    // todo fix this shit NOW
    // need to break this into individual token additions with a respective eta
        uint256 r = div(amt1, amt2);
        uint256 eta1 = 2e18-div(2e18,r+1e18);
        uint256 eta2 = div(2e18,r+1e18);
        a[token1] = 1e18 + sqrt(1e18 - 4 *(1e18 + eta1) )/2;
        a[token2] = 1e18 + sqrt(1e18 - 4 *(1e18 + eta2) )/2;
        reserves[token1] = amt1;
        reserves[token2] = amt2;
        liquidity[token1] = amt1;
        liquidity[token2] = amt2;

    }
    function _bubbleUp(uint16 idx) internal {
        // Move element at idx toward the front while it outranks its predecessor
        while (idx > 0) {
            uint16 aId = order[idx];
            uint16 bId = order[idx - 1];

            if (liquidity[tokens[aId]] <= liquidity[tokens[bId]]) break;

            // swap a <-> b
            order[idx]     = bId;
            order[idx - 1] = aId;
            pos[aId]       = idx - 1;
            pos[bId]       = idx;

            unchecked { --idx; }
        }
    }

    function _bubbleDown(uint16 idx) internal {
        while (idx + 1 < order.length) {
            uint16 aId = order[idx];
            uint16 cId = order[idx + 1];

            if (liquidity[tokens[aId]] >= liquidity[tokens[cId]]) break;

            // swap a <-> c
            order[idx]     = cId;
            order[idx + 1] = aId;
            pos[aId]       = idx + 1;
            pos[cId]       = idx;

            unchecked { ++idx; }
        }
    }
    

    function setMinLiq(uint256 minLiq_) public onlyOwner {
        minLiq = minLiq_;
    }

    function setMinLiquidity(address token) public onlyOwner {
        minLiquidity[token] = minLiq;
    }

    function addToken(address token) public {
        require(token != address(0), "Invalid token address");
        supportedTokens[token] = true;
        decimals[token] = IERC20Metadata(token).decimals();
    }

    function largestLiquidity() public view returns (address token) {
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
    function getPrice2(address tokenA, address tokenB) public view validToken(tokenA) validToken(tokenB) returns (uint256) {
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
                a2 += mul(sq(liquidity[tokens[j]]), p);
            }
            a[tokens[i]] = sqrt(a2);
        }

    }

    function addLiquidity(address token, uint128 amount) public validToken(token) {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        _changeLiquidity(token, amount, true);
    }

    // This will be a permit2 version later
    function addLiquidity(address token, uint256 amount) public validToken(token) {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        _changeLiquidity(token, amount, true);
    }

    function _changeLiquidity(address token, uint256 amount, bool add) public validToken(token) {
        
        require(add || liquidity[token] >= amount, "Insufficient liquidity");

        uint256 L = add? liquidity[token] + amount : liquidity[token] - amount;
        uint256 res = add? reserves[token] + amount : reserves[token] - amount;
        uint256 r = div(L, res);
        uint256 a_ = mul(r, 1 + sqrt(1e18 - mul(4 * w[token], r)))/2; //use old w
        w[token] = mul(1e18 - mul(a_, div(res, L)), div(a_, L));
        a[token] = a_;
        liquidity[token] = L;
        reserves[token] = res;
        minSurpassed[token] = L > minLiquidity[token];
    }

    function removeLiquidity(address token, uint256 amount) public validToken(token) {
        require(liquidity[token] >= amount, "Insufficient liquidity");
        IERC20(token).transferFrom(address(this), msg.sender, amount);
        _changeLiquidity(token, amount, false);
    }


    function swap(address fromToken, address toToken, uint256 amountIn) public validToken(fromToken) validToken(toToken) {
        swap(fromToken, toToken, amountIn, msg.sender);
    }


    function swap(address fromToken, address toToken, uint256 amountIn, address to) public validToken(fromToken) validToken(toToken) {
        require(liquidity[fromToken] >= amountIn, "Insufficient liquidity for swap");

        uint256 amountOut = getAmountOut(fromToken, toToken, amountIn);
        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(toToken).safeTransfer(to, amountOut);
        require(reserves[toToken] >= amountOut, "Insufficient liquidity for output token");

        reserves[fromToken] += amountIn;
        reserves[toToken] -= amountOut;
    }

    function swapOut(address fromToken, address toToken, uint256 amountOut) public validToken(fromToken) validToken(toToken) {
        uint256 amountIn = getAmountIn(toToken, fromToken, amountOut);
        swap(fromToken, toToken, amountIn);
    }

    function getAmountIn(address tokenOut, address tokenIn, uint256 amountOut) public view validToken(tokenIn) validToken(tokenOut) returns (uint256 amountIn) {
        // calculate amountIn based on amountOut
    }

    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn) public view validToken(tokenIn) validToken(tokenOut) returns (uint256 amountOut) {
        uint ao = a[tokenOut];
        uint z = reserves[tokenOut];
        uint ai = a[tokenIn];
        uint y = reserves[tokenIn];
        // i believe this needs to be recalculated with alpha instead of a
        uint256 s_ = 1e18 + sq(div(ao, ai)) * (2*mul(div(amountIn, ao-z), div(ai-y, ao-z) - sq(div(amountIn, ao-z))));
        amountOut = mul(ao-z, 1 - sqrt(s_));

    }

    function getPrice(address tokenIn, address tokenOut) public view validToken(tokenIn) validToken(tokenOut) returns (uint256) {
        return div(w[tokenIn], w[tokenOut]);
    }


    function sq(uint256 x) internal pure returns (uint256) {return mul(x, x);}
    function mul(uint256 x, uint256 y) internal pure returns (uint256) {return x * y / 1e18;}
    function div(uint256 x, uint256 y) internal pure returns (uint256) {return x * 1e18 / y;}
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
}