// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {MockMarketNonUpgradeable} from "../test/mocks/MockMarketNonUpgradeable.sol";

contract ReadMarket is Script {
  MockMarketNonUpgradeable public market;

  function setUp() public {
    market = MockMarketNonUpgradeable(0xd3FEb55DD641843A3624692274BD7fEBB6E4C7D5);
  }

  function run() public {
    vm.createSelectFork("hyperevm");
  }
}
