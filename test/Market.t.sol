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

  uint256 btcPrice = 100000;

  uint256 cycleId;

  function setUp() public {
    usdt = new Token("USDT0", "USDT0"); // 6-dec mock

    implementation = new MarketWithViews();

    // Init data
    bytes memory initData =
      abi.encodeWithSelector(Market.initialize.selector, "BTC", feeSink, address(usdt), address(0), gov);

    // Proxy
    proxy = new ERC1967Proxy(address(implementation), initData);

    vm.startPrank(securityCouncil);
    Market(address(proxy)).unpause();
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

    // cycle closed
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
    int256 takerFee = int256(premium) * TAKER_FEE_BPS / 10_000; // u1
    int256 makerFee = int256(premium) * MAKER_FEE_BPS / 10_000; // u2

    int256 cashTaker = -int256(premium) - takerFee; // -1.07 USDT
    int256 cashMaker = int256(premium) - makerFee; // +1.02 USDT

    uint256 balU1_afterTrade = uint256(int256(longDeposit) + cashTaker);
    uint256 balU2_afterTrade = uint256(int256(shortDeposit) + cashMaker);

    vm.warp(cycleId + 1);
    _mockOracle(btcPrice + 10_000); // +10 000 USD spot move

    uint256 intrinsic = (10_000 * ONE_COIN) / CONTRACT_SIZE; // 100 USDT

    mkt.settleChunk(10);

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
    mkt.settleChunk(1000);
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
    (bool isSettled,,) = mkt.cycles(initialCycleId);
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
    mkt.settleChunk(6); // Choose a chunk size which would complete phase 1
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
    mkt.settleChunk(100);
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
    mkt.settleChunk(3); // Choose a chunk size which would not complete phase 1
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
    mkt.settleChunk(100);
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
      if (i & 1 == 1) {
        _openCallPair(makeAddr(string(abi.encodePacked("multi", vm.toString(i - 1)))), user);
      }
    }

    uint256 cycleIdBefore = mkt.activeCycle();
    vm.warp(cycleIdBefore + 1);
    _mockOracle(btcPrice + 1_000);

    uint256 txCount;
    while (mkt.activeCycle() == cycleIdBefore) {
      mkt.settleChunk(1); // deliberately small to force many txs
      ++txCount;
    }

    assertGt(txCount, 2, "should take more than two txs");
    (bool settled,,) = mkt.cycles(cycleIdBefore);
    assertTrue(settled, "previous cycle not settled");
    assertGt(mkt.activeCycle(), cycleIdBefore, "new cycle should start");
  }

  function testSettlementWithPausePreventsAutoCycle() public {
    // Setup
    _fund(u1, 200 * ONE_COIN);
    _fund(u2, 200 * ONE_COIN);

    // Can still place orders after pause
    _openCallPair(u1, u2);

    vm.startPrank(securityCouncil);
    mkt.pauseNewCycles();
    vm.stopPrank();

    vm.warp(cycleId + 1);
    _mockOracle(btcPrice + 1_000);

    mkt.settleChunk(100);

    // Cycle settled — but no new cycle should have started
    (bool settled,,) = mkt.cycles(cycleId);
    assertTrue(settled, "cycle should settle");
    assertEq(mkt.activeCycle(), 0, "no active cycle in settlement only mode");

    // Attempting to start a cycle must revert
    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    mkt.startCycle();

    // Exit settlement‑only mode and start a new cycle
    vm.startPrank(securityCouncil);
    mkt.unpause();
    vm.stopPrank();

    mkt.startCycle();
    assertGt(mkt.activeCycle(), cycleId, "new cycle should start after unpause");
  }

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
    mkt.settleChunk(100);
    
    mkt.unpause();
    mkt.settleChunk(100);
    
    // Pause but allow settling
    mkt.pauseNewCycles();

    uint256 cycleIdAfter = mkt.activeCycle();
    vm.warp(cycleIdAfter + 1);
    vm.recordLogs();
    mkt.settleChunk(100);
    Vm.Log[] memory logs = vm.getRecordedLogs();

    assertEq(logs[0].topics[0], keccak256("PriceFixed(uint256,uint64)"));
    assertEq(logs[1].topics[0], keccak256("CycleSettled(uint256)"));
    
    assertEq(mkt.activeCycle(), 0);

    // Unpause and start a new cycle
    mkt.unpause();
    assertEq(mkt.paused(), false);

    mkt.startCycle();
    assertGt(mkt.activeCycle(), cycleIdAfter);
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

  function testLiquidationFeeNotZeroedBug() public {
    uint256 collateral = 2 * ONE_COIN;
    _fund(u1, collateral);
    _fund(u2, 1000 * ONE_COIN);

    // u1 goes short calls
    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.CALL_BUY, 1, ONE_COIN, cycleId);
    vm.stopPrank();
    vm.startPrank(u1);
    mkt.placeOrder(MarketSide.CALL_SELL, 1, ONE_COIN, cycleId);
    vm.stopPrank();

    // Price pumps, u1 becomes liquidatable
    _mockOracle(btcPrice + 20000);
    
    // Liquidate u1 
    vm.startPrank(owner);
    mkt.liquidate(u1);
    vm.stopPrank();
    
    // Provide liquidity to close the liquidation order
    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.CALL_SELL, 1, 5000 * ONE_COIN, cycleId);
    vm.stopPrank();
    
    // Fast forward to settlement
    vm.warp(cycleId + 1);
    
    // Get liquidation fee owed before settlement
    uint64 liquidationFeeOwed = mkt.getUserAccount(u1).liquidationFeeOwed;
    console.log("Liquidation fee owed before settlement:", liquidationFeeOwed);
    
    // Settlement
    vm.startPrank(owner);
    mkt.settleChunk(20);
    mkt.settleChunk(20);
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

    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.CALL_BUY, 1, ONE_COIN, cycleId);
    vm.stopPrank();
    vm.startPrank(u1);
    mkt.placeOrder(MarketSide.CALL_SELL, 1, ONE_COIN, cycleId);
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
    mkt.placeOrder(MarketSide.CALL_SELL, 1, 5 * ONE_COIN, cycleId); // More than u1 can afford
    vm.stopPrank();
    
    Vm.Log[] memory entries = vm.getRecordedLogs();
    
    // Find the LimitOrderFilled event from the liquidation
    int256 emittedCashTaker = 0;
    bool foundFillEvent = false;
    
    for (uint256 i = 0; i < entries.length; i++) {
      if (entries[i].topics[0] == keccak256("LimitOrderFilled(uint256,uint256,uint256,uint256,uint256,uint8,address,address,int256,int256,uint256)")) {
        address taker = address(uint160(uint256(entries[i].topics[2])));
        if (taker == u1) { // u1 is the liquidated taker
          (,,,,, int256 cashTaker,,) = abi.decode(entries[i].data, (uint256, uint256, uint256, uint256, uint8, int256, int256, uint256));
          emittedCashTaker = cashTaker;
          foundFillEvent = true;
          break;
        }
      }
    }
    
    assertTrue(foundFillEvent, "LimitOrderFilled event should be emitted for liquidation");
    
    uint256 balanceAfterFill = mkt.getUserAccount(u1).balance;
    console.log("u1 balance after fill:", balanceAfterFill);
    console.log("Emitted cashTaker:", emittedCashTaker);
    
    // Calculate the theoretical vs actual payment
    uint256 theoreticalCost = 5 * ONE_COIN + (5 * ONE_COIN * 700 / 10000);
    uint256 actualPaid = balanceBeforeFill - balanceAfterFill;
    
    console.log("Theoretical cost (5 USDC + fee):", theoreticalCost);
    console.log("Actual amount paid:", actualPaid);
    console.log("User had insufficient funds?", actualPaid < theoreticalCost);
    
    if (actualPaid < theoreticalCost && balanceAfterFill == 0) {
      int256 expectedCashTaker = -int256(actualPaid);
      console.log("Expected cashTaker (actual paid):", expectedCashTaker);
      
      if (emittedCashTaker == expectedCashTaker) {
        console.log("ISSUE 2 FIXED: Event correctly shows actual amount paid");
      } else {
        console.log("BUG: Event shows theoretical amount instead of actual amount paid");
      }
      
      assertEq(emittedCashTaker, expectedCashTaker, "Event should show actual amount paid by insolvent user, not theoretical amount");
    } else {
      console.log("No insolvency scenario created - test needs adjustment");
    }
  }

  // Liquidation fee should be included in settlement PnL when user can afford it
  function testLiquidationFeeIncludedInSettlementPnL() public {
    uint256 collateral = 100 * ONE_COIN;
    _fund(u1, collateral);
    _fund(u2, 1000 * ONE_COIN);

    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.CALL_BUY, 1, ONE_COIN, cycleId);
    vm.stopPrank();
    vm.startPrank(u1);  
    mkt.placeOrder(MarketSide.CALL_SELL, 1, ONE_COIN, cycleId);
    vm.stopPrank();

    // Significant price pump to make user liquidatable
    _mockOracle(btcPrice + 15000); 
    vm.startPrank(owner);
    mkt.liquidate(u1);
    vm.stopPrank();
    
    uint64 liquidationFeeOwed = mkt.getUserAccount(u1).liquidationFeeOwed;
    console.log("Liquidation fee owed:", liquidationFeeOwed);
    
    // Provide liquidity at reasonable price to preserve u1's balance
    vm.startPrank(u2);
    mkt.placeOrder(MarketSide.CALL_SELL, 1, 10 * ONE_COIN, cycleId);
    vm.stopPrank();
    
    // Check u1 has enough balance to pay liquidation fee
    uint256 balanceAfterFill = mkt.getUserAccount(u1).balance;
    console.log("Balance after liquidation fill:", balanceAfterFill);
    console.log("Can afford liquidation fee?", balanceAfterFill >= liquidationFeeOwed);
    
    // Fast forward to settlement  
    vm.warp(cycleId + 1);
    
    // Record the Settled event
    vm.recordLogs();
    mkt.settleChunk(20);
    mkt.settleChunk(20);
    
    Vm.Log[] memory entries = vm.getRecordedLogs();
    
    // Find the Settled event for u1
    int256 emittedPnL = 0;
    bool foundSettledEvent = false;
    
    for (uint256 i = 0; i < entries.length; i++) {
      if (entries[i].topics[0] == keccak256("Settled(uint256,address,int256)")) {
        address trader = address(uint160(uint256(entries[i].topics[2])));
        if (trader == u1) {
          emittedPnL = abi.decode(entries[i].data, (int256));
          foundSettledEvent = true;
          break;
        }
      }
    }
    
    assertTrue(foundSettledEvent, "Settled event should be emitted for u1");
    console.log("Emitted PnL:", emittedPnL);
    
    // Get final state
    MarketWithViews.UserAccount memory uaFinal = mkt.getUserAccount(u1);
    console.log("Final balance:", uaFinal.balance);
    console.log("Final liquidationFeeOwed:", uaFinal.liquidationFeeOwed);
    
    // If user could afford the liquidation fee, it should be reflected in PnL
    if (balanceAfterFill >= liquidationFeeOwed) {
      // Expected PnL = 0 (positions cancel) - liquidationFee (actually paid)
      int256 expectedPnL = -int256(uint256(liquidationFeeOwed));
      console.log("Expected PnL (should include liquidation fee):", expectedPnL);
      
      // This should FAIL if liquidation fee isn't included in settlement PnL
      assertEq(emittedPnL, expectedPnL, "Settlement PnL should include liquidation fee when user can afford it");
    } else {
      console.log("User couldn't afford liquidation fee, test invalid");
      assertTrue(false, "Test setup failed - user should have enough balance");
    }
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
}
