// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {Market} from "../src/Market.sol";

contract DeployTransparentProxy is Script {
  address public constant ADMIN = 0xE7Bc1Ed115b368B946d97e45eE79f47a14eBF179;

  function run() external {
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(deployerPrivateKey);

    vm.startBroadcast(deployerPrivateKey);

    console.log("Deploying with account:", deployer);
    console.log("Account balance:", deployer.balance);

    // 1. Deploy the implementation contract
    Market implementation = new Market();
    console.log("Implementation deployed at:", address(implementation));

    // 2. Deploy ProxyAdmin (this will be the admin of the proxy)
    ProxyAdmin proxyAdmin = new ProxyAdmin(deployer);
    console.log("ProxyAdmin deployed at:", address(proxyAdmin));

    // 3. Prepare initialization data
    bytes memory initData = abi.encodeWithSelector(Market.initialize.selector, "BTC Market", ADMIN);

    // 4. Deploy the Transparent Upgradeable Proxy
    TransparentUpgradeableProxy proxy =
      new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);

    console.log("Proxy deployed at:", address(proxy));

    // 5. Verify the proxy is working by calling functions through it
    Market market = Market(address(proxy));

    console.log("Market name:", market.name());

    vm.stopBroadcast();

    console.log("\n=== Deployment Summary ===");
    console.log("Implementation:", address(implementation));
    console.log("ProxyAdmin:", address(proxyAdmin));
    console.log("Proxy:", address(proxy));
    console.log("Market (proxy interface):", address(market));
  }
}
