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
  Deployer contractDeployer = Deployer(0x93DE98a29020d46CF60d7Cf1c5a5Cd1d01F351bC);

  bytes32 salt = 0x93814d313083c0991a51c8a7d1d25b64bf50420350872e2119df79e1e1e0ae92;
  // address will be 0xB7C609cFfa0e47DB2467ea03fF3e598bF59361A5

  function run() external {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("OPT_FUN_DEPLOYER"));
    address optFunDeployer = vm.addr(vm.envUint("OPT_FUN_DEPLOYER"));

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
