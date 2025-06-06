// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MarketNonUpgradeable} from "../src/MarketNonUpgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Script, console} from "forge-std/Script.sol";

contract DeployNonUpgradeableMarket is Script {
  function run() public {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

    new MarketNonUpgradeable(
      "Test Market",
      0xE7Bc1Ed115b368B946d97e45eE79f47a14eBF179,
      0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb,
      0x99f052B76c837853f5F649edCAb028fF1521d1BA,
      0xf059b24cE0C34D44fb271dDC795a7C0E71576fd2
    );
  }
}
