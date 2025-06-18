// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "forge-std/StdUtils.sol";
import "./mocks/MarketWithViews.sol";
import {BitScan} from "../src/lib/Bitscan.sol";
import {Token} from "./mocks/Token.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
  TransparentUpgradeableProxy,
  ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract MarketSuite is Test {
  using BitScan for uint256;

  int256 constant MAKER_FEE_BPS = -200;
  int256 constant TAKER_FEE_BPS = 700;
  uint256 constant TICK_SIZE = 1e4;
  uint256 constant CONTRACT_SIZE = 100;

  uint256 constant ONE_COIN = 1_000_000; // 6-dec → 1.00
  uint256 constant LOT = 100; // contracts

  Token usdt; // USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb on hyperEVM. 6 decimals

  MarketWithViews implementation;
  ProxyAdmin proxyAdmin;
  TransparentUpgradeableProxy proxy;
  MarketWithViews mkt;

  address owner = makeAddr("owner");
  address u1 = makeAddr("user1");
  address u2 = makeAddr("user2");
  address feeSink = makeAddr("feeSink");
  address gov = makeAddr("gov");
  address securityCouncil = makeAddr("securityCouncil");
  address signer;
  uint256 signerKey;

  uint256 btcPrice = 100000;

  uint256 cycleId;

  function setUp() public {
    signerKey = 0x17edc1e22b2fa63800979f12e31f4df4e5966edfa8205456f169ea8b2112dd49;
    signer = 0x1FaE1550229fE09ef3e266d8559acdcFC154e72f;
    usdt = new Token("USDT0", "USDT0"); // 6-dec mock

    implementation = new MarketWithViews();

    // ProxyAdmin with owner as `owner`
    vm.startPrank(owner);
    proxyAdmin = new ProxyAdmin(owner);

    // Init data
    bytes memory initData = abi.encodeWithSelector(
      Market.initialize.selector, "BTC", feeSink, address(usdt), address(0), gov, securityCouncil
    );

    // Proxy
    proxy = new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);

    // Interface to interact with proxy
    mkt = MarketWithViews(address(proxy));

    _mockOracle(btcPrice);

    vm.recordLogs();
    mkt.startCycle();
    Vm.Log[] memory entries = vm.getRecordedLogs();
    cycleId = uint256(entries[0].topics[1]); // There's only one log emitted in startCycle
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
    vm.startPrank(u1);
    mkt.withdrawCollateral(withdrawAmount);

    MarketWithViews.UserAccount memory ua = mkt.getUserAccount(u1);

    assertEq(ua.balance, depositAmount - withdrawAmount);
    assertEq(usdt.balanceOf(address(mkt)), depositAmount - withdrawAmount);
  }

  function testInsertCallBidPriceAtLowestBitmap() public {
    _fund(u1, 10 * ONE_COIN);
    MarketSide side = MarketSide.CALL_BUY;

    uint256 price = 2e6; // 2 USDT0

    vm.startPrank(u1);
    mkt.placeOrder(side, LOT, price, cycleId);

    uint32 tick = _tick(price); // tick = 2e6 / 1e4 = 200
    uint32 key = _key(tick, false, true); // CALL-BID

    // Test level volume
    Level memory lvl = mkt.levels(key);
    assertEq(lvl.vol, LOT, "level vol mismatch");

    // Test summary (L1) bitmap - l1 is 0, so bit 0 should be set. Which means value of 1
    assertEq(mkt.summaries(uint256(side)), 1, "summary bit not set correctly");

    // Test mid (L2) bitmap - l1 is 0, l2 is 0, so bit 0 should be set in mid[0]
    assertEq(mkt.mids(side, 0), 1, "mid bit not set correctly");

    // Test detail (L3) bitmap - l1 and l2 are 0, l3 is 200, since tick is 200
    uint16 detKey = 0; // (l1 << 8) | l2 where both are 0
    assertEq(mkt.dets(side, detKey), 1 << 200, "detail bit not set correctly");

    _printBook(side);
  }

  function testInsertCallBidPriceAtMiddleBitmap() public {
    _fund(u1, 1000 * ONE_COIN);
    MarketSide side = MarketSide.CALL_BUY;

    uint256 price = 700_000_000; // 700 USDT0
    uint32 expectedTick = 70000; // 700_000_000 / 10000

    vm.startPrank(u1);
    mkt.placeOrder(side, LOT, price, cycleId);

    uint32 tick = _tick(price);
    assertEq(tick, expectedTick, "tick calculation incorrect");

    uint32 key = _key(tick, false, true); // CALL-BID

    // Test level volume
    Level memory lvl = mkt.levels(key);
    assertEq(lvl.vol, LOT, "level vol mismatch");

    // Test summary (L1) bitmap - l1 is 0x01, so bit 1 should be set
    assertEq(mkt.summaries(uint256(side)), 1 << 1, "summary bit not set correctly");

    // Test mid (L2) bitmap - l1 is 0x01, l2 is 0x11 (17), so bit 17 should be set in mid[1]
    assertEq(mkt.mids(side, 1), 1 << 17, "mid bit not set correctly");

    // Test detail (L3) bitmap - l1 is 0x01, l2 is 0x11, l3 is 0x70 (112)
    uint16 detKey = (uint16(1) << 8) | 17; // (l1 << 8) | l2
    assertEq(mkt.dets(side, detKey), 1 << 112, "detail bit not set correctly");

    _printBook(side);
  }

  function testMultipleOrdersAtDifferentPriceLevels() public {
    _fund(u1, 1000 * ONE_COIN);
    MarketSide side = MarketSide.CALL_BUY;

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
      vm.startPrank(u1);
      mkt.placeOrder(side, LOT, prices[i], cycleId);
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

      assertTrue((mkt.summaries(uint256(side)) & (1 << l1s[i])) != 0, "summary bit not set");

      // Mid bitmap check - should have its bit set in the correct word
      assertTrue((mkt.mids(side, l1s[i]) & (1 << l2s[i])) != 0, "mid bit not set");

      // Detail bitmap check - should have its bit set in the correct word
      uint16 detKey = (uint16(l1s[i]) << 8) | l2s[i];
      assertTrue((mkt.dets(side, detKey) & (1 << l3s[i])) != 0, "detail bit not set");

      // Level check - should have correct volume
      uint32 key = _key(tick, false, true);
      Level memory lvl = mkt.levels(key);
      assertEq(lvl.vol, LOT, "level vol mismatch");
    }

    // Visual check
    _printBook(side);
  }

  // #######################################################################
  // #                                                                     #
  // #                        2. Maker <-> Taker match                     #
  // #                                                                     #
  // #######################################################################

  function testCrossAtSameTick() public {
    // Maker (u1) posts bid
    _fund(u1, 10000 * ONE_COIN);
    vm.startPrank(u1);
    mkt.placeOrder(MarketSide.CALL_BUY, LOT, ONE_COIN, cycleId);

    uint256 balSinkBefore = mkt.getUserAccount(feeSink).balance;

    // Taker (u2) hits bid
    _fund(u2, 10000 * ONE_COIN); // writer needs no upfront USDT premium
    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.CALL_SELL, LOT, ONE_COIN, cycleId); // Price crossed since same price
      // as maker

    // Queues empty, level deleted
    uint32 key = _key(_tick(ONE_COIN), false, true);
    Level memory lvl = mkt.levels(key);
    assertEq(lvl.vol, 0, "level not cleared");

    // Fee accounting - fees are now based on notional value (BTC price), not premium
    // int256 notional = int256(LOT) * int256(_getOraclePrice()) / 100; // CONTRACT_SIZE = 100
    int256 premium = int256(ONE_COIN) * int256(LOT);
    int256 makerFee = premium * MAKER_FEE_BPS / 10_000; // -0.10% rebate
    int256 takerFee = premium * TAKER_FEE_BPS / 10_000; // +0.50% charge
    uint256 sinkPlus = uint256(takerFee + makerFee); // House gets taker fee + maker fee

    assertEq(mkt.getUserAccount(feeSink).balance, balSinkBefore + sinkPlus);
  }

  // Market order sweeps 3 price levels and leaves tail in queue
  function testMarketOrderMultiLevelAndQueue() public {
    uint32[3] memory ticks = [_tick(ONE_COIN), _tick(ONE_COIN * 2), _tick(ONE_COIN * 700)];
    uint256 collatPerContract = btcPrice * 10 ** 6 / 100 / 1000; // Divide by 100 for 0.01BTC size contract price,
      // divide by 1000 for 0.1% margin
    _fund(u1, collatPerContract * LOT * 3);

    // Three makers @ 1,2,700 USD
    for (uint256 i; i < 3; ++i) {
      vm.startPrank(u1);
      mkt.placeOrder(MarketSide.PUT_SELL, LOT, ticks[i] * 1e4, cycleId); // ask
    }

    // Taker buys 350 contracts market –> eats 3 levels
    _fund(u2, 1000000 * ONE_COIN);
    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.PUT_BUY, 350, 0, cycleId); // market

    // level[0] & level[1] empty, level[2] empty
    uint32 key0 = _key(ticks[0], true, false);
    Level memory lvl0 = mkt.levels(key0);
    assertEq(lvl0.vol, 0);
    uint32 key1 = _key(ticks[1], true, false);
    Level memory lvl1 = mkt.levels(key1);
    assertEq(lvl1.vol, 0);
    uint32 key2 = _key(ticks[2], true, false);
    Level memory lvl2 = mkt.levels(key2);
    assertEq(lvl2.vol, 0);

    // Queue should not hold any leftover (fully filled)
    (TakerQ[] memory q) = mkt.viewTakerQueue(MarketSide.PUT_BUY); // PUT-Bid bucket
    assertEq(q.length, 1, "incorrect queue length");
    assertEq(q[0].size, 50, "incorrect queue size");
  }

  function testLiquidation() public {
    // Maker
    _fund(u1, 1000 * ONE_COIN);
    vm.startPrank(u1);
    // Buy and sell price the same to make premium accounting net to zero
    mkt.placeOrder(MarketSide.PUT_BUY, 1, 1, cycleId);
    mkt.placeOrder(MarketSide.CALL_SELL, 1, 1, cycleId);

    // Taker going long, to be liquidated
    uint256 userCollateral = 1 * ONE_COIN;
    _fund(u2, userCollateral);
    vm.startPrank(u2);
    vm.recordLogs();
    mkt.long(1, cycleId);

    // Check if liquidatable.
    uint64 currentPrice = uint64(btcPrice * 1e6);
    assertEq(mkt.isLiquidatable(u2, currentPrice), false); // current price is 100000, where user opened position
    currentPrice -= uint64(CONTRACT_SIZE);
    assertEq(mkt.isLiquidatable(u2, currentPrice), true); // Becomes liquidatable as just 1 tick below strike

    // Liquidate
    _mockOracle(btcPrice - 1); // Oracle only reports price in whole dollar moves. There are no cents in the oracle
      // price.
    vm.startPrank(owner);
    mkt.liquidate(u2);

    // In this case, liquidated user's market order goes to the takerQueue, so fill it

    vm.startPrank(u1);
    uint256 optionPrice = TICK_SIZE;
    mkt.placeOrder(MarketSide.PUT_SELL, 1, optionPrice, cycleId);

    // Check if liquidated
    uint256 takerFee = uint256(int256(TICK_SIZE) * TAKER_FEE_BPS / 10_000);
    assertEq(mkt.getUserAccount(u2).balance, userCollateral - optionPrice - takerFee);
    assertEq(mkt.getUserAccount(u2).liquidationQueued, false);
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
    vm.startPrank(u1);
    mkt.placeOrder(MarketSide.PUT_BUY, 120, 0, cycleId); // book is blank

    (TakerQ[] memory qBefore) = mkt.viewTakerQueue(MarketSide.PUT_BUY);
    assertEq(qBefore.length, 1); // 1 queued
    assertEq(qBefore[0].size, 120);

    // Maker comes with limit Sell 200 @ $1
    _fund(u2, 1000 * ONE_COIN);
    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.PUT_SELL, 200, ONE_COIN, cycleId);

    // The first 120 matched immediately, only 80 rest on book
    uint32 key = _key(_tick(ONE_COIN), true, false); // PUT-Ask
    Level memory lvl = mkt.levels(key);
    assertEq(lvl.vol, 80, "book remainder wrong");

    // Queue length won't be zero since we don't pop, but pointer should be equal to length
    (TakerQ[] memory qAfter) = mkt.viewTakerQueue(MarketSide.PUT_BUY);
    assertEq(mkt.tqHead(uint256(MarketSide.PUT_BUY)), qAfter.length, "queue head not at the end");
  }

  // #######################################################################
  // #                                                                     #
  // #                            Liquidation                              #
  // #                                                                     #
  // #######################################################################

  function testLiquidateRevertIfSafe() public {
    _fund(u1, 10 * ONE_COIN);
    vm.expectRevert("Not liquidatable");
    mkt.liquidate(u1);
  }

  /// maker-order and queued-taker entries are wiped when trader is liquidated
  function testLiquidationClearsBookAndQueues() public {
    // 1) Collateral: 150 USDT (enough to open, nowhere near enough after pump)
    _fund(u1, 150 * ONE_COIN);
    _fund(u2, 5000 * ONE_COIN); // counter-party + later liquidity

    // 2) u2 posts a BID for 100 CALL contracts @ 1 USDT
    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.CALL_BUY, LOT, ONE_COIN, cycleId); // bid sits

    // 3) u1 hits that bid (short CALL)
    vm.startPrank(u1);
    mkt.placeOrder(MarketSide.CALL_SELL, LOT, ONE_COIN, cycleId); // taker sell

    // u1 now has 100 short-CALLs, balance = 150 + 100 (premium) = 250 USDT
    assertEq(mkt.getUserAccount(u1).shortCalls, LOT);

    // 4) Leave a resting maker ask (10 contracts @ 2 USDT) on the book, don't fill
    vm.startPrank(u1);
    mkt.placeOrder(MarketSide.CALL_SELL, 10, ONE_COIN * 2, cycleId); // will not cross

    // 5) Leave a *queued* taker order (PUT-BUY, 30 contracts, market)
    vm.startPrank(u1);
    mkt.placeOrder(MarketSide.PUT_BUY, 30, 0, cycleId); // book empty → queued
    (TakerQ[] memory qBefore) = mkt.viewTakerQueue(MarketSide.PUT_BUY);
    assertEq(qBefore.length, 1);
    assertEq(qBefore[0].trader, u1);

    // BTC pumps by +20 k
    _mockOracle(btcPrice + 20_000);
    assertTrue(mkt.isLiquidatable(u1, uint64((btcPrice + 20_000) * 1e6)), "trader should now be liquidatable");

    // Liquidate
    vm.startPrank(owner);
    mkt.liquidate(u1);

    // Resting maker order cleared
    uint32 restingKey = _key(_tick(ONE_COIN * 2), false, false); // CALL-ASK key
    assertEq(mkt.levels(restingKey).vol, 0, "maker vol not cleared");

    // Queued taker entry zeroed
    (TakerQ[] memory qAfter) = mkt.viewTakerQueue(MarketSide.PUT_BUY);
    uint256 head = mkt.tqHead(uint256(MarketSide.PUT_BUY));
    bool queueClean = qAfter.length == 0 || head >= qAfter.length || qAfter[head].size == 0;
    assertTrue(queueClean, "taker queue not cleaned");

    // 3. liquidation flag set (until closing trades finish)
    assertTrue(mkt.getUserAccount(u1).liquidationQueued, "flag not set");

    // 4. short position has started to be offset (<= original LOT)
    qAfter = mkt.viewTakerQueue(MarketSide.CALL_BUY);
    assertEq(qAfter.length, 1, "liq market order not queued");
  }

  function testLiquidationPriceHelperCall() public {
    _fund(u1, 2 * ONE_COIN);
    _fund(u2, 2 * ONE_COIN);

    _openCallPair(u2, u1);

    (uint64 upperPx, uint64 lowerPx) = mkt.liquidationPrices(u1);

    assertGt(upperPx, 0, "upperPx should be > 0 for short CALL");
    assertEq(lowerPx, 0, "lowerPx should be 0 (no short PUTs)");

    uint64 almostPx = upperPx > 0 ? upperPx - 1 : upperPx;
    bool unsafeBelow = mkt.isLiquidatable(u1, almostPx);
    assertFalse(unsafeBelow, "should NOT liquidate just below threshold");

    bool unsafeAbove = mkt.isLiquidatable(u1, upperPx);
    assertTrue(unsafeAbove, "should liquidate once price crosses threshold");
  }

  function testLiquidationPriceHelperPut() public {
    _fund(u1, 2 * ONE_COIN); // writer – will be liquidated
    _fund(u2, 2 * ONE_COIN); // long side

    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.PUT_BUY, 1, ONE_COIN, cycleId); // bid
    vm.startPrank(u1);
    mkt.placeOrder(MarketSide.PUT_SELL, 1, ONE_COIN, cycleId);

    (uint64 upperPx, uint64 lowerPx) = mkt.liquidationPrices(u1);

    assertEq(upperPx, 0, "upperPx should be 0 (no short CALLs)");
    assertGt(lowerPx, 0, "lowerPx should be > 0 for short PUT");

    uint64 justAbove = lowerPx + 1; // just above = safe
    assertFalse(mkt.isLiquidatable(u1, justAbove), "should NOT liquidate just above lowerPx");

    assertTrue(mkt.isLiquidatable(u1, lowerPx), "should liquidate once price crosses below threshold");

    console.log("upperPx", upperPx);
    console.log("lowerPx", lowerPx);
    console.log("justAbove", justAbove);
  }

  // #######################################################################
  // #                                                                     #
  // #                            Settlement                               #
  // #                                                                     #
  // #######################################################################

  function testSettlement_NoSocialLoss() public {
    uint256 collateral = 200 * ONE_COIN;
    _fund(u1, collateral); // long – must be able to receive, not pay
    _fund(u2, collateral); // short – ample collateral → no bad-debt

    _openCallPair(u1, u2);

    // fast-forward to expiry
    vm.warp(cycleId + 1);
    _mockOracle(btcPrice + 10_000); // +10 k → long wins 100 USDT

    // phase-1 + phase-2 in two txs
    mkt.settleChunk(20);
    mkt.settleChunk(20);

    // cycle closed
    assertEq(mkt.activeCycle(), 0);
    (bool settled,,) = mkt.cycles(cycleId);
    assertTrue(settled, "cycle not flagged as settled");

    // u1 received full 100 USDT (±1 tick for fees) – check delta not exact start
    uint256 gain = mkt.getUserAccount(u1).balance - (collateral - ONE_COIN - 70_000); // deposit - premium - fee
    assertEq(gain, 100 * ONE_COIN, "winner not paid in full");

    // u2 balance dropped by 100 USDT
    uint256 loss = (200 * ONE_COIN + 1_020_000) - mkt.getUserAccount(u2).balance; // deposit + premium rebate
    assertEq(loss, 100 * ONE_COIN, "loser did not pay full");
  }

  function testSettlementPartialSocialLoss() public {
    uint256 longDeposit = 50 * ONE_COIN; // 50 USDT
    uint256 shortDeposit = 60 * ONE_COIN; // 60 USDT
    _fund(u1, longDeposit);
    _fund(u2, shortDeposit);

    _openCallPair(u1, u2);

    uint256 premium = ONE_COIN; // 1.000000
    int256 makerFee = int256(premium) * MAKER_FEE_BPS / 10_000;
    int256 takerFee = int256(premium) * TAKER_FEE_BPS / 10_000;

    int256 cashMaker = -int256(premium) - makerFee; // −0.98 USDT
    int256 cashTaker = int256(premium) - takerFee; // +0.93 USDT

    uint256 balU1_afterTrade = uint256(int256(longDeposit) + cashMaker);
    uint256 balU2_afterTrade = uint256(int256(shortDeposit) + cashTaker);

    vm.warp(cycleId + 1);
    _mockOracle(btcPrice + 10_000); // +10 000 USD spot move

    uint256 intrinsic = (10_000 * ONE_COIN) / CONTRACT_SIZE; // 100 USDT

    mkt.settleChunk(10);

    // u2 must be drained to zero, u1’s scratchPnL should equal +100
    assertEq(mkt.getUserAccount(u2).balance, 0);
    uint256 scratchPnL = mkt.getUserAccount(u1).scratchPnL;
    assertEq(scratchPnL, intrinsic);

    mkt.settleChunk(10);

    // Full balance taken from u2
    uint256 expectedFinal = balU1_afterTrade + balU2_afterTrade;

    assertEq(mkt.getUserAccount(u1).balance, expectedFinal, "social-loss calculation wrong");
    assertLt(balU2_afterTrade, scratchPnL, "u1 should recieve less than their actual pnl");
  }

  // #######################################################################
  // #                                                                     #
  // #                    Bitscan and bitmap invariants                    #
  // #                                                                     #
  // #######################################################################

  function testFuzzBitmap(uint128 amount, uint8 priceTick, uint8 sideIndex) public {
    vm.assume(amount > 0 && amount < 1e6);
    vm.assume(sideIndex < 4);
    MarketSide side = MarketSide(sideIndex);
    uint256 price = uint256(priceTick) * 1e4 + 1e4; // >=1 tick

    _fund(u1, 1e24);
    vm.startPrank(u1);
    mkt.placeOrder(side, amount, price, cycleId);

    uint32 tick = _tick(price);
    (uint8 l1,,) = BitScan.split(tick);
    assertTrue((mkt.summaries(uint256(side)) & BitScan.mask(l1)) != 0); // bit set
  }

  function testBitscan(uint256 bit) public pure {
    vm.assume(bit < 256);
    assert(BitScan.msb(1) == 0); // bit-0 set
    // Check that msb returns the correct index
    assert(BitScan.msb(1 << bit) == bit);
  }

  function testCancelOrderNonExistentOrder() public {
    _fund(u1, 1000 * ONE_COIN);
    vm.startPrank(u1);
    mkt.placeOrder(MarketSide.PUT_SELL, 200, ONE_COIN, cycleId);

    vm.startPrank(u1);
    vm.expectRevert();
    mkt.cancelOrder(123);
  }

  function testTakerQueueThenLimitOrder() public {
    _fund(u1, 1000 * ONE_COIN);
    vm.startPrank(u1);
    mkt.placeOrder(MarketSide.PUT_BUY, 2, 0, cycleId); // book is blank

    _fund(u2, 1000 * ONE_COIN);
    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.PUT_SELL, 1, ONE_COIN, cycleId);
  }

  // #######################################################################
  // #                                                                     #
  // #                             Helpers                                 #
  // #                                                                     #
  // #######################################################################

  function _fund(address who, uint256 amount) internal {
    deal(address(usdt), who, amount);
    vm.startPrank(who);
    usdt.approve(address(mkt), type(uint256).max);
    bytes memory signature = _createSignature(who);
    vm.startPrank(who);
    mkt.depositCollateral(amount, signature);
  }

  function _tick(uint256 p) internal pure returns (uint32) {
    return uint32(p / 1e4);
  }

  function _key(uint32 t, bool put, bool bid) internal pure returns (uint32) {
    return t | (put ? 1 << 31 : 0) | (bid ? 1 << 30 : 0);
  }

  function _createSignature(address user) internal view returns (bytes memory) {
    bytes32 messageHash = keccak256(abi.encodePacked(user));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, messageHash);
    return abi.encodePacked(r, s, v);
  }

  // helper: open a 1-contract CALL long/short pair at 1 USDT premium
  function _openCallPair(address longAddr, address shortAddr) internal {
    // shortAddr posts ask
    vm.startPrank(shortAddr);
    mkt.placeOrder(MarketSide.CALL_SELL, 1, ONE_COIN, cycleId);
    vm.stopPrank();

    // longAddr hits it market
    vm.startPrank(longAddr);
    mkt.placeOrder(MarketSide.CALL_BUY, 1, 0, cycleId); // market
    vm.stopPrank();
  }

  function _printBook(MarketSide side) internal view {
    OBLevel[] memory book = mkt.dumpBook(side);

    console.log("\n");
    console.log("============================================");
    console.log(
      "              %s %s                ",
      side == MarketSide.PUT_BUY || side == MarketSide.PUT_SELL ? "PUT" : "CALL",
      side == MarketSide.CALL_BUY || side == MarketSide.PUT_BUY ? "BIDS" : "ASKS"
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
      console.log("%d\t\t%d\t\t%d", book[i].tick, price6, book[i].vol);
    }
    console.log("============================================\n");
  }

  function _getOraclePrice() internal view returns (int256) {
    return int256(btcPrice * 1000000);
  }

  function _mockOracle(uint256 price) internal {
    vm.mockCall(
      address(0x0000000000000000000000000000000000000806),
      abi.encodeWithSelector(0x00000000),
      abi.encode(price * 10) // Oracle and Mark price feeds return with 1 decimal when reading L1 from HyperEVM
    );
  }
}
