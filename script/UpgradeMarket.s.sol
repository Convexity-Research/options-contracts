// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Market} from "../src/Market.sol";
import {MarketExtension} from "../src/MarketExtension.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract DeployUUPSProxy is Script {
  address marketProxy1 = 0xEaCCc2025Ee34Be0b6F1F8c8B18f074a1568335C;
  address marketProxy2 = 0xd7Fef464914551466d2c3DcD239F1670f2b77cb2;

  function run() external {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("MARKET_OWNER"));

    address upgrader = vm.addr(vm.envUint("MARKET_OWNER"));
    console.log("Deploying with account:", upgrader);
    console.log("Account balance:", upgrader.balance);

    // 1. Deploy Market and MarketExtension impl
    Market newMarket = new Market();
    MarketExtension newMarketExtension = new MarketExtension();

    console.log("Market impl deployed at:", address(newMarket));
    console.log("MarketExtension impl deployed at:", address(newMarketExtension));

    // 3. Upgrade
    UUPSUpgradeable(address(marketProxy1)).upgradeToAndCall(address(newMarket), "");
    UUPSUpgradeable(address(marketProxy2)).upgradeToAndCall(address(newMarket), "");
    console.log("Market upgraded");

    // 4. Set market extension
    Market(address(marketProxy1)).setExtension(address(newMarketExtension));
    Market(address(marketProxy2)).setExtension(address(newMarketExtension));
    console.log("Market extension set");

    vm.stopBroadcast();
  }
}
