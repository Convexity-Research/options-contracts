// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Market} from "../src/Market.sol";

contract UpgradeProdMarket is Script {
  function run() external {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("FRESH_RESCUER"));
    address wallet = vm.addr(vm.envUint("FRESH_RESCUER"));
    console.log("Deploying with account:", wallet);
    console.log("Account balance:", wallet.balance);

    // 1. Deploy the implementation contract
    Market newImplementation = new Market();
    console.log("Implementation deployed at:", address(newImplementation));

    vm.stopBroadcast();
  }
}
