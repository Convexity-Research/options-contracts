// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ERC2771Forwarder} from "../src/ERC2771Forwarder.sol";

contract TrustedForwarderScript is Script {
  function run() external {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

    address forwarder = address(new ERC2771Forwarder("OptFun Forwarder"));
    console.log("Forwarder deployed at", forwarder);

    vm.stopBroadcast();
  }
}
