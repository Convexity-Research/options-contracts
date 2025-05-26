// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {OptionsEngine} from "../src/OptionsEngine.sol";

contract OptionsMarketScript is Script {
  OptionsEngine public optionsEngine;

  address public constant ORACLE_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
  address public constant COLLATERAL_TOKEN = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

  function setUp() public {}

  function run() public {
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
    optionsEngine = new OptionsEngine(
      "BTC",
      ORACLE_FEED,
      COLLATERAL_TOKEN
    );
    vm.stopBroadcast();
  }
}
