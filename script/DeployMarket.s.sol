// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Market} from "../src/Market.sol";
import {Deployer} from "../src/Deployer.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployUUPSProxy is Script {
  address usdt0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
  address forwarder = 0x9508120e06403E779088412A13bBa578edffD766;
  address feeRecipient = 0x17f8dec583Ab9af5De05FBBb4d4C2bfE767A0AC3;
  Deployer contractDeployer = Deployer(0x9040B84350B16712E042a6f751dCa1C846B341B6);

  bytes32 salt = 0x7718f518a3c20e84d1ac1cc1a610c6665d19ae8c93b0af4c7e56d503bcbc0586;
  // address will be 0xB7C60aaa12Ab90731f3632d32945ED0459baDfE0

  function run() external {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("OPT_FUN_DEPLOYER"));
    address optFunDeployer = 0xc6Be45368F9d89A782001c059E52dCdad95D956d;

    console.log("Deploying with account:", optFunDeployer);
    console.log("Account balance:", optFunDeployer.balance);

    address implementation = address(new Market());
    address proxy = contractDeployer.deployMarket("BTC Market", feeRecipient, usdt0, forwarder, implementation, salt);

    console.log("Market name:", Market(proxy).name());

    vm.stopBroadcast();

    console.log("\n=== Deployment Summary ===");
    console.log("Implementation:", address(implementation));
    console.log("Proxy:", address(proxy));
    console.log("Market name:", Market(proxy).name());
  }
}
