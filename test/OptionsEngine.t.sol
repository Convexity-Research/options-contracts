// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {OptionsEngine} from "../src/OptionsEngine.sol";

contract OptionsEngineTest is Test {
  OptionsEngine public optionsEngine;

  address public constant ORACLE_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
  address public constant COLLATERAL_TOKEN = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

  function setUp() public {
    optionsEngine = new OptionsEngine(
      "BTC",
      ORACLE_FEED,
      COLLATERAL_TOKEN
    );
    optionsEngine.startMarket(block.timestamp);
  }
}
