// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ERC2771Forwarder} from "../src/ERC2771Forwarder.sol";
import {Market} from "../src/Market.sol";

contract TrustedForwarderScript is Script {
  function run() external {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

    address forwarder = address(new ERC2771Forwarder("OptFun Forwarder"));
    console.log("Forwarder deployed at", forwarder);

    // ERC2771Forwarder forwarder = ERC2771Forwarder(0xA42CEe49110ed7520291684992e31789c404EC3F);
    // Market market = Market(0xE57425afC7662E8D151F5249A8E621e167BBE6aB);

    // market.setTrustedForwarder(address(forwarder));

    vm.stopBroadcast();
  }
}
