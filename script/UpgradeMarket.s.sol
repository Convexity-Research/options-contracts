// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Market} from "../src/Market.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract DeployUUPSProxy is Script {
  address public constant ADMIN = 0xE7Bc1Ed115b368B946d97e45eE79f47a14eBF179;

  address marketProxy = 0xE57425afC7662E8D151F5249A8E621e167BBE6aB;

  function run() external {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
    address deployer = ADMIN;

    console.log("Deploying with account:", deployer);
    console.log("Account balance:", deployer.balance);

    // 1. Deploy the implementation contract
    Market newImplementation = new Market();
    console.log("Implementation deployed at:", address(newImplementation));

    // 2. Upgrade
    UUPSUpgradeable(address(marketProxy)).upgradeToAndCall(address(newImplementation), "");
    console.log("Proxy upgraded");

    Market(marketProxy).transferOwnership(0xdf5dc9d934a87E52aAdCE0c4F6258b0DCDbBF4c2);

    vm.stopBroadcast();
  }
}
// 0x5fA815049DCaf3e7e79C27F0FaE3ecCcEEa07F46