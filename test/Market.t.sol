// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Market} from "../src/Market.sol";
import {OptionType, Side} from "../src/interfaces/IMarket.sol";
import {Token} from "./mocks/Token.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MarketTest is Test {
  Market public market;

  address public constant ORACLE_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

  Token public collateralToken;

  address user1 = makeAddr("user1");
  address feeRecipient = makeAddr("feeRecipient");

  function setUp() public {
    // Deploy implementation contract
    Market implementation = new Market();

    collateralToken = new Token("USDT", "USDT");

    // Prepare initialization data
    bytes memory initData =
      abi.encodeWithSelector(Market.initialize.selector, "BTC", feeRecipient, ORACLE_FEED, address(collateralToken));

    // Deploy proxy contract
    ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

    // Cast proxy to Market interface
    market = Market(address(proxy));

    market.startCycle(block.timestamp);
  }

  function testDepositCollateral() public {
    // Setup
    uint256 amount = 10 ether;

    deal(address(collateralToken), user1, amount);
    vm.startPrank(user1);
    collateralToken.approve(address(market), amount);

    // Deposit
    market.depositCollateral(amount);
    vm.stopPrank();

    // Verify
    assertEq(collateralToken.balanceOf(user1), 0);
    assertEq(collateralToken.balanceOf(address(market)), amount);
    assertEq(market.balances(user1), amount);
  }
}
