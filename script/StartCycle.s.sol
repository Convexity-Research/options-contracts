// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Market} from "../src/Market.sol";

contract StartCycleScript is Script {
  function run() public {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

    Market market = Market(0x32cce11f39f46b0a60c7D7656c1Dbd8620fC0Fd2);
    market.startCycle(block.timestamp + 1 days);

    vm.stopBroadcast();
  }
}
