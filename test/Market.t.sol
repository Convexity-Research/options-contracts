// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Market, OBLevel} from "../src/Market.sol";
import {OptionType, Side} from "../src/interfaces/IMarket.sol";
import {BitScan} from "../src/lib/Bitscan.sol";
import {Token} from "./mocks/Token.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MarketTest is Test {
  using BitScan for uint256;

  Market public market;

  address public constant ORACLE_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

  Token public collateralToken; // USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb on hyperEVM. 6 decimals

  address user1 = makeAddr("user1");
  address user2 = makeAddr("user2");
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

  function testPlaceLimitOrder() public {
    uint256 size = 50; // contracts
    uint256 price6 = 1_000_000; // 1.00 USDC in 6-dec

    // fund + deposit (unchanged)
    uint256 quote = 10_000_000; // 10 USDC collateral
    deal(address(collateralToken), user1, quote);
    vm.prank(user1);
    collateralToken.approve(address(market), quote);
    vm.prank(user1);
    market.depositCollateral(quote);

    // place limit
    vm.prank(user1);
    market.placeOrder(OptionType.CALL, Side.BUY, size, price6 + 2);

    uint32 tick = _tick(price6); // 100
    uint32 key = _key(tick, false, true);

    vm.startPrank(user2);
    market.placeOrder(OptionType.CALL, Side.SELL, size, 0);

    // (uint128 vol, uint128 head, uint128 tail) = market.levels(key);

    // _printBook(true, false);

    // vm.startPrank(user1);
    // uint256 nodeId = market.placeOrder(
    //   OptionType.CALL,
    //   Side.BUY,
    //   size,
    //   price6 // 6-dec premium
    // );

    // // assertions
    // uint32 tick = _tick(price6); // 100
    // uint32 key = _key(tick, false, true);

    // (uint128 vol,,) = market.levels(key);

    // console.log("nodeId", nodeId);
    // assertEq(nodeId, 1, "nodeId");
    // assertEq(vol, size, "level vol");

    // // bitmap summary bit
    // (uint8 l1,,) = BitScan.split(tick);

    // uint8 ix = 1; // 0 = CallAsk, 1 = CallBid, 2 = PutAsk, 3 = PutBid
    // assertEq(market.summaries(ix) & BitScan.mask(l1), BitScan.mask(l1));
  }

  function _tick(uint256 price) internal pure returns (uint32) {
    return uint32(price / 1e4); // TICK_SZ = 1e4 in contract
  }

  function _key(uint32 tick, bool isPut, bool isBid) internal pure returns (uint32) {
    return tick | (isPut ? 1 << 31 : 0) | (isBid ? 1 << 30 : 0);
  }

  function _printBook(bool isBid, bool isPut) internal view {
    OBLevel[] memory book = market.dumpBook(isBid, isPut);

    console.log("\n");
    console.log("============================================");
    console.log("              %s %s                ", 
      isPut ? "PUT" : "CALL", 
      isBid ? "BIDS" : "ASKS"
    );
    console.log("============================================");
    
    if (book.length == 0) {
      console.log("            [Empty Book]");
      console.log("============================================\n");
      return;
    }

    console.log("Tick\t\tPrice(6dp)\tVolume");
    console.log("----\t\t----------\t------");
    
    for (uint256 i; i < book.length; ++i) {
      uint256 price6 = uint256(book[i].tick) * 1e4;
      console.log("%d\t\t%d\t\t%d", 
        book[i].tick,
        price6,
        book[i].vol
      );
    }
    console.log("============================================\n");
  }
}
