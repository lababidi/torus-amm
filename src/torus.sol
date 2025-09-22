// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

contract Torus {
    uint24 public n;
    uint256 minLiquidity = 1e6;
    mapping(address => uint256) public liquidity;
    mapping(address => uint256) public x;
    mapping(address => uint256) public a;
    mapping(address => uint256) public fees;
    mapping(address => uint256) public price;
    mapping(address => bool) public supportedTokens;
    mapping(address => bool) public minSurpassed;

    modifier validateToken(address token) {
        require(token != address(0), "Invalid token address");
        require(supportedTokens[token], "Token not supported");
        _;
    }


    function addLiquidity(address token, uint256 amount) public validateToken(token) {
        liquidity[token] += amount;
        minSurpassed[token] = liquidity[token] > minLiquidity;
        // recalculate a

    }

    function removeLiquidity(address token, uint256 amount) public validateToken(token) {
        require(liquidity[token] >= amount, "Insufficient liquidity");
        liquidity[token] -= amount;
        // recalculate a
        // a[token] = calculateA(token);

    }

    function addToken(address token) public {
        require(token != address(0), "Invalid token address");
        supportedTokens[token] = true;
    }

}
