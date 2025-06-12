// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

contract SignSomething is Script {
  function run() external {
    uint256 signerKey = 0x1;

    bytes32 hash = keccak256(abi.encodePacked(0xE7Bc1Ed115b368B946d97e45eE79f47a14eBF179));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, hash);
    bytes memory signature = abi.encodePacked(r, s, v);

    console.logBytes(signature);
  }
}
