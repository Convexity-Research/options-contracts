// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/StdUtils.sol";
import "./mocks/MarketWithViews.sol";
import {BitScan} from "../src/lib/Bitscan.sol";
import {Token} from "./mocks/Token.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract MarketSuite is Test {
  using BitScan for uint256;

  int256 constant MAKER_FEE_BPS = -200;
  int256 constant TAKER_FEE_BPS = 700;
  uint256 constant TICK_SIZE = 1e2;
  uint256 constant CONTRACT_SIZE = 100;

  uint256 constant ONE_COIN = 1_000_000; // 6-dec → 1.00
  uint256 constant LOT = 100; // contracts
  uint256 constant DEFAULT_EXPIRY = 1 minutes;

  Token usdt; // USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb on hyperEVM. 6 decimals

  MarketWithViews implementation;
  ERC1967Proxy proxy;
  MarketWithViews mkt;

  address owner = makeAddr("owner");
  address u1 = makeAddr("user1");
  address u2 = makeAddr("user2");
  address feeSink = makeAddr("feeSink");
  address gov = makeAddr("gov");
  address securityCouncil = 0xAd8997fAaAc3DA36CA0aA88a0AAf948A6C3a5338;
  address signer;
  uint256 signerKey;

  uint256 btcPrice = 107370;

  uint256 cycleId;

  function setUp() public {
    usdt = new Token("USDT0", "USDT0"); // 6-dec mock

    implementation = new MarketWithViews();

    // Init data
    bytes memory initData =
      abi.encodeWithSelector(Market.initialize.selector, "BTC", feeSink, address(usdt), address(0), gov);

    // Proxy
    proxy = new ERC1967Proxy(address(implementation), initData);

    vm.startPrank(owner);

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

    uint256 price = 2e4; // 0.02 USDT0

    vm.startPrank(u1);
    mkt.placeOrder(side, LOT, price, cycleId);

    uint32 tick = _tick(price); // tick = 2e4 / 1e2 = 200
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

    uint256 price = 7_000_000; // 7 USDT0
    uint32 expectedTick = 70000; // 7_000_000 / 10000

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
    // e4 everywhere because token decimals = 6, tick size = 2, so 6-2 = 4 decimals places
    prices[0] = 2e4;
    l1s[0] = 0;
    l2s[0] = 0;
    l3s[0] = 200;

    // 700 USDT0 - middle level (from second test)
    prices[1] = 700e4;
    l1s[1] = 1;
    l2s[1] = 17;
    l3s[1] = 112;

    // 1000 USDT0 - different level
    prices[2] = 1000e4;
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
      mkt.placeOrder(MarketSide.PUT_SELL, LOT, ticks[i] * TICK_SIZE, cycleId); // ask
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

  function testLiquidationPlain() public {
    // Maker
    _fund(u1, 1000 * ONE_COIN);
    vm.startPrank(u1);
    // Buy and sell price the same to make premium accounting net to zero
    mkt.placeOrder(MarketSide.PUT_BUY, 1, 1, cycleId);
    mkt.placeOrder(MarketSide.CALL_SELL, 1, 1, cycleId);

    // Taker going long, to be liquidated
    uint256 userCollateral = 1 * ONE_COIN + 1000;
    _fund(u2, userCollateral);
    vm.startPrank(u2);
    vm.recordLogs();
    mkt.long(1, 0, 0, cycleId);

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

  function testMaximumPriceLevelsMatch() public {}

  function testMaxPremiumPaidByRestingLimitOrder() public {}

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
    assertEq(mkt.getTqHead(uint256(MarketSide.PUT_BUY)), qAfter.length, "queue head not at the end");
  }

  // #######################################################################
  // #                                                                     #
  // #                            Liquidation                              #
  // #                                                                     #
  // #######################################################################

  function testLiquidateRevertIfSafe() public {
    _fund(u1, 10 * ONE_COIN);
    vm.expectRevert(Errors.StillSolvent.selector);
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
    uint256 head = mkt.getTqHead(uint256(MarketSide.PUT_BUY));
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
    mkt.settleChunk(20, false);

    // cycle closed
    Cycle memory cycle = mkt.getCycle(cycleId);
    bool settled = cycle.isSettled;
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
    int256 takerFee = int256(premium) * TAKER_FEE_BPS / 10_000; // u1
    int256 makerFee = int256(premium) * MAKER_FEE_BPS / 10_000; // u2

    int256 cashTaker = -int256(premium) - takerFee; // -1.07 USDT
    int256 cashMaker = int256(premium) - makerFee; // +1.02 USDT

    uint256 balU1_afterTrade = uint256(int256(longDeposit) + cashTaker);
    uint256 balU2_afterTrade = uint256(int256(shortDeposit) + cashMaker);

    vm.warp(cycleId + 1);
    _mockOracle(btcPrice + 10_000); // +10 000 USD spot move

    uint256 intrinsic = (10_000 * ONE_COIN) / CONTRACT_SIZE; // 100 USDT

    mkt.settleChunk(10, false);

    // u2 must be drained to zero, u1's scratchPnL should equal +100
    assertEq(mkt.getUserAccount(u2).balance, 0, "u2 balance not zero");

    // Full balance taken from u2
    uint256 expectedFinal = balU1_afterTrade + balU2_afterTrade;

    assertEq(mkt.getUserAccount(u1).balance, expectedFinal, "social-loss calculation wrong");
    assertLt(balU2_afterTrade, intrinsic, "u1 receives less than their 'deserved' pnl");
  }

  function testSettlementCompleteInOneTransaction() public {
    // Setup
    uint256 collateral = 200 * ONE_COIN;
    _fund(u1, collateral);
    _fund(u2, collateral);

    // Open a call pair
    _openCallPair(u1, u2);

    uint256 initialCycleId = mkt.activeCycle();
    assertGt(initialCycleId, 0, "Should have active cycle");

    vm.warp(initialCycleId + 1);
    _mockOracle(btcPrice + 1000);

    vm.recordLogs();
    mkt.settleChunk(1000, false);
    Vm.Log[] memory logs = vm.getRecordedLogs();

    // Should have CycleSettled and CycleStarted events
    bool foundCycleSettled = false;
    bool foundCycleStarted = false;
    uint256 newCycleId = 0;

    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == keccak256("CycleSettled(uint256)")) {
        foundCycleSettled = true;
        assertEq(uint256(logs[i].topics[1]), initialCycleId, "Wrong cycle settled");
      }
      if (logs[i].topics[0] == keccak256("CycleStarted(uint256,uint256)")) {
        foundCycleStarted = true;
        newCycleId = uint256(logs[i].topics[1]);
      }
    }

    assertTrue(foundCycleSettled, "CycleSettled event not found");
    assertTrue(foundCycleStarted, "CycleStarted event not found");
    assertGt(newCycleId, initialCycleId, "New cycle should have later expiry");

    // Verify new cycle is active
    assertEq(mkt.activeCycle(), newCycleId, "New cycle should be active");

    // Verify old cycle is marked as settled
    Cycle memory cycle = mkt.getCycle(initialCycleId);
    bool isSettled = cycle.isSettled;
    assertTrue(isSettled, "Old cycle should be settled");
  }

  function testSettlementCompleteInTwoPhasesWithCompleteFirstPhase() public {
    // Setup
    address[4] memory users = [u1, u2, makeAddr("user3"), makeAddr("user4")];

    for (uint256 i; i < users.length; ++i) {
      _fund(users[i], 200 * ONE_COIN);
    }

    _openCallPair(users[0], users[1]);
    _openCallPair(users[2], users[3]);

    uint256 cycleIdBefore = mkt.activeCycle();

    // Expire cycle and settle in two chunks
    vm.warp(cycleIdBefore + 1);
    _mockOracle(btcPrice + 1_000);

    // 1st chunk — should NOT finish settlement
    vm.recordLogs();
    mkt.settleChunk(6, false); // Choose a chunk size which would complete phase 1
    Vm.Log[] memory first = vm.getRecordedLogs();

    for (uint256 i; i < first.length; ++i) {
      require(
        first[i].topics[0] != keccak256("CycleSettled(uint256)")
          && first[i].topics[0] != keccak256("CycleStarted(uint256,uint256)"),
        "cycle should not finish in first chunk"
      );
    }
    assertEq(mkt.activeCycle(), cycleIdBefore, "cycle should remain active");

    // 2nd chunk — must complete settlement and start new cycle
    vm.recordLogs();
    mkt.settleChunk(100, false);
    Vm.Log[] memory second = vm.getRecordedLogs();

    uint256 cycleIdAfter;
    bool settled;
    bool started;

    for (uint256 i; i < second.length; ++i) {
      if (second[i].topics[0] == keccak256("CycleSettled(uint256)")) settled = true;
      if (second[i].topics[0] == keccak256("CycleStarted(uint256,uint256)")) {
        started = true;
        cycleIdAfter = uint256(second[i].topics[1]);
      }
    }

    assertTrue(settled && started, "cycle should complete and next start");
    assertGt(cycleIdAfter, cycleIdBefore, "new cycle id should increase");
    assertEq(mkt.activeCycle(), cycleIdAfter);
  }

  function testSettlementCompleteInTwoPhasesWithIncompleteFirstPhase() public {
    // Same test as above, but with a chunk size that doesn't complete phase 1
    // Setup: four users, two call pairs
    address[4] memory users = [u1, u2, makeAddr("user3"), makeAddr("user4")];

    for (uint256 i; i < users.length; ++i) {
      _fund(users[i], 200 * ONE_COIN);
    }

    _openCallPair(users[0], users[1]);
    _openCallPair(users[2], users[3]);

    uint256 cycleIdBefore = mkt.activeCycle();

    // Expire cycle and settle in two chunks
    vm.warp(cycleIdBefore + 1);
    _mockOracle(btcPrice + 1_000);

    // 1st chunk — should NOT finish settlement
    vm.recordLogs();
    mkt.settleChunk(3, false); // Choose a chunk size which would not complete phase 1
    Vm.Log[] memory first = vm.getRecordedLogs();

    for (uint256 i; i < first.length; ++i) {
      require(
        first[i].topics[0] != keccak256("CycleSettled(uint256)")
          && first[i].topics[0] != keccak256("CycleStarted(uint256,uint256)"),
        "cycle should not finish in first chunk"
      );
    }
    assertEq(mkt.activeCycle(), cycleIdBefore, "cycle should remain active");

    // 2nd chunk — must complete settlement and start new cycle
    vm.recordLogs();
    mkt.settleChunk(100, false);
    Vm.Log[] memory second = vm.getRecordedLogs();

    uint256 cycleIdAfter;
    bool settled;
    bool started;

    for (uint256 i; i < second.length; ++i) {
      if (second[i].topics[0] == keccak256("CycleSettled(uint256)")) settled = true;
      if (second[i].topics[0] == keccak256("CycleStarted(uint256,uint256)")) {
        started = true;
        cycleIdAfter = uint256(second[i].topics[1]);
      }
    }

    assertTrue(settled && started, "cycle should complete and next start");
    assertGt(cycleIdAfter, cycleIdBefore, "new cycle id should increase");
    assertEq(mkt.activeCycle(), cycleIdAfter);
  }

  function testSettlementCompleteInMultipleTransactions() public {
    // Setup
    for (uint256 i; i < 8; ++i) {
      address user = makeAddr(string(abi.encodePacked("multi", vm.toString(i))));
      _fund(user, 200 * ONE_COIN);
      if (i & 1 == 1) _openCallPair(makeAddr(string(abi.encodePacked("multi", vm.toString(i - 1)))), user);
    }

    uint256 cycleIdBefore = mkt.activeCycle();
    vm.warp(cycleIdBefore + 1);
    _mockOracle(btcPrice + 1_000);

    uint256 txCount;
    while (mkt.activeCycle() == cycleIdBefore) {
      mkt.settleChunk(1, false); // deliberately small to force many txs
      ++txCount;
    }

    assertGt(txCount, 2, "should take more than two txs");
    Cycle memory cycle = mkt.getCycle(cycleIdBefore);
    bool settled = cycle.isSettled;
    assertTrue(settled, "previous cycle not settled");
    assertGt(mkt.activeCycle(), cycleIdBefore, "new cycle should start");
  }

  // function testSettlementWithPausePreventsAutoCycle() public {
  //   // Setup
  //   _fund(u1, 200 * ONE_COIN);
  //   _fund(u2, 200 * ONE_COIN);

  //   // Can still place orders after pause
  //   _openCallPair(u1, u2);

  //   vm.startPrank(securityCouncil);
  //   mkt.pause();
  //   vm.stopPrank();

  //   vm.warp(cycleId + 1);
  //   _mockOracle(btcPrice + 1_000);

  //   mkt.settleChunk(100);

  //   // Cycle settled — but no new cycle should have started
  //   Cycle memory cycle = mkt.getCycle(cycleId);
  //   bool settled = cycle.isSettled;
  //   assertTrue(settled, "cycle should settle");
  //   assertEq(mkt.activeCycle(), 0, "no active cycle in settlement only mode");

  //   // Attempting to start a cycle must revert
  //   vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
  //   mkt.startCycle();

  //   // Exit settlement‑only mode and start a new cycle
  //   vm.startPrank(securityCouncil);
  //   mkt.unpause();
  //   vm.stopPrank();

  //   mkt.startCycle();
  //   assertGt(mkt.activeCycle(), cycleId, "new cycle should start after unpause");
  // }

  function testPauseUnpause() public {
    vm.startPrank(securityCouncil);

    // Standard full pause()
    mkt.pause();
    assertEq(mkt.paused(), true);

    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    mkt.startCycle();

    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    mkt.placeOrder(MarketSide.CALL_BUY, 1, 1, cycleId);

    vm.warp(cycleId + 1);
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    mkt.settleChunk(100, false);

    mkt.unpause();
    mkt.settleChunk(100, false);
  }

  // #######################################################################
  // #                                                                     #
  // #              Comprehensive Settlement-Only Mode Tests               #
  // #                                                                     #
  // #######################################################################

  // function testSettlementOnlyMode_DepositCollateralBlocked() public {
  //   // Start in normal mode
  //   assertEq(mkt.paused(), false);

  //   // Enable settlement-only mode
  //   vm.startPrank(securityCouncil);
  //   mkt.pause();
  //   vm.stopPrank();

  //   // Try to deposit collateral - should revert
  //   deal(address(usdt), u1, 100 * ONE_COIN);
  //   _whitelistAddress(u1);
  //   vm.startPrank(u1);
  //   usdt.approve(address(mkt), type(uint256).max);

  //   vm.expectRevert(Errors.SettlementOnlyMode.selector);
  //   mkt.depositCollateral(100 * ONE_COIN);
  // }

  // function testSettlementOnlyMode_DepositCollateralWithSignatureBlocked() public {
  //   // Enable settlement-only mode
  //   vm.startPrank(securityCouncil);
  //   mkt.pause();
  //   vm.stopPrank();

  //   // Try to deposit collateral with signature - should revert with SettlementOnlyMode
  //   deal(address(usdt), u1, 100 * ONE_COIN);
  //   vm.startPrank(u1);
  //   usdt.approve(address(mkt), type(uint256).max);

  //   // Create a valid signature - the signature validation happens first
  //   // We'll use a mock signature that will fail validation before reaching settlement-only check
  //   bytes memory signature = abi.encodePacked(bytes32(0), bytes32(0), uint8(0));

  //   // Should revert with signature error, not settlement-only mode error
  //   // because signature validation happens first
  //   vm.expectRevert();
  //   mkt.depositCollateral(100 * ONE_COIN, signature);
  // }

  // function testSettlementOnlyMode_WithdrawCollateralBlocked() public {
  //   // First fund user in normal mode
  //   _fund(u1, 100 * ONE_COIN);

  //   // Enable settlement-only mode
  //   vm.startPrank(securityCouncil);
  //   mkt.pause();
  //   vm.stopPrank();

  //   // Try to withdraw collateral - should revert
  //   vm.startPrank(u1);
  //   vm.expectRevert(Errors.SettlementOnlyMode.selector);
  //   mkt.withdrawCollateral(50 * ONE_COIN);
  // }

  // function testSettlementOnlyMode_TradingAllowed() public {
  //   // Fund users in normal mode
  //   _fund(u1, 100 * ONE_COIN);
  //   _fund(u2, 100 * ONE_COIN);

  //   // Enable settlement-only mode
  //   vm.startPrank(securityCouncil);
  //   mkt.pause();
  //   vm.stopPrank();

  //   uint256 currentCycleId = mkt.activeCycle();

  //   // Trading functions should still work in settlement-only mode
  //   // Only deposits/withdrawals are blocked
  //   vm.startPrank(u1);
  //   mkt.long(1, 0, currentCycleId); // Should work

  //   vm.startPrank(u2);
  //   mkt.short(1, 0, currentCycleId); // Should work

  //   vm.startPrank(u1);
  //   // Place a limit order
  //   mkt.placeOrder(MarketSide.CALL_BUY, 1, ONE_COIN, currentCycleId); // Should work

  //   // Cancel that order - just try to cancel order ID 1 (if it exists)
  //   // We can't easily access the userOrders mapping from tests, so just try a common order ID
  //   try mkt.cancelOrder(1) {
  //     // Order existed and was cancelled successfully
  //   } catch {
  //     // Order didn't exist, which is fine for this test
  //   }
  // }

  // function testSettlementOnlyMode_StartCycleBlocked() public {
  //   // Setup a cycle and settle it first
  //   _fund(u1, 100 * ONE_COIN);
  //   _fund(u2, 100 * ONE_COIN);
  //   _openCallPair(u1, u2);

  //   uint256 currentCycleId = mkt.activeCycle();
  //   vm.warp(currentCycleId + 1);

  //   // Enable settlement-only mode before settling
  //   vm.startPrank(securityCouncil);
  //   mkt.pause();
  //   vm.stopPrank();

  //   // Settlement should still work
  //   mkt.settleChunk(100);

  //   // Verify cycle is settled but no new cycle started
  //   Cycle memory cycle = mkt.getCycle(currentCycleId);
  //   bool settled = cycle.isSettled;
  //   assertTrue(settled, "cycle should be settled");
  //   assertEq(mkt.activeCycle(), 0, "no new cycle should start in settlement-only mode");

  //   // Try to manually start cycle - should revert
  //   vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
  //   mkt.startCycle();
  // }

  // function testSettlementOnlyMode_SettlementWorksWhenPaused() public {
  //   // Setup positions
  //   _fund(u1, 100 * ONE_COIN);
  //   _fund(u2, 100 * ONE_COIN);
  //   _openCallPair(u1, u2);

  //   uint256 currentCycleId = mkt.activeCycle();
  //   vm.warp(currentCycleId + 1);

  //   // Full pause (not just settlement-only)
  //   // vm.startPrank(securityCouncil);
  //   // mkt.pause();
  //   // vm.stopPrank();

  //   // // Settlement should fail with full pause
  //   // vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
  //   // mkt.settleChunk(100);

  //   // Enable settlement-only mode (this unpauses but sets settlementOnlyMode)
  //   vm.startPrank(securityCouncil);
  //   mkt.pause();
  //   vm.stopPrank();

  //   // Now settlement should work
  //   mkt.settleChunk(100);

  //   // Verify settlement completed
  //   Cycle memory cycle = mkt.getCycle(currentCycleId);
  //   bool settled = cycle.isSettled;
  //   assertTrue(settled, "cycle should be settled");
  // }

  // function testSettlementOnlyMode_UnpauseRestoresNormalOperation() public {
  //   // Setup and enable settlement-only mode
  //   _fund(u1, 100 * ONE_COIN);
  //   _fund(u2, 100 * ONE_COIN);

  //   vm.startPrank(securityCouncil);
  //   mkt.pause();
  //   vm.stopPrank();

  //   // Verify operations are blocked
  //   deal(address(usdt), u1, 10 * ONE_COIN); // Give user additional tokens
  //   vm.startPrank(u1);
  //   usdt.approve(address(mkt), type(uint256).max);
  //   vm.expectRevert(Errors.SettlementOnlyMode.selector);
  //   mkt.depositCollateral(10 * ONE_COIN);
  //   vm.stopPrank();

  //   // Unpause should restore normal operation
  //   vm.startPrank(securityCouncil);
  //   mkt.unpause();
  //   vm.stopPrank();

  //   // Verify normal operations work again
  //   assertEq(mkt.paused(), false);

  //   vm.startPrank(u1);
  //   // Should not revert anymore
  //   mkt.depositCollateral(10 * ONE_COIN);
  //   mkt.withdrawCollateral(5 * ONE_COIN);
  //   vm.stopPrank();

  //   // New cycle should start automatically if none active
  //   if (mkt.activeCycle() == 0) {
  //     mkt.startCycle();
  //     assertGt(mkt.activeCycle(), 0, "new cycle should start after unpause");
  //   }
  // }

  // function testSettlementOnlyMode_AdminFunctionAccess() public {
  //   // Only security council should be able to call pause
  //   vm.expectRevert();
  //   mkt.pause();

  //   vm.startPrank(owner);
  //   vm.expectRevert();
  //   mkt.pause();
  //   vm.stopPrank();

  //   // Security council should succeed
  //   vm.startPrank(securityCouncil);
  //   mkt.pause();
  //   vm.stopPrank();

  //   // Only security council should be able to unpause
  //   vm.expectRevert();
  //   mkt.unpause();

  //   vm.startPrank(owner);
  //   vm.expectRevert();
  //   mkt.unpause();
  //   vm.stopPrank();

  //   // Security council should succeed
  //   vm.startPrank(securityCouncil);
  //   mkt.unpause();
  //   vm.stopPrank();
  // }

  // function testSettlementOnlyMode_MultipleTransitions() public {
  //   // Test multiple transitions between states
  //   _fund(u1, 100 * ONE_COIN);
  //   _fund(u2, 100 * ONE_COIN);

  //   // Normal -> Settlement-only
  //   vm.startPrank(securityCouncil);
  //   mkt.pause();
  //   vm.stopPrank();

  //   // Give user tokens and try to deposit (should fail)
  //   deal(address(usdt), u1, 10 * ONE_COIN);
  //   vm.startPrank(u1);
  //   usdt.approve(address(mkt), type(uint256).max);
  //   vm.expectRevert(Errors.SettlementOnlyMode.selector);
  //   mkt.depositCollateral(10 * ONE_COIN);
  //   vm.stopPrank();

  //   // Settlement-only -> Normal
  //   vm.startPrank(securityCouncil);
  //   mkt.unpause();
  //   vm.stopPrank();

  //   assertEq(mkt.paused(), false);
  //   vm.startPrank(u1);
  //   mkt.depositCollateral(10 * ONE_COIN); // Should work
  //   vm.stopPrank();

  //   // Normal -> Full pause
  //   // vm.startPrank(securityCouncil);
  //   // mkt.pause();
  //   // vm.stopPrank();

  //   // assertTrue(mkt.paused());
  //   // deal(address(usdt), u1, 10 * ONE_COIN); // Give more tokens
  //   // vm.startPrank(u1);
  //   // usdt.approve(address(mkt), type(uint256).max);
  //   // vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
  //   // mkt.depositCollateral(10 * ONE_COIN);
  //   // vm.stopPrank();

  //   // Full pause -> Settlement-only (should remain paused since pause doesn't unpause)
  //   vm.startPrank(securityCouncil);
  //   mkt.pause();
  //   vm.stopPrank();

  //   assertTrue(mkt.paused()); // Should still be paused
  //   vm.startPrank(u1);
  //   // Should still get EnforcedPause error, not SettlementOnlyMode, because contract is still paused
  //   vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
  //   mkt.depositCollateral(10 * ONE_COIN);
  //   vm.stopPrank();

  //   // Back to normal
  //   vm.startPrank(securityCouncil);
  //   mkt.unpause();
  //   vm.stopPrank();

  //   assertEq(mkt.paused(), false);
  //   vm.startPrank(u1);
  //   mkt.depositCollateral(10 * ONE_COIN); // Should work
  //   vm.stopPrank();
  // }

  // function testSettlementOnlyMode_SettlementAutoStartsCycleWhenExiting() public {
  //   // Setup positions and expire cycle
  //   _fund(u1, 100 * ONE_COIN);
  //   _fund(u2, 100 * ONE_COIN);
  //   _openCallPair(u1, u2);

  //   uint256 currentCycleId = mkt.activeCycle();
  //   vm.warp(currentCycleId + 1);

  //   // Enter settlement-only mode
  //   vm.startPrank(securityCouncil);
  //   mkt.pause();
  //   vm.stopPrank();

  //   // Settlement should complete but not start new cycle
  //   mkt.settleChunk(100);
  //   assertEq(mkt.activeCycle(), 0, "no new cycle in settlement-only mode");

  //   // Exit settlement-only mode
  //   vm.startPrank(securityCouncil);
  //   mkt.unpause();
  //   vm.stopPrank();

  //   // Manually starting a cycle should work now
  //   mkt.startCycle();
  //   assertGt(mkt.activeCycle(), 0, "new cycle should start after exiting settlement-only mode");
  // }

  // function testSettlementOnlyMode_EventsEmitted() public {
  //   // Test that proper events are emitted during state transitions
  //   _fund(u1, 100 * ONE_COIN);
  //   _fund(u2, 100 * ONE_COIN);
  //   _openCallPair(u1, u2);

  //   uint256 currentCycleId = mkt.activeCycle();
  //   vm.warp(currentCycleId + 1);

  //   vm.startPrank(securityCouncil);

  //   // Enter settlement-only mode and record events
  //   vm.recordLogs();
  //   mkt.pause();
  //   Vm.Log[] memory pauseLogs = vm.getRecordedLogs();

  //   // Should emit Unpaused event if was paused
  //   bool foundUnpaused = false;
  //   for (uint256 i = 0; i < pauseLogs.length; i++) {
  //     if (pauseLogs[i].topics[0] == keccak256("Unpaused(address)")) {
  //       foundUnpaused = true;
  //       break;
  //     }
  //   }

  //   // Settlement should still work and emit proper events
  //   vm.recordLogs();
  //   mkt.settleChunk(100);
  //   Vm.Log[] memory settleLogs = vm.getRecordedLogs();

  //   // Should find CycleSettled event but not CycleStarted
  //   bool foundSettled = false;
  //   bool foundStarted = false;
  //   for (uint256 i = 0; i < settleLogs.length; i++) {
  //     if (settleLogs[i].topics[0] == keccak256("CycleSettled(uint256)")) foundSettled = true;
  //     if (settleLogs[i].topics[0] == keccak256("CycleStarted(uint256,uint256)")) foundStarted = true;
  //   }

  //   assertTrue(foundSettled, "CycleSettled event should be emitted");
  //   assertFalse(foundStarted, "CycleStarted event should NOT be emitted in settlement-only mode");

  //   // Exit settlement-only mode
  //   vm.recordLogs();
  //   mkt.unpause();
  //   Vm.Log[] memory unpauseLogs = vm.getRecordedLogs();

  //   // Should emit Unpaused event
  //   foundUnpaused = false;
  //   for (uint256 i = 0; i < unpauseLogs.length; i++) {
  //     if (unpauseLogs[i].topics[0] == keccak256("Unpaused(address)")) {
  //       foundUnpaused = true;
  //       break;
  //     }
  //   }

  //   vm.stopPrank();
  // }

  // function testSettlementOnlyMode_EdgeCaseNoCycleActive() public {
  //   // Test settlement-only mode when no cycle is active

  //   // First, settle any existing cycle and prevent auto-start
  //   uint256 currentCycleId = mkt.activeCycle();
  //   if (currentCycleId != 0) {
  //     // Set up some positions first so settlement actually happens
  //     _fund(u1, 100 * ONE_COIN);
  //     _fund(u2, 100 * ONE_COIN);
  //     _openCallPair(u1, u2);

  //     vm.warp(currentCycleId + 1);

  //     // Enable settlement-only mode BEFORE settling to prevent auto-start
  //     vm.startPrank(securityCouncil);
  //     mkt.pause();
  //     vm.stopPrank();

  //     mkt.settleChunk(100); // This should not auto-start a new cycle
  //   }

  //   assertEq(mkt.activeCycle(), 0, "no cycle should be active");

  //   // Settlement operations should revert with CycleNotStarted when no active cycle
  //   vm.expectRevert(Errors.CycleNotStarted.selector);
  //   mkt.settleChunk(100);

  //   // Starting a cycle should still be blocked
  //   vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
  //   mkt.startCycle();

  //   // Exit settlement-only mode and start new cycle
  //   vm.startPrank(securityCouncil);
  //   mkt.unpause();
  //   vm.stopPrank();

  //   mkt.startCycle();
  //   assertGt(mkt.activeCycle(), 0, "new cycle should start");
  // }

  // #######################################################################
  // #                                                                     #
  // #                    Bitscan and bitmap invariants                    #
  // #                                                                     #
  // #######################################################################

  function testFuzzBitmap(uint128 amount, uint8 priceTick, uint8 sideIndex) public {
    vm.assume(amount > 0 && amount < 1e6);
    vm.assume(sideIndex < 4);
    MarketSide side = MarketSide(sideIndex);
    uint256 price = uint256(priceTick) * TICK_SIZE + TICK_SIZE; // >=1 tick

    _fund(u1, 1e24);
    vm.startPrank(u1);
    mkt.placeOrder(side, amount, price, cycleId);

    uint32 tick = _tick(price);
    (uint8 l1, uint8 l2, uint8 l3) = BitScan.split(tick);

    // Test summary (L1) bitmap - should have bit l1 set
    assertTrue((mkt.summaries(uint256(side)) & BitScan.mask(l1)) != 0, "Summary bit not set");

    // Test mid (L2) bitmap - should have bit l2 set in mid[l1]
    assertTrue((mkt.mids(side, l1) & BitScan.mask(l2)) != 0, "Mid bit not set");

    // Test detail (L3) bitmap - should have bit l3 set in det[l1][l2]
    uint16 detKey = (uint16(l1) << 8) | l2;
    assertTrue((mkt.dets(side, detKey) & BitScan.mask(l3)) != 0, "Detail bit not set");

    // Test level volume
    uint32 key = _key(tick, _isPut(side), _isBuy(side));
    Level memory lvl = mkt.levels(key);
    assertEq(lvl.vol, amount, "Level volume mismatch");
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
  // #                   Liquidation Accounting Bug Tests                  #
  // #                                                                     #
  // #######################################################################

  function testLiquidationFromPriceFall_OrdersFilled() public {
    uint256 traderDeposit = 6 * ONE_COIN + 100000; // A bit extra to cover fees
    uint256 mmDeposit = 1_000 * ONE_COIN;

    int256 backendBalance;

    // fund accounts
    _fund(u1, traderDeposit); // will be liquidated
    _fund(u2, mmDeposit); // market-maker / liquidity

    backendBalance += int256(traderDeposit);

    // ---------------------------------------------------------------------
    // 1.  Provide resting liquidity so u1's `long()` market order executes
    // ---------------------------------------------------------------------
    vm.startPrank(u2);
    uint256 premiumPrice = 10000;
    uint256 orderSize = 5;
    mkt.placeOrder(MarketSide.CALL_SELL, orderSize, premiumPrice, 0); // ask
    mkt.placeOrder(MarketSide.PUT_BUY, orderSize, premiumPrice, 0); // bid
    vm.stopPrank();

    // record initial balance & open long
    uint256 balBefore = mkt.getUserAccount(u1).balance;
    vm.startPrank(u1);
    vm.recordLogs();
    mkt.long(orderSize, 0, 0, 0); // market order
    Vm.Log[] memory lg = vm.getRecordedLogs();
    vm.stopPrank();

    //  premium legs net to zero -> only taker fees are paid (2×0.07 USDT)
    uint256 fee = 2 * orderSize * premiumPrice * uint256(TAKER_FEE_BPS) / 10_000; // 2x for buyCall and sellPut
    assertEq(mkt.getUserAccount(u1).balance, balBefore - fee, "post-trade balance incorrect");
    backendBalance += _getCashTakerFromLimitOrderFilledEvents(lg);
    assertEq(uint256(backendBalance), mkt.getUserAccount(u1).balance, "backend balance incorrect");

    // ---------------------------------------------------------------------
    // 2.  BTC price dumps -> u1 short-put deeply ITM -> liquidatable
    // ---------------------------------------------------------------------
    _mockOracle(btcPrice - 15_000);
    assertTrue(mkt.isLiquidatable(u1), "should be liquidatable after price fall");

    //  liquidity that will INSTANTLY close the puts inside `liquidate`
    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.PUT_SELL, 5, premiumPrice, 0);
    vm.stopPrank();

    // ---------------------------------------------------------------------
    // 3.  Liquidate (orders are FILLED, no queue left)
    // ---------------------------------------------------------------------
    vm.startPrank(owner);
    balBefore = mkt.getUserAccount(u1).balance;
    vm.recordLogs();
    mkt.liquidate(u1);
    lg = vm.getRecordedLogs();
    vm.stopPrank();

    fee = orderSize * premiumPrice * uint256(TAKER_FEE_BPS) / 10_000; // 2x for buyCall and sellPut

    assertEq(
      mkt.getUserAccount(u1).balance, balBefore - fee - (premiumPrice * orderSize), "balance after liquidation wrong"
    );

    uint256 liqFeeOwed = _getLiquidationFeeOwed(lg);
    backendBalance = 0; // We have to manually set to zero in backend

    //   liquidation flags
    MarketWithViews.UserAccount memory ua = mkt.getUserAccount(u1);
    assertFalse(ua.liquidationQueued, "liq flag should be cleared");
    assertEq(ua.liquidationFeeOwed, liqFeeOwed, "liquidationFeeOwed should be equal to liquidation fee owed");

    //   no remaining queued PUT-buys
    (TakerQ[] memory q) = mkt.viewTakerQueue(MarketSide.PUT_BUY);
    uint256 head = mkt.getTqHead(uint256(MarketSide.PUT_BUY));
    bool empty = q.length == 0 || head >= q.length || q[head].size == 0;
    assertTrue(empty, "taker queue should be empty");

    // Go to settlement
    vm.warp(cycleId + 1);
    vm.recordLogs();
    mkt.settleChunk(100, false);
    lg = vm.getRecordedLogs();

    uint256 liqFeePaid = _getLiquidationFeePaid(lg);

    // The liquidation fee we recoup will be less than that first calculated, as we wait until after taker fees +
    // premiums are paid
    assertEq(
      liqFeePaid,
      liqFeeOwed - fee - (premiumPrice * orderSize),
      "liquidation fee paid should be equal to liquidation fee owed"
    );

    // Check user doesn't get any pnl on settlement. In this case, as liquidation orders are filled, pnl should be zero
    int256 pnl = _getPnl(lg, u1);
    assertEq(pnl, 0, "pnl should be zero");
  }

  function testLiquidationFromPriceFall_OrdersUnfilled() public {
    uint256 traderDeposit = 6 * ONE_COIN + 100_000; // same as "filled" test
    uint256 mmDeposit = 1_000 * ONE_COIN;

    // ---------------------------------------------------------------------
    // 0. Fund & provide liquidity so the LONG opens
    // ---------------------------------------------------------------------
    _fund(u1, traderDeposit); // will be liquidated
    _fund(u2, mmDeposit); // market-maker / liquidity

    vm.startPrank(u2);
    uint256 premiumPrice = 10_000; // 0.01 USDT premium-per-leg
    uint256 orderSize = 5; // contracts
    mkt.placeOrder(MarketSide.CALL_SELL, orderSize, premiumPrice, 0); // ask
    mkt.placeOrder(MarketSide.PUT_BUY, orderSize, premiumPrice, 0); // bid
    vm.stopPrank();

    // u1 hits the book -> long CALL, short PUT
    vm.startPrank(u1);
    mkt.long(orderSize, 0, 0, 0); // market order
    vm.stopPrank();

    // ---------------------------------------------------------------------
    // 1.  Price dumps —> u1 is liquidatable
    // ---------------------------------------------------------------------
    _mockOracle(btcPrice - 15_000);
    assertTrue(mkt.isLiquidatable(u1), "should be liquidatable after price fall");

    // ---------------------------------------------------------------------
    // 2.  Liquidate WITHOUT providing offsetting PUT-SELL liquidity
    // ---------------------------------------------------------------------
    uint256 balBeforeLiq = mkt.getUserAccount(u1).balance;

    vm.startPrank(owner);
    mkt.liquidate(u1); // leaves 5 x PUT-BUY in taker-queue
    vm.stopPrank();

    // After liquidation: flag set, fee owed recorded, queue holds 5 contracts
    MarketWithViews.UserAccount memory uaAfterLiq = mkt.getUserAccount(u1);
    assertTrue(uaAfterLiq.liquidationQueued, "liq flag should be set (orders unfilled)");
    assertEq(uaAfterLiq.liquidationFeeOwed, balBeforeLiq, "liqFeeOwed must equal current balance");

    (TakerQ[] memory q1) = mkt.viewTakerQueue(MarketSide.PUT_BUY);
    assertEq(q1.length, 1, "one queue entry expected");
    assertEq(q1[0].size, orderSize, "queued size wrong");

    // ---------------------------------------------------------------------
    // 3.  Fast-forward to expiry and settle – queue still unfilled
    // ---------------------------------------------------------------------
    vm.warp(cycleId + 1);
    vm.recordLogs();
    mkt.settleChunk(100, false); // run both phases in one call
    Vm.Log[] memory logs = vm.getRecordedLogs();

    // a) liquidation fee was paid in full to feeRecipient
    uint256 liqFeePaid = _getLiquidationFeePaid(logs);
    assertEq(liqFeePaid, balBeforeLiq, "fee recipient should seize full balance");

    // b) user keeps nothing, flags are cleared
    MarketWithViews.UserAccount memory uaFinal = mkt.getUserAccount(u1);
    assertEq(uaFinal.balance, 0, "user balance must be zero");
    assertFalse(uaFinal.liquidationQueued, "liq flag should be cleared");
    assertEq(uaFinal.liquidationFeeOwed, 0, "liqFeeOwed should be zeroed");

    // c) PnL event for liquidated user must be zero
    int256 pnl = _getPnl(logs, u1);
    assertEq(pnl, 0, "liquidated user should record zero pnl");

    // d) settlement wiped the taker queue
    (TakerQ[] memory qFinal) = mkt.viewTakerQueue(MarketSide.PUT_BUY);
    assertTrue(qFinal.length == 0, "queue should be cleared after settlement");
  }

  function testLiquidationFromPricePump_OrdersFilled() public {
    uint256 traderDeposit = 6 * ONE_COIN + 100_000; // u1 – will be liquidated
    uint256 mmDeposit = 1_000 * ONE_COIN; // u2 – liquidity provider

    int256 backendBalance;

    // ---------------------------------------------------------------------
    // 0.  Fund users
    // ---------------------------------------------------------------------
    _fund(u1, traderDeposit);
    _fund(u2, mmDeposit);
    backendBalance += int256(traderDeposit);

    // ---------------------------------------------------------------------
    // 1.  Provide resting liquidity so u1's `short()` market order executes
    //     short() = PUT_BUY  + CALL_SELL
    //               (taker)     (taker)
    // ---------------------------------------------------------------------
    vm.startPrank(u2);
    uint256 premiumPrice = 10_000; // 0.01 USDT0
    uint256 orderSize = 5;
    mkt.placeOrder(MarketSide.PUT_SELL, orderSize, premiumPrice, 0); // ask
    mkt.placeOrder(MarketSide.CALL_BUY, orderSize, premiumPrice, 0); // bid
    vm.stopPrank();

    // record logs & open the short pair
    uint256 balBefore = mkt.getUserAccount(u1).balance;
    vm.startPrank(u1);
    vm.recordLogs();
    mkt.short(orderSize, 0, 0, 0); // market order
    Vm.Log[] memory lg = vm.getRecordedLogs();
    vm.stopPrank();

    // taker fees on two legs
    uint256 fee = 2 * orderSize * premiumPrice * uint256(TAKER_FEE_BPS) / 10_000;
    assertEq(mkt.getUserAccount(u1).balance, balBefore - fee, "post-trade balance incorrect");

    backendBalance += _getCashTakerFromLimitOrderFilledEvents(lg);
    assertEq(uint256(backendBalance), mkt.getUserAccount(u1).balance, "backend sync failed");

    // ---------------------------------------------------------------------
    // 2.  BTC price **pumps** – u1 short-CALLs are now deep ITM
    // ---------------------------------------------------------------------
    _mockOracle(btcPrice + 15_000);
    assertTrue(mkt.isLiquidatable(u1), "should be liquidatable after price pump");

    //   Liquidity that will IMMEDIATELY offset the short-CALLs in `liquidate`
    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.CALL_SELL, orderSize, premiumPrice, 0); // ask side for the CALL_BUY liquidator order
    vm.stopPrank();

    // ---------------------------------------------------------------------
    // 3.  Liquidate (orders are FILLED, queue empty)
    // ---------------------------------------------------------------------
    vm.startPrank(owner);
    balBefore = mkt.getUserAccount(u1).balance;
    vm.recordLogs();
    mkt.liquidate(u1);
    lg = vm.getRecordedLogs();
    vm.stopPrank();

    fee = orderSize * premiumPrice * uint256(TAKER_FEE_BPS) / 10_000; // just one liquidator taker leg
    assertEq(
      mkt.getUserAccount(u1).balance, balBefore - fee - (premiumPrice * orderSize), "balance after liquidation wrong"
    );

    uint256 liqFeeOwed = _getLiquidationFeeOwed(lg);
    backendBalance = 0; // backend balance wiped on our side

    //   no liquidation flag, fee owed recorded
    MarketWithViews.UserAccount memory ua = mkt.getUserAccount(u1);
    assertFalse(ua.liquidationQueued, "liq flag should be cleared");
    assertEq(ua.liquidationFeeOwed, liqFeeOwed, "liqFeeOwed mismatch");

    //   CALL-BUY taker queue must be empty
    (TakerQ[] memory q) = mkt.viewTakerQueue(MarketSide.CALL_BUY);
    uint256 head = mkt.getTqHead(uint256(MarketSide.CALL_BUY));
    bool empty = q.length == 0 || head >= q.length || q[head].size == 0;
    assertTrue(empty, "taker queue not empty");

    // ---------------------------------------------------------------------
    // 4.  Fast-forward to expiry and settle
    // ---------------------------------------------------------------------
    vm.warp(cycleId + 1);
    vm.recordLogs();
    mkt.settleChunk(100, false); // both phases
    lg = vm.getRecordedLogs();

    uint256 liqFeePaid = _getLiquidationFeePaid(lg);
    // liquidation-fee paid = fee owed – (premium + takerFee) consumed inside liquidate
    assertEq(liqFeePaid, liqFeeOwed - fee - (premiumPrice * orderSize), "liquidation fee paid incorrect");

    // liquidated trader should get **zero** pnl
    int256 pnl = _getPnl(lg, u1);
    assertEq(pnl, 0, "pnl should be zero for liquidated trader");
  }

  function testLiquidationFromPricePump_OrdersUnfilled() public {
    // ---------------------------------------------------------------------
    // 0.  Fund accounts
    // ---------------------------------------------------------------------
    uint256 traderDeposit = 6 * ONE_COIN + 100_000; // will be liquidated
    uint256 mmDeposit = 1_000 * ONE_COIN; // maker / liquidity
    _fund(u1, traderDeposit);
    _fund(u2, mmDeposit);

    int256 backendBalance = int256(traderDeposit);

    // ---------------------------------------------------------------------
    // 1.  u1 opens a SHORT pair (CALL_SELL + PUT_BUY) against u2 liquidity
    // ---------------------------------------------------------------------
    vm.startPrank(u2);
    uint256 premiumPrice = 10_000; // 0.01 USDT0
    uint256 orderSize = 5;
    mkt.placeOrder(MarketSide.PUT_SELL, orderSize, premiumPrice, 0); // ask
    mkt.placeOrder(MarketSide.CALL_BUY, orderSize, premiumPrice, 0); // bid
    vm.stopPrank();

    uint256 balBefore = mkt.getUserAccount(u1).balance;
    vm.startPrank(u1);
    vm.recordLogs();
    mkt.short(orderSize, 0, 0, 0); // market order
    Vm.Log[] memory lg = vm.getRecordedLogs();
    vm.stopPrank();

    // taker fees on both legs
    uint256 fee = 2 * orderSize * premiumPrice * uint256(TAKER_FEE_BPS) / 10_000;
    assertEq(mkt.getUserAccount(u1).balance, balBefore - fee, "post-trade balance wrong");

    backendBalance += _getCashTakerFromLimitOrderFilledEvents(lg);
    assertEq(uint256(backendBalance), mkt.getUserAccount(u1).balance, "backend sync failed");

    // ---------------------------------------------------------------------
    // 2.  BTC price PUMPS  → u1 short-CALLs deep ITM → liquidatable
    // ---------------------------------------------------------------------
    _mockOracle(btcPrice + 15_000);
    assertTrue(mkt.isLiquidatable(u1), "should be liquidatable after pump");

    // *** NO liquidity is added on the ask side ***
    //     → the CALL_BUY orders created inside `liquidate` will sit in queue

    // ---------------------------------------------------------------------
    // 3.  Liquidate – orders go to taker-queue (UNFILLED)
    // ---------------------------------------------------------------------
    vm.startPrank(owner);
    vm.recordLogs();
    mkt.liquidate(u1);
    lg = vm.getRecordedLogs();
    vm.stopPrank();

    uint256 liqFeeOwed = _getLiquidationFeeOwed(lg);
    assertEq(liqFeeOwed, mkt.getUserAccount(u1).balance, "liqFeeOwed != remaining balance");

    // Liquidation flag must still be set (positions not yet closed)
    assertTrue(mkt.getUserAccount(u1).liquidationQueued, "liq flag should stay true");

    // Queued CALL-BUY must exist for u1
    (TakerQ[] memory q) = mkt.viewTakerQueue(MarketSide.CALL_BUY);
    uint256 head = mkt.getTqHead(uint256(MarketSide.CALL_BUY));
    assertGt(q.length, 0, "queue empty");
    assertEq(q[head].trader, u1, "queue head not u1");
    assertEq(q[head].size, orderSize, "queued size wrong");

    // ---------------------------------------------------------------------
    // 4.  Fast-forward to expiry and run settlement (no one ever filled)
    // ---------------------------------------------------------------------
    vm.warp(cycleId + 1);
    vm.recordLogs();
    mkt.settleChunk(100, false); // phase-1 + phase-2
    lg = vm.getRecordedLogs();

    // Entire balance seized as liquidation fee
    uint256 liqFeePaid = _getLiquidationFeePaid(lg);
    assertEq(liqFeePaid, liqFeeOwed, "liqFeePaid mismatch");
    assertEq(mkt.getUserAccount(u1).balance, 0, "u1 balance should be zero");

    // Settled event for u1 must carry 0 PnL
    int256 pnl = _getPnl(lg, u1);
    assertEq(pnl, 0, "pnl should be zero for liquidated trader");

    // Flags & fee-owed cleared after settlement
    MarketWithViews.UserAccount memory ua = mkt.getUserAccount(u1);
    assertFalse(ua.liquidationQueued, "liq flag not cleared post-settlement");
    assertEq(ua.liquidationFeeOwed, 0, "liqFeeOwed not cleared");

    // Queue entry should now be consumed / ignored
    (TakerQ[] memory qAfter) = mkt.viewTakerQueue(MarketSide.CALL_BUY);
    uint256 h2 = mkt.getTqHead(uint256(MarketSide.CALL_BUY));
    bool empty = qAfter.length == 0 || h2 >= qAfter.length || qAfter[h2].size == 0;
    assertTrue(empty, "queue should be empty after settlement");
  }

  /// @dev   Liquidation caused only by premium over-payment on a LIMIT long().
  ///        After liquidation the protocol (feeSink) must hold the seized
  ///        long CALLs.
  function testLiquidationFromPremiumOverpayment_Long() public {
    uint256 MM_BPS = 10;
    uint256 denominator = 10000;
    uint256 TAKER_FEE_BPS = 700;

    //------------------------------------------------------------
    // 0.  Constants & helpers
    //------------------------------------------------------------
    uint256 orderSize = 5; // contracts
    uint256 callAskPrice = 1 * ONE_COIN; // 1 USDT premium per CALL
    uint256 putBidPrice = 100; // 0.0001 USDT per PUT
    uint64 strike = uint64(btcPrice * 1e6); // strike == spot

    // maintenance-margin on 5 short-PUTs at strike:  0.1 % × (5 × strike /100)
    uint256 mmNeeded = (orderSize * strike / CONTRACT_SIZE) * MM_BPS / denominator; // ≈ 5 USDT

    // deposit JUST enough to satisfy margin **before** the trade,
    // plus the premium that will later be paid (callAskPrice*5) and taker fees
    uint256 premiumPay = orderSize * callAskPrice; // 5.000000
    uint256 takerFeeCall = premiumPay * TAKER_FEE_BPS / denominator; // 0.350000
    uint256 deposit = premiumPay + takerFeeCall + mmNeeded + 1; // ≈ 10.4 USDT

    //------------------------------------------------------------
    // 1.  Fund accounts, place long, and match liquidity
    //------------------------------------------------------------
    _fund(u1, deposit); // will be liquidated
    _fund(u2, 1_000 * ONE_COIN); // liquidity provider

    // 1-A.  u1 places a LIMIT long() that **rests**
    vm.startPrank(u1);
    mkt.long(
      orderSize,
      callAskPrice, // limit price for CALL buy
      putBidPrice, // limit price for PUT sell
      0 // current cycle
    );
    vm.stopPrank();

    // at this point nothing is filled → account is still solvent
    assertFalse(mkt.isLiquidatable(u1), "should be solvent while order resting");

    // 1-B.  u2 now crosses the book – fills both CALL & PUT legs
    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.CALL_SELL, orderSize, callAskPrice, 0); // crosses CALL bid
    mkt.placeOrder(MarketSide.PUT_BUY, orderSize, putBidPrice, 0); // crosses PUT ask
    vm.stopPrank();

    //------------------------------------------------------------
    // 2.  Premium was paid
    //------------------------------------------------------------
    assertFalse(mkt.isLiquidatable(u1), "u1 not liquidatable yet after fill");

    _mockOracle(btcPrice - 15_000);
    assertTrue(mkt.isLiquidatable(u1), "u1 must be liquidatable after adverse price move");

    //------------------------------------------------------------
    // 3.  Provide minimal PUT-SELL liquidity so the liquidation  *
    //     closes the net-short PUTs instantly                     *
    //------------------------------------------------------------
    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.PUT_SELL, orderSize, putBidPrice, 0);
    vm.stopPrank();

    //------------------------------------------------------------
    // 4.  Liquidate u1
    //------------------------------------------------------------
    uint32 longCallsBefore = mkt.getUserAccount(feeSink).longCalls;
    uint256 balanceBefore = mkt.getUserAccount(u1).balance;

    vm.startPrank(owner);
    mkt.liquidate(u1);
    vm.stopPrank();

    //------------------------------------------------------------
    // 5.  Assertions
    //------------------------------------------------------------
    MarketWithViews.UserAccount memory ua = mkt.getUserAccount(u1);

    //  a) flag cleared (orders filled, no queue left)
    assertFalse(ua.liquidationQueued, "liq flag should be cleared");

    //  b) protocol now owns the user's confiscated long CALLs
    uint32 longCallsAfter = mkt.getUserAccount(feeSink).longCalls;
    assertEq(longCallsAfter - longCallsBefore, uint32(orderSize), "protocol did not seize long CALLs");

    //  c) user still has balance, as its confiscated in settlement
    uint256 liqPremiumPay = orderSize * putBidPrice;
    assertEq(
      ua.balance,
      balanceBefore - liqPremiumPay - liqPremiumPay * TAKER_FEE_BPS / denominator,
      "user balance should be confiscated"
    );

    //  d) PUT-BUY taker queue empty
    (TakerQ[] memory q) = mkt.viewTakerQueue(MarketSide.PUT_BUY);
    uint256 head = mkt.getTqHead(uint256(MarketSide.PUT_BUY));
    bool empty = q.length == 0 || head >= q.length || q[head].size == 0;
    assertTrue(empty, "taker queue should be empty");

    //------------------------------------------------------------
    // 6.  Pump price ABOVE strike *before* expiry so seized CALLs are ITM
    //------------------------------------------------------------
    _mockOracle(btcPrice + 20_000); // spot = strike + 20 000

    // fast-forward one second past expiry
    vm.warp(cycleId + 1);

    //------------------------------------------------------------
    // 7.  Run settlement & capture events
    //------------------------------------------------------------
    vm.recordLogs();
    mkt.settleChunk(1000, false); // single-shot completion
    Vm.Log[] memory logs = vm.getRecordedLogs();

    //------------------------------------------------------------
    // 8.  Post-settlement checks
    //------------------------------------------------------------
    // (a) liquidated user balance & flags
    assertEq(mkt.getUserAccount(u1).balance, 0, "user balance must be 0");
    assertEq(mkt.getUserAccount(u1).liquidationFeeOwed, 0, "liq fee owed should be cleared");

    // (b) event decoding
    bool seenFeeSinkSettle;
    bool seenUserSettle;
    bool seenLiqFee;
    int256 pnlFeeSink;
    int256 pnlUser;
    uint256 liqFeeAmt;

    bytes32 SETTLED_SIG = keccak256("Settled(uint256,address,int256)");
    bytes32 LIQ_FEE_SIG = keccak256("LiquidationFeePaid(uint256,address,uint256)");

    for (uint256 i; i < logs.length; ++i) {
      // Settled(...)
      if (logs[i].topics[0] == SETTLED_SIG) {
        address trader = address(uint160(uint256(logs[i].topics[2])));
        int256 pnl = abi.decode(logs[i].data, (int256));
        if (trader == feeSink) {
          seenFeeSinkSettle = true;
          pnlFeeSink = pnl;
        }
        if (trader == u1) {
          seenUserSettle = true;
          pnlUser = pnl;
        }
      }
      // LiquidationFeePaid(...)
      if (logs[i].topics[0] == LIQ_FEE_SIG && address(uint160(uint256(logs[i].topics[2]))) == u1) {
        seenLiqFee = true;
        liqFeeAmt = abi.decode(logs[i].data, (uint256));
      }
    }

    require(seenFeeSinkSettle, "feeSink Settled evt missing");
    require(seenUserSettle, "user Settled evt missing");
    require(seenLiqFee, "LiquidationFeePaid evt missing");

    // (c) feeSink PnL  = intrinsic of 5 long-CALLs, 20 000 USDT ITM
    uint256 priceDiff = 20_000 * ONE_COIN; // 20 000 USDT (6-dp)
    uint256 expectedPnL = priceDiff * orderSize / CONTRACT_SIZE; // 1 000 USDT
    assertEq(uint256(pnlFeeSink), expectedPnL, "feeSink PnL mismatch");

    //     liquidated user gets zero PnL
    assertEq(pnlUser, 0, "user PnL should be zero");

    // (d) liquidation fee paid equals the balance we observed pre-settlement
    uint256 expectedLiqFee = ua.balance; // 'ua' captured before settlement
    assertEq(liqFeeAmt, expectedLiqFee, "liq fee amount mismatch");
  }

  function testLiquidationFromPremiumOverpayment_Short() public {}

  function testLiquidationFeeNotZeroedBug() public {
    uint256 collateral = 2 * ONE_COIN;
    _fund(u1, collateral);
    _fund(u2, 1000 * ONE_COIN);

    // u1 goes short calls
    uint256 currentCycleId = mkt.activeCycle();
    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.CALL_BUY, 1, ONE_COIN, currentCycleId);
    vm.stopPrank();
    vm.startPrank(u1);
    mkt.placeOrder(MarketSide.CALL_SELL, 1, ONE_COIN, currentCycleId);
    vm.stopPrank();

    // Price pumps, u1 becomes liquidatable
    _mockOracle(btcPrice + 20000);

    // Liquidate u1
    vm.startPrank(owner);
    mkt.liquidate(u1);
    vm.stopPrank();

    // Provide liquidity to close the liquidation order
    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.CALL_SELL, 1, 5000 * ONE_COIN, currentCycleId);
    vm.stopPrank();

    // Fast forward to settlement
    vm.warp(currentCycleId + 1);

    // Get liquidation fee owed before settlement
    uint64 liquidationFeeOwed = mkt.getUserAccount(u1).liquidationFeeOwed;
    console.log("Liquidation fee owed before settlement:", liquidationFeeOwed);

    // Settlement
    vm.startPrank(owner);
    mkt.settleChunk(100, false); // Use larger chunk to complete in one call
    vm.stopPrank();

    // Check that liquidationFeeOwed is zeroed
    uint64 liquidationFeeOwedAfter = mkt.getUserAccount(u1).liquidationFeeOwed;
    console.log("Liquidation fee owed after settlement:", liquidationFeeOwedAfter);

    assertEq(liquidationFeeOwedAfter, 0, "LiquidationFeeOwed should be zero after settlement");
  }

  function testLiquidationEventEmissionBug() public {
    uint256 collateral = 2 * ONE_COIN;
    _fund(u1, collateral);
    _fund(u2, 1000 * ONE_COIN);

    uint256 currentCycleId = mkt.activeCycle();
    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.CALL_BUY, 1, ONE_COIN, currentCycleId);
    vm.stopPrank();
    vm.startPrank(u1);
    mkt.placeOrder(MarketSide.CALL_SELL, 1, ONE_COIN, currentCycleId);
    vm.stopPrank();

    // Price pumps, u1 becomes liquidatable
    _mockOracle(btcPrice + 20000);

    // Liquidate u1
    vm.startPrank(owner);
    mkt.liquidate(u1);
    vm.stopPrank();

    uint256 balanceBeforeFill = mkt.getUserAccount(u1).balance;
    console.log("u1 balance before fill:", balanceBeforeFill);

    // Record events during liquidation fill
    vm.recordLogs();

    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.CALL_SELL, 1, 5 * ONE_COIN, currentCycleId); // More than u1 can afford
    vm.stopPrank();

    Vm.Log[] memory entries = vm.getRecordedLogs();

    // Find the LimitOrderFilled event from the liquidation
    int256 emittedCashTaker = _getCashTakerFromLimitOrderFilledEvents(entries);

    // hacky but assume non-zero means we found event
    assertTrue(emittedCashTaker != 0, "LimitOrderFilled event should be emitted for liquidation");

    uint256 balanceAfterFill = mkt.getUserAccount(u1).balance;
    console.log("u1 balance after fill:", balanceAfterFill);
    console.log("Emitted cashTaker:", emittedCashTaker);

    // Calculate the theoretical vs actual payment
    uint256 theoreticalCost = 5 * ONE_COIN + (5 * ONE_COIN * 700 / 10000);
    uint256 actualPaid = balanceBeforeFill; // We cap premium paid to user's balance

    console.log("Theoretical cost (5 USDC + fee):", theoreticalCost);
    console.log("Actual amount paid:", actualPaid);
    console.log("User had insufficient funds?", actualPaid < theoreticalCost);

    if (actualPaid < theoreticalCost && balanceAfterFill == 0) {
      int256 expectedCashTaker = -int256(actualPaid);
      console.log("Expected cashTaker (actual paid):", expectedCashTaker);

      if (emittedCashTaker == expectedCashTaker) console.log("ISSUE 2 FIXED: Event correctly shows actual amount paid");
      else console.log("BUG: Event shows theoretical amount instead of actual amount paid");

      assertEq(
        emittedCashTaker,
        expectedCashTaker,
        "Event should show actual amount paid by insolvent user, not theoretical amount"
      );
    } else {
      console.log("No insolvency scenario created - test needs adjustment");
    }
  }

  function testLongShortLiquidationZeroBalance() public {
    // Setup: Fund both users with different collateral amounts
    uint256 user1Collateral = 15 * ONE_COIN; // User 1 - less collateral, will be liquidated
    uint256 user2Collateral = 100 * ONE_COIN; // User 2 - more collateral, counterparty

    _fund(u1, user1Collateral);
    _fund(u2, user2Collateral);

    uint256 currentCycleId = mkt.activeCycle();
    uint256 callBuyPrice = 4 * ONE_COIN; // 4 USDT for calls
    uint256 callSellPrice = 3 * ONE_COIN; // 3 USDT for calls (lower, so orders will cross)
    uint256 putBuyPrice = 2 * ONE_COIN; // 2 USDT for puts
    uint256 putSellPrice = 1 * ONE_COIN; // 1 USDT for puts (lower, so orders will cross)
    uint256 orderSize = 3; // 3 contracts

    // User 1 goes LONG (long calls + short puts) with higher call price and lower put price
    vm.startPrank(u1);
    mkt.long(orderSize, callBuyPrice, putSellPrice, currentCycleId);
    vm.stopPrank();

    // User 2 goes SHORT (short calls + long puts) with lower call price and higher put price
    // This creates cross-priced orders that will execute against User 1's orders
    vm.startPrank(u2);
    vm.recordLogs();
    mkt.short(orderSize, putBuyPrice, callSellPrice, currentCycleId);
    Vm.Log[] memory initialTradeLogs = vm.getRecordedLogs();
    vm.stopPrank();

    // Verify LimitOrderFilled events were emitted for initial cross-priced trades
    uint256 initialFillCount = _countLimitOrderFilledEvents(initialTradeLogs);
    console.log("Initial trade LimitOrderFilled events:", initialFillCount);
    assertEq(initialFillCount, 2, "Should have 2 LimitOrderFilled events for call and put trades");

    // Verify positions after trade
    MarketWithViews.UserAccount memory ua1 = mkt.getUserAccount(u1);
    MarketWithViews.UserAccount memory ua2 = mkt.getUserAccount(u2);

    assertEq(ua1.longCalls, orderSize, "User 1 should have long calls");
    assertEq(ua1.shortPuts, orderSize, "User 1 should have short puts");
    assertEq(ua2.shortCalls, orderSize, "User 2 should have short calls");
    assertEq(ua2.longPuts, orderSize, "User 2 should have long puts");

    // Record balances after trade
    uint256 u1BalanceAfterTrade = ua1.balance;
    uint256 u2BalanceAfterTrade = ua2.balance;

    console.log("u1 balance after trade:", u1BalanceAfterTrade);
    console.log("u2 balance after trade:", u2BalanceAfterTrade);

    // BTC price dumps significantly, making User 1 (short puts) liquidatable
    _mockOracle(btcPrice - 20_000); // -20k makes short puts deeply ITM

    // Verify User 1 is now liquidatable
    assertTrue(mkt.isLiquidatable(u1), "User 1 should be liquidatable after price dump");
    assertFalse(mkt.isLiquidatable(u2), "User 2 should not be liquidatable");

    // Record User 1's balance before liquidation
    uint256 u1BalanceBeforeLiq = mkt.getUserAccount(u1).balance;
    console.log("u1 balance before liquidation:", u1BalanceBeforeLiq);

    // Liquidate User 1
    vm.startPrank(owner);
    mkt.liquidate(u1);
    vm.stopPrank();

    // Check liquidation state
    ua1 = mkt.getUserAccount(u1);
    assertTrue(ua1.liquidationQueued, "User 1 should have liquidation queued");
    console.log("u1 liquidation fee owed:", ua1.liquidationFeeOwed);
    console.log("u1 balance after liquidation (before settlement):", ua1.balance);

    // Provide liquidity to fill the liquidation orders
    // User 1's liquidation will create market orders to close their net short puts
    vm.startPrank(u2);
    vm.recordLogs();
    mkt.placeOrder(MarketSide.PUT_SELL, orderSize, 10 * ONE_COIN, currentCycleId); // High price to ensure fill
    Vm.Log[] memory liquidationFillLogs = vm.getRecordedLogs();
    vm.stopPrank();

    // Verify LimitOrderFilled event was emitted for liquidation order fill
    uint256 liquidationFillCount = _countLimitOrderFilledEvents(liquidationFillLogs);
    console.log("Liquidation order LimitOrderFilled events:", liquidationFillCount);
    assertEq(liquidationFillCount, 1, "Should have 1 LimitOrderFilled event for liquidation order fill");

    // Verify User 1's balance is now 0 after liquidation order execution
    ua1 = mkt.getUserAccount(u1);
    assertEq(ua1.balance, 0, "User 1 balance should be 0 after liquidation order execution");
    console.log("u1 balance after liquidation order filled:", ua1.balance);

    // Fast forward to settlement
    vm.warp(currentCycleId + 1);
    _mockOracle(btcPrice - 20_000); // Keep same settlement price

    // Record events during settlement
    vm.recordLogs();
    mkt.settleChunk(100, false);
    Vm.Log[] memory settlementLogs = vm.getRecordedLogs();

    // Check if LiquidationFeePaid event was emitted for User 1
    // Note: This event is only emitted if the user has balance > 0 during settlement
    // In this case, the user's balance was consumed by liquidation order execution
    bool foundLiquidationFeePaid = false;
    uint256 liquidationFeePaid = 0;

    for (uint256 i = 0; i < settlementLogs.length; i++) {
      if (settlementLogs[i].topics[0] == keccak256("LiquidationFeePaid(uint256,address,uint256)")) {
        address liquidatedUser = address(uint160(uint256(settlementLogs[i].topics[2])));
        if (liquidatedUser == u1) {
          foundLiquidationFeePaid = true;
          (liquidationFeePaid) = abi.decode(settlementLogs[i].data, (uint256));
          break;
        }
      }
    }

    // In this test case, the liquidation order consumed the user's entire balance,
    // so no LiquidationFeePaid event should be emitted during settlement
    assertFalse(
      foundLiquidationFeePaid,
      "LiquidationFeePaid event should NOT be emitted when balance was consumed by liquidation orders"
    );
    console.log("Liquidation fee paid during settlement:", liquidationFeePaid);

    // Verify User 1's final state after settlement
    ua1 = mkt.getUserAccount(u1);
    assertEq(ua1.balance, 0, "User 1 balance should be 0 after settlement");
    assertEq(ua1.liquidationFeeOwed, 0, "User 1 liquidation fee owed should be 0 after settlement");
    assertFalse(ua1.liquidationQueued, "User 1 liquidation should no longer be queued");

    // Verify all positions are cleared for User 1
    assertEq(ua1.longCalls, 0, "User 1 long calls should be 0");
    assertEq(ua1.shortCalls, 0, "User 1 short calls should be 0");
    assertEq(ua1.longPuts, 0, "User 1 long puts should be 0");
    assertEq(ua1.shortPuts, 0, "User 1 short puts should be 0");

    console.log("Final u1 balance:", ua1.balance);
    console.log("Final u1 liquidation fee owed:", ua1.liquidationFeeOwed);
    console.log("Final u1 liquidation queued:", ua1.liquidationQueued);

    // Check fee recipient balance after settlement
    uint256 feeRecipientBalance = mkt.getUserAccount(feeSink).balance;
    console.log("Fee recipient balance after settlement:", feeRecipientBalance);

    // In this case, the liquidation was handled through trade execution,
    // not through settlement transfer, so fee recipient gets trading fees

    // Verify User 2 has positive balance after settlement (positions are cleared during settlement)
    ua2 = mkt.getUserAccount(u2);
    assertGt(ua2.balance, 0, "User 2 should still have positive balance");
    // Note: All positions are cleared during settlement for all users
    assertEq(ua2.shortCalls, 0, "User 2 positions should be cleared after settlement");
    assertEq(ua2.longPuts, 0, "User 2 positions should be cleared after settlement");
  }

  function testLongShortLiquidationZeroBalanceNoLiquidity() public {
    // Setup: Fund both users with different collateral amounts
    uint256 user1Collateral = 15 * ONE_COIN; // User 1 - less collateral, will be liquidated
    uint256 user2Collateral = 100 * ONE_COIN; // User 2 - more collateral, counterparty

    _fund(u1, user1Collateral);
    _fund(u2, user2Collateral);

    uint256 currentCycleId = mkt.activeCycle();
    uint256 callBuyPrice = 4 * ONE_COIN; // 4 USDT for calls
    uint256 callSellPrice = 3 * ONE_COIN; // 3 USDT for calls (lower, so orders will cross)
    uint256 putBuyPrice = 2 * ONE_COIN; // 2 USDT for puts
    uint256 putSellPrice = 1 * ONE_COIN; // 1 USDT for puts (lower, so orders will cross)
    uint256 orderSize = 3; // 3 contracts

    // User 1 goes LONG (long calls + short puts) with higher call price and lower put price
    vm.startPrank(u1);
    mkt.long(orderSize, callBuyPrice, putSellPrice, currentCycleId);
    vm.stopPrank();

    // User 2 goes SHORT (short calls + long puts) with lower call price and higher put price
    // This creates cross-priced orders that will execute against User 1's orders
    vm.startPrank(u2);
    vm.recordLogs();
    mkt.short(orderSize, putBuyPrice, callSellPrice, currentCycleId);
    Vm.Log[] memory initialTradeLogs = vm.getRecordedLogs();
    vm.stopPrank();

    // Verify LimitOrderFilled events were emitted for initial cross-priced trades
    uint256 initialFillCount = _countLimitOrderFilledEvents(initialTradeLogs);
    console.log("Initial trade LimitOrderFilled events:", initialFillCount);
    assertEq(initialFillCount, 2, "Should have 2 LimitOrderFilled events for call and put trades");

    // Verify positions after trade
    MarketWithViews.UserAccount memory ua1 = mkt.getUserAccount(u1);
    MarketWithViews.UserAccount memory ua2 = mkt.getUserAccount(u2);

    assertEq(ua1.longCalls, orderSize, "User 1 should have long calls");
    assertEq(ua1.shortPuts, orderSize, "User 1 should have short puts");
    assertEq(ua2.shortCalls, orderSize, "User 2 should have short calls");
    assertEq(ua2.longPuts, orderSize, "User 2 should have long puts");

    // Record balances after trade
    uint256 u1BalanceAfterTrade = ua1.balance;
    uint256 u2BalanceAfterTrade = ua2.balance;

    console.log("u1 balance after trade:", u1BalanceAfterTrade);
    console.log("u2 balance after trade:", u2BalanceAfterTrade);

    // BTC price dumps significantly, making User 1 (short puts) liquidatable
    _mockOracle(btcPrice - 20_000); // -20k makes short puts deeply ITM

    // Verify User 1 is now liquidatable
    assertTrue(mkt.isLiquidatable(u1), "User 1 should be liquidatable after price dump");
    assertFalse(mkt.isLiquidatable(u2), "User 2 should not be liquidatable");

    // Record User 1's balance before liquidation
    uint256 u1BalanceBeforeLiq = mkt.getUserAccount(u1).balance;
    console.log("u1 balance before liquidation:", u1BalanceBeforeLiq);

    // Liquidate User 1
    vm.startPrank(owner);
    mkt.liquidate(u1);
    vm.stopPrank();

    // Check liquidation state
    ua1 = mkt.getUserAccount(u1);
    assertTrue(ua1.liquidationQueued, "User 1 should have liquidation queued");
    console.log("u1 liquidation fee owed:", ua1.liquidationFeeOwed);
    console.log("u1 balance after liquidation (before settlement):", ua1.balance);

    // NOTE: In this test, we DO NOT provide liquidity to fill the liquidation orders
    // The liquidation orders will remain in the taker queue unfilled

    // Verify no additional LimitOrderFilled events occur (since no liquidity provided)
    vm.recordLogs();
    // No orders placed here - just checking that no spontaneous fills occur
    Vm.Log[] memory noLiquidityLogs = vm.getRecordedLogs();
    uint256 noLiquidityFillCount = _countLimitOrderFilledEvents(noLiquidityLogs);
    console.log("LimitOrderFilled events without liquidity:", noLiquidityFillCount);
    assertEq(noLiquidityFillCount, 0, "Should have 0 LimitOrderFilled events when no liquidity is provided");

    // Verify User 1's balance is still the same (no liquidation order execution)
    ua1 = mkt.getUserAccount(u1);
    assertEq(ua1.balance, u1BalanceBeforeLiq, "User 1 balance should be unchanged when liquidation orders are unfilled");
    console.log("u1 balance after liquidation (no liquidity provided):", ua1.balance);

    // Fast forward to settlement
    vm.warp(currentCycleId + 1);
    _mockOracle(btcPrice - 20_000); // Keep same settlement price

    // Record events during settlement
    vm.recordLogs();
    mkt.settleChunk(100, false);
    Vm.Log[] memory settlementLogs = vm.getRecordedLogs();

    // Check if LiquidationFeePaid event was emitted for User 1
    // In this case, the user's balance was NOT consumed by liquidation order execution,
    // so the liquidation fee should be paid during settlement
    bool foundLiquidationFeePaid = false;
    uint256 liquidationFeePaid = 0;

    for (uint256 i = 0; i < settlementLogs.length; i++) {
      if (settlementLogs[i].topics[0] == keccak256("LiquidationFeePaid(uint256,address,uint256)")) {
        address liquidatedUser = address(uint160(uint256(settlementLogs[i].topics[2])));
        if (liquidatedUser == u1) {
          foundLiquidationFeePaid = true;
          (liquidationFeePaid) = abi.decode(settlementLogs[i].data, (uint256));
          break;
        }
      }
    }

    // In this test case, the liquidation orders were NOT filled, so the user's balance
    // should be available during settlement to pay the liquidation fee
    assertTrue(
      foundLiquidationFeePaid, "LiquidationFeePaid event should be emitted when liquidation orders remain unfilled"
    );
    console.log("Liquidation fee paid during settlement:", liquidationFeePaid);

    // Verify User 1's final state after settlement
    ua1 = mkt.getUserAccount(u1);
    assertEq(ua1.balance, 0, "User 1 balance should be 0 after settlement");
    assertEq(ua1.liquidationFeeOwed, 0, "User 1 liquidation fee owed should be 0 after settlement");
    assertFalse(ua1.liquidationQueued, "User 1 liquidation should no longer be queued");

    // Verify all positions are cleared for User 1
    assertEq(ua1.longCalls, 0, "User 1 long calls should be 0");
    assertEq(ua1.shortCalls, 0, "User 1 short calls should be 0");
    assertEq(ua1.longPuts, 0, "User 1 long puts should be 0");
    assertEq(ua1.shortPuts, 0, "User 1 short puts should be 0");

    console.log("Final u1 balance:", ua1.balance);
    console.log("Final u1 liquidation fee owed:", ua1.liquidationFeeOwed);
    console.log("Final u1 liquidation queued:", ua1.liquidationQueued);

    // Check fee recipient balance after settlement
    uint256 feeRecipientBalance = mkt.getUserAccount(feeSink).balance;
    console.log("Fee recipient balance after settlement:", feeRecipientBalance);

    // In this case, the liquidation fee should be transferred to fee recipient during settlement
    assertGt(feeRecipientBalance, 0, "Fee recipient should have received liquidation fee during settlement");

    // Verify User 2 has positive balance after settlement (positions are cleared during settlement)
    ua2 = mkt.getUserAccount(u2);
    assertGt(ua2.balance, 0, "User 2 should still have positive balance");
    // Note: All positions are cleared during settlement for all users
    assertEq(ua2.shortCalls, 0, "User 2 positions should be cleared after settlement");
    assertEq(ua2.longPuts, 0, "User 2 positions should be cleared after settlement");
  }

  // #######################################################################
  // #                                                                     #
  // #                             Pnl                                     #
  // #                                                                     #
  // #######################################################################

  function testLongThenMM_PriceUp() public {
    uint256 deposit = 5_000 * ONE_COIN; // 5 000 USDT0
    _fund(u1, deposit);
    _fund(u2, deposit);

    vm.startPrank(u1);
    mkt.long(10, 0, 0, cycleId); // 10 long calls + 10 short puts
    vm.stopPrank();

    uint256 callPrem = 2 * ONE_COIN; // 2 USDT0 / call
    uint256 putPrem = 1 * ONE_COIN; // 1 USDT0 / put

    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.CALL_SELL, 10, callPrem, cycleId);
    mkt.placeOrder(MarketSide.PUT_BUY, 10, putPrem, cycleId);
    vm.stopPrank();

    vm.warp(cycleId + 1);
    _mockOracle(btcPrice + 15_000); // 115 000 -> calls ITM by 15 000

    mkt.settleChunk(20, false);

    uint256 callPremAll = callPrem * 10; // 20 USDT0
    uint256 putPremAll = putPrem * 10; // 10 USDT0

    // taker fees (u1 pays two of them)
    uint256 takerFeeCall = callPremAll * uint256(TAKER_FEE_BPS) / 10_000; // +7 % -> 1.4
    uint256 takerFeePut = putPremAll * uint256(TAKER_FEE_BPS) / 10_000; // +7 % -> 0.7

    // u1 cash flow during trade
    int256 cashU1 = -int256(callPremAll) - int256(takerFeeCall) + int256(putPremAll) - int256(takerFeePut);

    // intrinsic P/L (calls ITM)
    uint256 intrinsic = 15_000 * ONE_COIN * 10 / CONTRACT_SIZE;

    // final expected balances
    uint256 expectU1 = uint256(int256(deposit) + cashU1 + int256(intrinsic));
    int256 makerFeeCall = int256(callPremAll) * int256(MAKER_FEE_BPS) / 10_000;
    int256 makerFeePut = int256(putPremAll) * int256(MAKER_FEE_BPS) / 10_000;

    int256 cashU2 = int256(callPremAll) - makerFeeCall - int256(putPremAll) - makerFeePut;

    uint256 expectU2 = uint256(int256(deposit) + cashU2 - int256(intrinsic));

    uint256 balU1 = mkt.getUserAccount(u1).balance;
    uint256 balU2 = mkt.getUserAccount(u2).balance;

    assertEq(balU1, expectU1, "u1 balance mismatch after pump");
    assertEq(balU2, expectU2, "u2 balance mismatch after pump");
  }

  function testLongThenMM_PriceDown() public {
    uint256 deposit = 5_000 * ONE_COIN; // 5 000 USDT0
    _fund(u1, deposit);
    _fund(u2, deposit);

    vm.startPrank(u1);
    mkt.long(10, 0, 0, cycleId); // 10 long calls + 10 short puts
    vm.stopPrank();

    uint256 callPrem = 2 * ONE_COIN; // 2 USDT0 / call
    uint256 putPrem = 1 * ONE_COIN; // 1 USDT0 / put

    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.CALL_SELL, 10, callPrem, cycleId);
    mkt.placeOrder(MarketSide.PUT_BUY, 10, putPrem, cycleId);
    vm.stopPrank();
    vm.warp(cycleId + 1);
    _mockOracle(btcPrice - 15_000); // 85 000 -> puts ITM by 15 000

    mkt.settleChunk(20, false);

    uint256 callPremAll = callPrem * 10; // 20 USDT0
    uint256 putPremAll = putPrem * 10; // 10 USDT0

    // taker fees (u1 pays two of them)
    uint256 takerFeeCall = callPremAll * uint256(TAKER_FEE_BPS) / 10_000; // +7 % -> 1.4
    uint256 takerFeePut = putPremAll * uint256(TAKER_FEE_BPS) / 10_000; // +7 % -> 0.7

    // u1 cash flow during trade
    int256 cashU1 = -int256(callPremAll) - int256(takerFeeCall) + int256(putPremAll) - int256(takerFeePut);

    // intrinsic P/L (puts ITM)
    uint256 intrinsic = 15_000 * ONE_COIN * 10 / CONTRACT_SIZE;

    // final expected balances
    uint256 expectU1 = uint256(int256(deposit) + cashU1 - int256(intrinsic));
    int256 makerFeeCall = int256(callPremAll) * int256(MAKER_FEE_BPS) / 10_000;
    int256 makerFeePut = int256(putPremAll) * int256(MAKER_FEE_BPS) / 10_000;

    int256 cashU2 = int256(callPremAll) - makerFeeCall - int256(putPremAll) - makerFeePut;

    uint256 expectU2 = uint256(int256(deposit) + cashU2 + int256(intrinsic));

    uint256 balU1 = mkt.getUserAccount(u1).balance;
    uint256 balU2 = mkt.getUserAccount(u2).balance;

    assertEq(balU1, expectU1, "u1 balance mismatch after dump");
    assertEq(balU2, expectU2, "u2 balance mismatch after dump");
  }

  function testShortThenMM_PriceUp() public {
    uint256 deposit = 5_000 * ONE_COIN; // 5 000 USDT0
    _fund(u1, deposit);
    _fund(u2, deposit);

    vm.startPrank(u1);
    mkt.short(10, 0, 0, cycleId); // 10 short calls + 10 long puts
    vm.stopPrank();

    uint256 callPrem = 2 * ONE_COIN; // 2 USDT0 / call
    uint256 putPrem = 1 * ONE_COIN; // 1 USDT0 / put

    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.CALL_BUY, 10, callPrem, cycleId);
    mkt.placeOrder(MarketSide.PUT_SELL, 10, putPrem, cycleId);
    vm.stopPrank();

    vm.warp(cycleId + 1);
    _mockOracle(btcPrice + 15_000); // 115 000 -> calls ITM by 15 000

    mkt.settleChunk(20, false);

    uint256 callPremAll = callPrem * 10; // 20 USDT0
    uint256 putPremAll = putPrem * 10; // 10 USDT0

    // taker fees (u1 pays two of them)
    uint256 takerFeeCall = callPremAll * uint256(TAKER_FEE_BPS) / 10_000; // +7 % -> 1.4
    uint256 takerFeePut = putPremAll * uint256(TAKER_FEE_BPS) / 10_000; // +7 % -> 0.7

    // u1 cash flow during trade
    int256 cashU1 = int256(callPremAll) // +20
      - int256(putPremAll) // -10
      - int256(takerFeeCall) // -1.4
      - int256(takerFeePut); // -0.7

    // intrinsic P/L (short calls lose)
    uint256 intrinsic = 15_000 * ONE_COIN * 10 / CONTRACT_SIZE; // 1 500 USDT0

    // final expected balances
    uint256 expectU1 = uint256(int256(deposit) + cashU1 - int256(intrinsic));
    int256 makerFeeCall = int256(callPremAll) * int256(MAKER_FEE_BPS) / 10_000;
    int256 makerFeePut = int256(putPremAll) * int256(MAKER_FEE_BPS) / 10_000;

    int256 cashU2 = -int256(callPremAll) - makerFeeCall + int256(putPremAll) - makerFeePut;

    uint256 expectU2 = uint256(int256(deposit) + cashU2 + int256(intrinsic));

    uint256 balU1 = mkt.getUserAccount(u1).balance;
    uint256 balU2 = mkt.getUserAccount(u2).balance;

    assertEq(balU1, expectU1, "u1 balance mismatch after pump");
    assertEq(balU2, expectU2, "u2 balance mismatch after pump");
  }

  function testShortThenMM_PriceDown() public {
    uint256 deposit = 5_000 * ONE_COIN; // 5 000 USDT0
    _fund(u1, deposit);
    _fund(u2, deposit);

    vm.startPrank(u1);
    mkt.short(10, 0, 0, cycleId); // 10 short calls + 10 long puts
    vm.stopPrank();

    uint256 callPrem = 2 * ONE_COIN; // 2 USDT0 / call
    uint256 putPrem = 1 * ONE_COIN; // 1 USDT0 / put

    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.CALL_BUY, 10, callPrem, cycleId);
    mkt.placeOrder(MarketSide.PUT_SELL, 10, putPrem, cycleId);
    vm.stopPrank();

    vm.warp(cycleId + 1);
    _mockOracle(btcPrice - 15_000); // 85 000 -> puts ITM by 15 000

    mkt.settleChunk(20, false);

    uint256 callPremAll = callPrem * 10; // 20 USDT0
    uint256 putPremAll = putPrem * 10; // 10 USDT0

    // taker fees (u1 pays two of them)
    uint256 takerFeeCall = callPremAll * uint256(TAKER_FEE_BPS) / 10_000; // +7 % -> 1.4
    uint256 takerFeePut = putPremAll * uint256(TAKER_FEE_BPS) / 10_000; // +7 % -> 0.7

    // u1 cash flow during trade
    int256 cashU1 = int256(callPremAll) // +20
      - int256(putPremAll) // -10
      - int256(takerFeeCall) // -1.4
      - int256(takerFeePut); // -0.7

    // intrinsic P/L (long puts win)
    uint256 intrinsic = 15_000 * ONE_COIN * 10 / CONTRACT_SIZE; // 1 500 USDT0

    // final expected balances
    uint256 expectU1 = uint256(int256(deposit) + cashU1 + int256(intrinsic));
    int256 makerFeeCall = int256(callPremAll) * int256(MAKER_FEE_BPS) / 10_000;
    int256 makerFeePut = int256(putPremAll) * int256(MAKER_FEE_BPS) / 10_000;

    int256 cashU2 = -int256(callPremAll) - makerFeeCall + int256(putPremAll) - makerFeePut;

    uint256 expectU2 = uint256(int256(deposit) + cashU2 - int256(intrinsic));

    uint256 balU1 = mkt.getUserAccount(u1).balance;
    uint256 balU2 = mkt.getUserAccount(u2).balance;

    assertEq(balU1, expectU1, "u1 balance mismatch after dump");
    assertEq(balU2, expectU2, "u2 balance mismatch after dump");
  }

  // #######################################################################
  // #                                                                     #
  // #                             Helpers                                 #
  // #                                                                     #
  // #######################################################################

  function _fund(address who, uint256 amount) internal {
    deal(address(usdt), who, amount);
    _whitelistAddress(who);
    vm.startPrank(who);
    usdt.approve(address(mkt), type(uint256).max);
    mkt.depositCollateral(amount);
  }

  function _tick(uint256 p) internal pure returns (uint32) {
    return uint32(p / TICK_SIZE);
  }

  function _key(uint32 t, bool put, bool bid) internal pure returns (uint32) {
    return t | (put ? 1 << 31 : 0) | (bid ? 1 << 30 : 0);
  }

  // helper: open a 1-contract CALL long/short pair at 1 USDT premium
  function _openCallPair(address longAddr, address shortAddr) internal {
    uint256 currentCycleId = mkt.activeCycle();
    // shortAddr posts ask
    vm.startPrank(shortAddr);
    mkt.placeOrder(MarketSide.CALL_SELL, 1, ONE_COIN, currentCycleId);
    vm.stopPrank();

    // longAddr hits it market
    vm.startPrank(longAddr);
    mkt.placeOrder(MarketSide.CALL_BUY, 1, 0, currentCycleId); // market
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
      uint256 price6 = uint256(book[i].tick) * TICK_SIZE;
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

  function _whitelistAddress(address user) internal {
    bytes32 slot = keccak256(abi.encode(user, uint256(4)));
    vm.store(address(mkt), slot, bytes32(uint256(1)));
  }

  function _isPut(MarketSide side) internal pure returns (bool) {
    return side == MarketSide.PUT_BUY || side == MarketSide.PUT_SELL;
  }

  function _isBuy(MarketSide side) internal pure returns (bool) {
    return side == MarketSide.CALL_BUY || side == MarketSide.PUT_BUY;
  }

  function _getLiquidationFeePaid(Vm.Log[] memory logs) internal pure returns (uint256) {
    for (uint256 i; i < logs.length; ++i) {
      if (logs[i].topics[0] == keccak256("LiquidationFeePaid(uint256,address,uint256)")) {
        (uint256 liqFeePaid) = abi.decode(logs[i].data, (uint256));
        return liqFeePaid;
      }
    }
    return 0;
  }

  function _getLiquidationFeeOwed(Vm.Log[] memory logs) internal pure returns (uint256) {
    for (uint256 i; i < logs.length; ++i) {
      if (logs[i].topics[0] == keccak256("Liquidated(uint256,address,uint256)")) {
        (uint256 liqFeeOwed) = abi.decode(logs[i].data, (uint256));
        return liqFeeOwed;
      }
    }
    return 0;
  }

  function _getCashTakerFromLimitOrderFilledEvents(Vm.Log[] memory logs) internal view returns (int256 totalCashTaker) {
    for (uint256 i; i < logs.length; ++i) {
      if (
        logs[i].topics[0]
          == keccak256(
            "LimitOrderFilled(uint256,uint256,int256,uint256,uint256,uint8,address,address,int256,int256,uint256)"
          ) && address(uint160(uint256(logs[i].topics[2]))) == u1 // taker == u1
      ) {
        (
          ,
          ,
          ,
          ,
          , // ignore
          int256 cashTaker,
          ,
        ) = abi.decode(logs[i].data, (uint256, int256, uint256, uint256, uint8, int256, int256, uint256));
        totalCashTaker += cashTaker; // CALL leg & PUT leg
      }
    }
  }

  function _getPnl(Vm.Log[] memory logs, address trader) internal view returns (int256) {
    for (uint256 i; i < logs.length; ++i) {
      if (logs[i].topics[0] == keccak256("Settled(uint256,address,int256)")) {
        if (address(uint160(uint256(logs[i].topics[2]))) == trader) {
          (int256 pnl) = abi.decode(logs[i].data, (int256));
          return pnl;
        }
      }
    }
    revert("Settled event not found");
  }

  function _countLimitOrderFilledEvents(Vm.Log[] memory logs) internal pure returns (uint256) {
    uint256 count = 0;
    for (uint256 i = 0; i < logs.length; i++) {
      if (
        logs[i].topics[0]
          == keccak256(
            "LimitOrderFilled(uint256,uint256,int256,uint256,uint256,uint8,address,address,int256,int256,uint256)"
          )
      ) count++;
    }
    return count;
  }

  // Test how many price levels a crossing limit order can cross before running out of gas
  function testMaxPriceLevelsCrossed() public {
    console.log("Testing maximum price levels that can be crossed in a single transaction");

    // Fund multiple users to place limit orders
    uint256 fundAmount = 100_000 * ONE_COIN; // Large amount for testing
    for (uint256 i = 0; i < 50; i++) {
      address user = address(uint160(0x1000 + i));
      _fund(user, fundAmount);
    }

    // Fund the crossing order placer
    _fund(u1, 1_000_000 * ONE_COIN);

    console.log("Setting up orderbook with multiple price levels...");

    // Place sell orders at incrementally higher prices (creates ask levels)
    // Starting from a low price and going up
    uint256 basePrice = 1000e4; // 1000 USDT base price
    uint256 orderSize = 10; // 10 contracts per level
    uint256 numLevels = 0;

    // Place orders at different price levels
    for (uint256 i = 0; i < 40; i++) {
      address seller = address(uint160(0x1000 + i));
      uint256 price = basePrice + (i * 100e4); // Increment by 100 USDT per level

      vm.startPrank(seller);
      try mkt.placeOrder(MarketSide.CALL_SELL, orderSize, price, cycleId) {
        numLevels++;
      } catch {
        console.log("Failed to place order at level", i);
        break;
      }
      vm.stopPrank();
    }

    console.log("Successfully placed sell orders at", numLevels, "price levels");

    // Print the orderbook state
    _printBook(MarketSide.CALL_SELL);

    // Now place a large buy order that will cross multiple levels
    // Calculate total size needed to cross all levels
    uint256 totalSize = numLevels * orderSize;
    uint256 maxPrice = basePrice + ((numLevels - 1) * 100e4); // Price of highest level

    console.log("Placing crossing buy order:");
    console.log("- Total size needed to cross all levels:", totalSize);
    console.log("- Max price willing to pay:", maxPrice);

    // Record gas usage and events
    uint256 gasBefore = gasleft();
    vm.recordLogs();

    vm.startPrank(u1);

    // Try to place the crossing order and see how many levels it crosses
    try mkt.placeOrder(MarketSide.CALL_BUY, totalSize, maxPrice, cycleId) {
      console.log("Successfully placed crossing order");
    } catch Error(string memory reason) {
      console.log("Crossing order failed with error:", reason);
    } catch {
      console.log("Crossing order failed with unknown error");
    }

    vm.stopPrank();

    uint256 gasAfter = gasleft();
    uint256 gasUsed = gasBefore - gasAfter;

    // Get the logs to count how many fills occurred
    Vm.Log[] memory logs = vm.getRecordedLogs();
    uint256 fillCount = _countLimitOrderFilledEvents(logs);

    console.log("Results:");
    console.log("- Gas used:", gasUsed);
    console.log("- Number of fills (levels crossed):", fillCount);
    console.log("- Average gas per level crossed:", fillCount > 0 ? gasUsed / fillCount : 0);

    // Print final orderbook state to see what's left
    console.log("\nOrderbook after crossing order:");
    _printBook(MarketSide.CALL_SELL);

    // Assert that we crossed at least some levels
    assertTrue(fillCount > 0, "Should have crossed at least one price level");

    // Log the theoretical maximum based on block gas limit
    uint256 blockGasLimit = 2000000; // Typical block gas limit
    uint256 avgGasPerLevel = fillCount > 0 ? gasUsed / fillCount : 0;
    uint256 theoreticalMax = avgGasPerLevel > 0 ? blockGasLimit / avgGasPerLevel : 0;

    console.log("Theoretical maximum levels in one block:", theoreticalMax);
  }

  function testNeelLoss() public {
    _fund(u1, 1000 * ONE_COIN);
    _fund(u2, 1000000000 * ONE_COIN);

    vm.startPrank(u1);
    mkt.long(161, 341300, 176700, cycleId);
    vm.stopPrank();

    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.CALL_SELL, 161, 0, cycleId);
    mkt.placeOrder(MarketSide.PUT_BUY, 161, 0, cycleId);
    vm.stopPrank();

    console.log("Neel balance before:", _getNeelBalance(u1));

    vm.warp(cycleId + 1);
    _mockOracle(107344); // 85 000 -> puts ITM by 15 000

    mkt.settleChunk(20, false);

    console.log("Neel balance after:", _getNeelBalance(u1));
  }

  function _getNeelBalance(address neel) internal view returns (uint256) {
    (
      bool active,
      bool liquidationQueued,
      uint64 balance,
      uint64 liquidationFeeOwed,
      uint64 scratchPnL,
      uint48 _gap,
      uint32 longCalls,
      uint32 shortCalls,
      uint32 longPuts,
      uint32 shortPuts,
      uint32 pendingLongCalls,
      uint32 pendingShortCalls,
      uint32 pendingLongPuts,
      uint32 pendingShortPuts
    ) = mkt.userAccounts(neel);
    return balance;
  }

  function testPlaceOrderNoBalance() public {
    vm.startPrank(u1);
    mkt.placeOrder(MarketSide.CALL_BUY, 1, 291020, cycleId);
    vm.stopPrank();

    console.log("Neel balance:", _getNeelBalance(u1));
  }
}
