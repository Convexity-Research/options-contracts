// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {MarketNew} from "../src/MarketNew.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
  TransparentUpgradeableProxy,
  ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract MarketNewTest is Test {
  MarketNew public implementation;
  ProxyAdmin public proxyAdmin;
  TransparentUpgradeableProxy public proxy;
  MarketNew public market;

  address public owner = makeAddr("owner");
  address public user1 = makeAddr("user1");
  address public user2 = makeAddr("user2");

  string constant MARKET_NAME = "BTC Market";

  event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

  function setUp() public {
    // Implementation
    implementation = new MarketNew();

    // ProxyAdmin with owner as `owner`
    vm.prank(owner);
    proxyAdmin = new ProxyAdmin(owner);

    // Init data
    bytes memory initData = abi.encodeWithSelector(MarketNew.initialize.selector, MARKET_NAME, owner);

    // Proxy
    proxy = new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);

    // Interface to interact with proxy
    market = MarketNew(address(proxy));
  }
}
