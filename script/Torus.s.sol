// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Torus} from "../src/Torus.sol";

contract CounterScript is Script {
     
    Torus public torus;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        torus = new Torus(address(0), address(0));

        vm.stopBroadcast();
    }
}
