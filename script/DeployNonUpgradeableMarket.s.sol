// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";

import {MarketNonUpgradeable} from "../src/MarketNonUpgradeable.sol";
import {Token} from "../test/mocks/Token.sol";

contract DeployNonUpgradeableMarket is Script {
  function run() public {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

    Token token = new Token("Test USDT0", "USDT0");

    new MarketNonUpgradeable(
      "Test Market",
      0xE7Bc1Ed115b368B946d97e45eE79f47a14eBF179,
      address(token),
      0x99f052B76c837853f5F649edCAb028fF1521d1BA,
      0xf059b24cE0C34D44fb271dDC795a7C0E71576fd2
    );
  }
}
