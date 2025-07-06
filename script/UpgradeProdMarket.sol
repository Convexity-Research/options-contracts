// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Market} from "../src/Market.sol";
import {MarketExtension} from "../src/MarketExtension.sol";
import {MarketExtensionFix} from "../src/MarketExtensionFix.sol";

contract UpgradeProdMarket is Script {
  function run() external {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("OPT_FUN_DEPLOYER"));
    address wallet = vm.addr(vm.envUint("OPT_FUN_DEPLOYER"));
    console.log("Deploying with account:", wallet);
    console.log("Account balance:", wallet.balance);

    // 1. Deploy the implementation contract
    Market newImplementation = new Market();
    console.log("Implementation deployed at:", address(newImplementation));

    // 2. Deploy MarketExtension impl
    MarketExtension newMarketExtension = new MarketExtension();
    console.log("MarketExtension impl deployed at:", address(newMarketExtension));

    vm.stopBroadcast();
  }
}
