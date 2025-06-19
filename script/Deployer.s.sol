// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Deployer} from "../src/Deployer.sol";

contract DeployerScript is Script {
  function run() external {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("OPT_FUN_DEPLOYER"));
    address optFunDeployer = vm.addr(vm.envUint("OPT_FUN_DEPLOYER"));
    console.log("Deploying with account:", optFunDeployer);
    console.log("Account balance:", optFunDeployer.balance);

    Deployer contractDeployer = new Deployer();
    console.log("Deployer deployed at:", address(contractDeployer));

  }
}
