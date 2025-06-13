// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Market} from "../src/Market.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployUUPSProxy is Script {
  address public constant ADMIN = 0xE7Bc1Ed115b368B946d97e45eE79f47a14eBF179;

  // address usdt0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
  address usdt0 = 0x12039B52D9F52e8F00784fe6FB49C0A7bEDb702F;
  address forwarder = 0x3fB78f769C33a9689aC28c77074BE74CB3ec2870;
  address whitelistSigner = 0xf059b24cE0C34D44fb271dDC795a7C0E71576fd2;

  function run() external {
    vm.createSelectFork("base");
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

    IERC20(usdt0).approve(address(market), 100 * 1e6);
    market.depositCollateral(100 * 1e6);

    vm.stopBroadcast();

    console.log("\n=== Deployment Summary ===");
    console.log("Implementation:", address(implementation));
    console.log("Proxy:", address(proxy));
    console.log("Market (proxy interface):", address(market));
  }
}
