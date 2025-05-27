// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Market} from "../src/Market.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MarketScript is Script {
  Market public market;

  address public constant ORACLE_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
  address public constant COLLATERAL_TOKEN = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

  function setUp() public {}

  function run() public {
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
    
    // Deploy implementation contract
    Market implementation = new Market();
    
    // Prepare initialization data
    bytes memory initData = abi.encodeWithSelector(
      Market.initialize.selector,
      "BTC",
      ORACLE_FEED,
      COLLATERAL_TOKEN
    );
    
    // Deploy proxy contract
    ERC1967Proxy proxy = new ERC1967Proxy(
      address(implementation),
      initData
    );
    
    // Cast proxy to Market interface
    market = Market(address(proxy));
    
    vm.stopBroadcast();
  }
}
