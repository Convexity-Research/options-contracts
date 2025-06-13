// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {Token} from "../test/mocks/Token.sol";

contract TokenScript is Script {
  function run() external {
    vm.createSelectFork("base");
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

    Token tok = Token(0x12039B52D9F52e8F00784fe6FB49C0A7bEDb702F);
    tok.mint(0x5dbAb2D4a3aea73CD6c6C2494A062E07a630430f, 1000000 * 1e6);

    vm.stopBroadcast();
  }
}
