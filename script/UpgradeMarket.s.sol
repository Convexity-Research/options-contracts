// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Market} from "../src/Market.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract UpgradeMarketScript is Script {
  Market public market;

  address public constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

  address feeRecipient = 0xE7Bc1Ed115b368B946d97e45eE79f47a14eBF179; // Luk lol
  address marketAddress = 0x32cce11f39f46b0a60c7D7656c1Dbd8620fC0Fd2;

  function run() public {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

    // Deploy implementation contract
    Market implementation = new Market();

    // Deploy proxy contract
    UUPSUpgradeable(marketAddress).upgradeToAndCall(address(implementation), "");

    console.log("Market upgraded to implementation", address(implementation));

    vm.stopBroadcast();
  }
}
