// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {OracleTester} from "../src/OracleTester.sol";
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

contract OracleTesterScript is Script {
  function run() public {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
    OracleTester oracleTester = new OracleTester();

    console.log("BTC Price:", oracleTester.getBtcPrice());

    // oracleTester.setBtcPrice();

    console.log("BTC Price:", oracleTester.getBtcPrice());
  }
}
