// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "forge-std/StdUtils.sol";
import "../src/Market.sol";
import "./mocks/MarketTest.sol";
import "../src/lib/Bitscan.sol";
import "./mocks/Token.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MarketSuite is Test {
  using BitScan for uint256;

  uint32 constant ONE_TICK = 1; // == 0.01 USDT
  uint256 constant ONE_COIN = 1_000_000; // 6-dec → 1.00
  uint256 constant LOT = 100; // contracts
  address public constant ORACLE_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

  Token usdt; // USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb on hyperEVM. 6 decimals
  MarketTest mkt;

  address u1 = makeAddr("alice");
  address u2 = makeAddr("bob");
  address feeSink = makeAddr("feeSink");

  function setUp() public {
    vm.createSelectFork("hyperevm");
    usdt = new Token("USDT0", "USDT0"); // 6-dec mock
    mkt = MarketTest(
      address(
        new ERC1967Proxy(
          address(new MarketTest()), abi.encodeWithSelector(Market.initialize.selector, "BTC", feeSink, address(usdt))
        )
      )
    );
    mkt.startCycle(block.timestamp);
  }

  // #######################################################################
  // #                                                                     #
  // #                Collateral and limit orders paths                    #
  // #                                                                     #
  // #######################################################################

  function testDepositWithdraw() public {
    uint256 depositAmount = 10 * ONE_COIN;
    uint256 withdrawAmount = 5 * ONE_COIN;
    _fund(u1, depositAmount);
    vm.prank(u1);
    mkt.withdrawCollateral(withdrawAmount);

    assertEq(mkt.balances(u1), depositAmount - withdrawAmount);
    assertEq(usdt.balanceOf(address(mkt)), depositAmount - withdrawAmount);
  }

  function testInsertCallBidPriceAtLowestBitmap() public {
    _fund(u1, 10 * ONE_COIN);

    uint256 price = 2e6; // 2 USDT0

    vm.prank(u1);
    uint256 id = mkt.placeOrder(OptionType.CALL, Side.BUY, LOT, price);

    uint32 tick = _tick(price); // tick = 2e6 / 1e4 = 200
    uint32 key = _key(tick, false, true); // CALL-BID

    // Test level volume
    (uint128 vol,,) = mkt.levels(key);
    assertEq(vol, LOT, "level vol mismatch");
    assertEq(id, 1, "first maker id");

    // Test summary (L1) bitmap - l1 is 0, so bit 0 should be set. Which means value of 1
    uint8 sid = 1; // CallBid bucket
    assertEq(mkt.summaries(sid), 1, "summary bit not set correctly");

    // Test mid (L2) bitmap - l1 is 0, l2 is 0, so bit 0 should be set in mid[0]
    assertEq(mkt.midCB(0), 1, "mid bit not set correctly");

    // Test detail (L3) bitmap - l1 and l2 are 0, l3 is 200, since tick is 200
    uint16 detKey = 0; // (l1 << 8) | l2 where both are 0
    assertEq(mkt.detCB(detKey), 1 << 200, "detail bit not set correctly");

    _printBook(true, false);
  }

  function testInsertCallBidPriceAtMiddleBitmap() public {
    _fund(u1, 1000 * ONE_COIN);

    uint256 price = 700_000_000; // 700 USDT0
    uint32 expectedTick = 70000; // 700_000_000 / 10000

    vm.prank(u1);
    uint256 id = mkt.placeOrder(OptionType.CALL, Side.BUY, LOT, price);

    uint32 tick = _tick(price);
    assertEq(tick, expectedTick, "tick calculation incorrect");

    uint32 key = _key(tick, false, true); // CALL-BID

    // Test level volume
    (uint128 vol,,) = mkt.levels(key);
    assertEq(vol, LOT, "level vol mismatch");
    assertEq(id, 1, "first maker id");

    // Test summary (L1) bitmap - l1 is 0x01, so bit 1 should be set
    uint8 sid = 1; // CallBid bucket
    assertEq(mkt.summaries(sid), 1 << 1, "summary bit not set correctly");

    // Test mid (L2) bitmap - l1 is 0x01, l2 is 0x11 (17), so bit 17 should be set in mid[1]
    assertEq(mkt.midCB(1), 1 << 17, "mid bit not set correctly");

    // Test detail (L3) bitmap - l1 is 0x01, l2 is 0x11, l3 is 0x70 (112)
    uint16 detKey = (uint16(1) << 8) | 17; // (l1 << 8) | l2
    assertEq(mkt.detCB(detKey), 1 << 112, "detail bit not set correctly");

    _printBook(true, false);
  }

  function testMultipleOrdersAtDifferentPriceLevels() public {
    _fund(u1, 1000 * ONE_COIN);

    uint256[] memory prices = new uint256[](3);
    uint8[] memory l1s = new uint8[](3);
    uint8[] memory l2s = new uint8[](3);
    uint8[] memory l3s = new uint8[](3);

    // We know which bits should be set for each price level. See console.log statements below.
    // 2 USDT0 - lowest level (from first test)
    prices[0] = 2e6;
    l1s[0] = 0;
    l2s[0] = 0;
    l3s[0] = 200;

    // 700 USDT0 - middle level (from second test)
    prices[1] = 700e6;
    l1s[1] = 1;
    l2s[1] = 17;
    l3s[1] = 112;

    // 1000 USDT0 - different level
    prices[2] = 1000e6;
    l1s[2] = 1;
    l2s[2] = 134;
    l3s[2] = 160;

    // Place all orders
    for (uint256 i = 0; i < prices.length; i++) {
      vm.prank(u1);
      mkt.placeOrder(OptionType.CALL, Side.BUY, LOT, prices[i]);
    }

    // Check each order's bits individually
    for (uint256 i = 0; i < prices.length; i++) {
      uint32 tick = _tick(prices[i]);
      // Log the high, mid, low bytes of the tick to double check which bits SHOULD be set
      // (uint8 l1, uint8 l2, uint8 l3) = BitScan.split(tick);
      // console.log("tick in binary:", vm.toString(bytes32(uint256(tick))));
      // console.log("l1 (high byte):", l1, "in binary:", vm.toString(bytes32(uint256(l1))));
      // console.log("l2 (mid byte):", l2, "in binary:", vm.toString(bytes32(uint256(l2))));
      // console.log("l3 (low byte):", l3, "in binary:", vm.toString(bytes32(uint256(l3))));

      assertTrue((mkt.summaries(1) & (1 << l1s[i])) != 0, "summary bit not set");

      // Mid bitmap check - should have its bit set in the correct word
      assertTrue((mkt.midCB(l1s[i]) & (1 << l2s[i])) != 0, "mid bit not set");

      // Detail bitmap check - should have its bit set in the correct word
      uint16 detKey = (uint16(l1s[i]) << 8) | l2s[i];
      assertTrue((mkt.detCB(detKey) & (1 << l3s[i])) != 0, "detail bit not set");

      // Level check - should have correct volume
      uint32 key = _key(tick, false, true);
      (uint128 vol,,) = mkt.levels(key);
      assertEq(vol, LOT, "level vol mismatch");
    }

    // Visual check
    _printBook(true, false);
  }

  // #######################################################################
  // #                                                                     #
  // #                        2. Maker <-> Taker match                     #
  // #                                                                     #
  // #######################################################################

  function testCrossAtSameTick() public {
    // Maker (u1) posts bid
    _fund(u1, 1000 * ONE_COIN);
    vm.prank(u1);
    mkt.placeOrder(OptionType.CALL, Side.BUY, LOT, ONE_COIN);

    uint256 balSinkBefore = mkt.balances(feeSink);

    // Taker (u2) hits bid
    _fund(u2, 1000 * ONE_COIN); // writer needs no upfront USDT premium
    vm.prank(u2);
    mkt.placeOrder(OptionType.CALL, Side.SELL, LOT, ONE_COIN); // Price crossed since same price as maker

    // Queues empty, level deleted
    uint32 key = _key(_tick(ONE_COIN), false, true);
    (uint128 vol,,) = mkt.levels(key);
    assertEq(vol, 0, "level not cleared");

    // Fee accounting
    int256 gross = int256(ONE_COIN) * int256(LOT);
    int256 makerFee = gross * mkt.makerFeeBps() / 10_000;
    int256 takerFee = gross * mkt.takerFeeBps() / 10_000;
    uint256 sinkPlus = uint256(-(makerFee + takerFee));

    assertEq(mkt.balances(feeSink), balSinkBefore + sinkPlus);
  }

  // Market order sweeps 3 price levels and leaves tail in queue
  function testMarketOrderMultiLevelAndQueue() public {
    uint32[3] memory ticks = [_tick(ONE_COIN), _tick(ONE_COIN * 2), _tick(ONE_COIN * 700)];
    uint256 collatPerContract = 107000000000 / 100 / 1000; // Divide by 100 for 0.01BTC size contract price,
      // divide by 1000 for 0.1% margin
    _fund(u1, collatPerContract * LOT * 3);

    // Three makers @ 1,2,700 USD
    for (uint256 i; i < 3; ++i) {
      vm.prank(u1);
      mkt.placeOrder(OptionType.PUT, Side.SELL, LOT, ticks[i] * 1e4); // ask
    }

    // Taker buys 250 contracts market –> eats 2.5 levels
    _fund(u2, 1000000 * ONE_COIN);
    vm.prank(u2);
    mkt.placeOrder(OptionType.PUT, Side.BUY, 250, 0); // market

    // level[0] & level[1] empty, level[2] partial 50 left
    uint32 key0 = _key(ticks[0], true, false);
    (uint128 vol0,,) = mkt.levels(key0);
    assertEq(vol0, 0);
    uint32 key1 = _key(ticks[1], true, false);
    (uint128 vol1,,) = mkt.levels(key1);
    assertEq(vol1, 0);
    uint32 key2 = _key(ticks[2], true, false);
    (uint128 vol2,,) = mkt.levels(key2);
    assertEq(vol2, 50);

    // Queue should not hold any leftover (fully filled)
    (TakerQ[] memory q) = mkt.viewTakerQueue(true, true); // PUT-Bid bucket
    assertEq(q.length, 0, "unexpected tail in takerQ");
  }

  // #######################################################################
  // #                                                                     #
  // #                      Limit -> Queued-taker flow                     #
  // #                                                                     #
  // #######################################################################

  // Post-fill remainder queues, next maker consumes it
  function testQueuedTakerThenMaker() public {
    // Taker market order, book empty, 120 contracts queued
    _fund(u1, 1000 * ONE_COIN);
    vm.prank(u1);
    mkt.placeOrder(OptionType.PUT, Side.BUY, 120, 0); // book is blank

    (TakerQ[] memory qBefore) = mkt.viewTakerQueue(true, true);
    assertEq(qBefore.length, 1); // 1 queued
    assertEq(qBefore[0].size, 120);

    // Maker comes with limit Sell 200 @ $1
    _fund(u2, 1000 * ONE_COIN);
    vm.prank(u2);
    mkt.placeOrder(OptionType.PUT, Side.SELL, 200, ONE_COIN);

    // The first 120 matched immediately, only 80 rest on book
    uint32 key = _key(_tick(ONE_COIN), true, false); // PUT-Ask
    (uint128 vol,,) = mkt.levels(key);
    assertEq(vol, 80, "book remainder wrong");

    // Queue length won't be zero since we don't pop, but pointer should be equal to length
    (TakerQ[] memory qAfter) = mkt.viewTakerQueue(true, false);
    assertEq(mkt.tqHead(1, 0), qAfter.length, "queue head not at the end");
  }

  // #######################################################################
  // #                                                                     #
  // #                    Bitscan and bitmap invariants                    #
  // #                                                                     #
  // #######################################################################

  function testFuzzBitmap(uint128 amount, uint8 priceTick) public {
    vm.assume(amount > 0 && amount < 1e6);
    uint256 price = uint256(priceTick) * 1e4 + 1e4; // >=1 tick

    _fund(u1, 1e24);
    vm.prank(u1);
    mkt.placeOrder(OptionType.CALL, Side.BUY, amount, price);

    uint32 tick = _tick(price);
    (uint8 l1,,) = BitScan.split(tick);
    assertTrue((mkt.summaries(1) & BitScan.mask(l1)) != 0); // bit set
  }

  function testBitscan(uint256 bit) public pure {
    vm.assume(bit < 256);
    assert(BitScan.msb(1) == 0); // bit-0 set
    // Check that msb returns the correct index
    assert(BitScan.msb(1 << bit) == bit);
  }

  // #######################################################################
  // #                                                                     #
  // #                             Helpers                                 #
  // #                                                                     #
  // #######################################################################

  function _fund(address who, uint256 amount) internal {
    deal(address(usdt), who, amount);
    vm.prank(who);
    usdt.approve(address(mkt), type(uint256).max);
    vm.prank(who);
    mkt.depositCollateral(amount);
  }

  function _tick(uint256 p) internal pure returns (uint32) {
    return uint32(p / 1e4);
  }

  function _key(uint32 t, bool put, bool bid) internal pure returns (uint32) {
    return t | (put ? 1 << 31 : 0) | (bid ? 1 << 30 : 0);
  }

  function _printBook(bool isBid, bool isPut) internal view {
    OBLevel[] memory book = mkt.dumpBook(isBid, isPut);

    console.log("\n");
    console.log("============================================");
    console.log("              %s %s                ", isPut ? "PUT" : "CALL", isBid ? "BIDS" : "ASKS");
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
      console.log("%d\t\t%d\t\t%d", book[i].tick, price6, book[i].vol);
    }
    console.log("============================================\n");
  }
}
