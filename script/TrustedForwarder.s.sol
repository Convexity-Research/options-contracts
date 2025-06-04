// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

contract TrustedForwarderScript is Script {
  function run() external {
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

    new ERC2771Forwarder("OptFun Forwarder");

    vm.stopBroadcast();
  }
}
