// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Market} from "../src/Market.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployUUPSProxy is Script {
  address usdt0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
  address forwarder = 0x9508120e06403E779088412A13bBa578edffD766;
  address feeRecipient = 0x17f8dec583Ab9af5De05FBBb4d4C2bfE767A0AC3;

  function run() external {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("MARKET_OWNER"));
    address deployer = 0xdf5dc9d934a87E52aAdCE0c4F6258b0DCDbBF4c2;

    console.log("Deploying with account:", deployer);
    console.log("Account balance:", deployer.balance);

    // 1. Deploy the implementation contract
    Market implementation = new Market();
    console.log("Implementation deployed at:", address(implementation));

    // 2. Init data
    bytes memory init = abi.encodeWithSelector(Market.initialize.selector, "BTC Market", feeRecipient, usdt0, forwarder);

    // 2. Deploy the proxy contract
    ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), init);
    console.log("Proxy deployed at:", address(proxy));

    // 5. Verify the proxy is working by calling functions through it
    Market market = Market(address(proxy));

    console.log("Market name:", market.name());

    vm.stopBroadcast();

    console.log("\n=== Deployment Summary ===");
    console.log("Implementation:", address(implementation));
    console.log("Proxy:", address(proxy));
    console.log("Market (proxy interface):", address(market));
  }
}
