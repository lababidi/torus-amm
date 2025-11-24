// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Torus} from "../src/Torus.sol";

contract TestTokenA is ERC20 {
    constructor() ERC20("Test Token A", "TTA") {
        _mint(msg.sender, 1_000_000e18);
    }
}

contract TestTokenB is ERC20 {
    constructor() ERC20("Test Token B", "TTB") {
        _mint(msg.sender, 1_000_000e18);
    }
}

contract TestToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000e18);
    }
}

contract TorusTest is Test {
    Torus public torus;
    TestTokenA public tokenA;
    TestTokenB public tokenB;

    function setUp() public {
        tokenA = new TestTokenA();
        tokenB = new TestTokenB();
        torus = new Torus(address(tokenA), address(tokenB));
        tokenA.approve(address(torus), type(uint256).max);
        tokenB.approve(address(torus), type(uint256).max);
        torus.initLiquidity(100e18);
        // torus.modLiquidity(address(tokenA), int256(10_000));
        // torus.addLiquidity(address(tokenB), uint256(100_000));
    }

    function testPrice() public view {
        assertEq(torus.getPrice(address(tokenA), address(tokenB)), 1e18);
    }

    function testPrice2() public {
        TestToken tokenC = new TestToken("Test Token C", "TTC");
        tokenC.approve(address(torus), type(uint256).max);
        torus.addToken(address(tokenC));
        torus.modLiquidity(address(tokenC), 80e18);
        torus.modLiquidity(address(tokenA), 10e18);

        console.log("a:", torus.a(0));
        console.log("a:", torus.a(1));
        console.log("a:", torus.a(2));
        assertApproxEqAbs(torus.getPrice(address(tokenA), address(tokenB)), 1e18, 1e10);
        assertApproxEqAbs(torus.getPrice(address(tokenA), address(tokenC)), 1e18, 1e10);
        assertApproxEqAbs(torus.getPrice(address(tokenB), address(tokenC)), 1e18, 1e10);
    }

    // function testAddLiquidity() public {
    //     torus.modLiquidity(address(tokenA), 100e18);
    //     console.log("a:", torus.a(0));
    //     console.log("a:", torus.a(1));
    // }

    function testAddTokenLiq() public {
        TestToken tokenC = new TestToken("Test Token C", "TTC");
        tokenC.approve(address(torus), type(uint256).max);
        torus.addToken(address(tokenC));
        torus.modLiquidity(address(tokenA), 100e18);
        torus.modLiquidity(address(tokenC), 100e18);
        console.log("a:", torus.a(0));
        console.log("a:", torus.a(1));
        console.log("a:", torus.a(2));
    }

    // function testFuzz_SetNumber(uint256 x) public {
    //     counter.setNumber(x);
    //     assertEq(counter.number(), x);
    // }
}
