// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Market} from "../src/Market.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MarketScript is Script {
  Market public market;

  address public constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

  address feeRecipient = 0xE7Bc1Ed115b368B946d97e45eE79f47a14eBF179; // Luk lol

  function run() public {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

    // Deploy implementation contract
    Market implementation = new Market();

    // Prepare initialization data
    bytes memory initData = abi.encodeWithSelector(Market.initialize.selector, "BTC", feeRecipient, USDT0);

    // Deploy proxy contract
    ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

    console.log("Market deployed to", address(proxy));

    vm.stopBroadcast();
  }
}
