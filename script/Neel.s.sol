// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Market} from "../src/Market.sol";

contract Neel is Script {
  Market mkt = Market(0xEaCCc2025Ee34Be0b6F1F8c8B18f074a1568335C);

  address neel = 0x2516115b336E3a5A0790D8B6EfdF5bD8D7d263Dd;

  function run() external {
    vm.createSelectFork("hyperevm", 6763810);
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

    (
      bool active,
      bool liquidationQueued,
      uint64 balance,
      uint64 liquidationFeeOwed,
      uint64 scratchPnL,
      uint48 _gap,
      uint32 longCalls,
      uint32 shortCalls,
      uint32 longPuts,
      uint32 shortPuts,
      uint32 pendingLongCalls,
      uint32 pendingShortCalls,
      uint32 pendingLongPuts,
      uint32 pendingShortPuts
    ) = mkt.userAccounts(neel);
    console.log("active", active);
    console.log("liquidationQueued", liquidationQueued);
    console.log("balance", balance);
    console.log("liquidationFeeOwed", liquidationFeeOwed);
    console.log("scratchPnL", scratchPnL);

    vm.stopBroadcast();
  }
}
