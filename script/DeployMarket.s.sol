// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Market} from "../src/Market.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract DeployUUPSProxy is Script {
  address public constant ADMIN = 0xE7Bc1Ed115b368B946d97e45eE79f47a14eBF179;

  // address usdt0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
  address usdt0 = 0xAA480C5F5EB436D0645189Ca20E5AdE13aecAf27;
  address forwarder = 0x99f052B76c837853f5F649edCAb028fF1521d1BA;
  address whitelistSigner = 0xf059b24cE0C34D44fb271dDC795a7C0E71576fd2;

  function run() external {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
    address deployer = ADMIN;

    console.log("Deploying with account:", deployer);
    console.log("Account balance:", deployer.balance);

    // 1. Deploy the implementation contract
    Market implementation = new Market();
    console.log("Implementation deployed at:", address(implementation));

    // 2. Init data
    bytes memory init = abi.encodeWithSelector(Market.initialize.selector, "BTC Market", ADMIN, usdt0, forwarder);

    // 2. Deploy the proxy contract
    ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), init);
    console.log("Proxy deployed at:", address(proxy));

    // 5. Verify the proxy is working by calling functions through it
    Market market = Market(address(proxy));

    console.log("Market name:", market.name());

    // Try upgrade
    // MarketV2 implementation2 = new MarketV2();
    // UUPSUpgradeable(address(proxy)).upgradeToAndCall(address(implementation2), "");
    // console.log("Proxy upgraded");
    // console.log("Market version:", MarketV2(address(proxy)).version());

    vm.stopBroadcast();

    console.log("\n=== Deployment Summary ===");
    console.log("Implementation:", address(implementation));
    console.log("Proxy:", address(proxy));
    console.log("Market (proxy interface):", address(market));
  }
}
