// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SharedStorage} from "./SharedStorage.sol";
import {BitScan} from "./lib/Bitscan.sol";
import {Errors} from "./lib/Errors.sol";
import {IMarket, Cycle, Level, Maker, TakerQ, MarketSide} from "./interfaces/IMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC2771ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Market is
  SharedStorage,
  IMarket,
  Initializable,
  UUPSUpgradeable,
  OwnableUpgradeable,
  PausableUpgradeable,
  ERC2771ContextUpgradeable
{
  using SafeERC20 for IERC20;

  //------- Events -------
  event CycleStarted(uint256 indexed cycleId, uint256 strike);
  event CycleSettled(uint256 indexed cycleId);
  event CollateralDeposited(address indexed trader, uint256 amount);
  event CollateralWithdrawn(address indexed trader, uint256 amount);
  event Liquidated(uint256 indexed cycleId, address indexed trader, uint256 liqFeeOwed);
  event PriceFixed(uint256 indexed cycleId, uint64 price);
  event Settled(uint256 indexed cycleId, address indexed trader, int256 pnl);
  event LimitOrderPlaced(
    uint256 indexed cycleId,
    uint256 makerOrderId,
    uint256 size,
    uint256 limitPrice,
    MarketSide side,
    address indexed maker
  );
  event LimitOrderFilled(
    uint256 indexed cycleId,
    uint256 makerOrderId,
    int256 takerOrderId,
    uint256 size,
    uint256 limitPrice,
    MarketSide side,
    address indexed taker,
    address indexed maker,
    int256 cashTaker,
    int256 cashMaker,
    uint256 btcPrice
  );
  event LimitOrderCancelled(
    uint256 indexed cycleId, uint256 makerOrderId, uint256 size, uint256 limitPrice, address indexed maker
  );
  event TakerOrderPlaced(
    uint256 indexed cycleId, int32 takerOrderId, uint256 size, MarketSide side, address indexed taker
  );
  event TakerOrderRemaining(
    uint256 indexed cycleId, int32 takerOrderId, uint256 size, MarketSide side, address indexed taker
  );

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() ERC2771ContextUpgradeable(address(0)) {
    _disableInitializers();
  }

  function initialize(
    string memory _name,
    address _feeRecipient,
    address _collateralToken,
    address _forwarder,
    address _governance
  ) external initializer {
    __Ownable_init(_governance);
    __Pausable_init();

    name = _name;
    feeRecipient = _feeRecipient;
    collateralToken = _collateralToken;
    _trustedForwarder = _forwarder;
  }

  // #######################################################################
  // #                                                                     #
  // #                  Public functions                                   #
  // #                                                                     #
  // #######################################################################

  function depositCollateral(uint256 amount, bytes memory signature) external isValidSignature(signature) whenNotPaused {
    address trader = _msgSender();
    whitelist[trader] = true;
    _depositCollateral(amount, trader);
  }

  function depositCollateral(uint256 amount) external onlyWhitelisted whenNotPaused {
    _depositCollateral(amount, _msgSender());
  }

  function withdrawCollateral(uint256 amount) external whenNotPaused {
    address trader = _msgSender();
    if (amount == 0) revert Errors.InvalidAmount();
    if (_hasOpenPositionsOrOrders(trader)) revert Errors.InTraderList();

    uint256 balance = userAccounts[trader].balance;
    if (balance < amount) revert Errors.InsufficientBalance();

    unchecked {
      // We check amount above, and this saves some gas + code size
      userAccounts[trader].balance -= uint64(amount);
    }

    IERC20(collateralToken).safeTransfer(trader, amount);

    emit CollateralWithdrawn(trader, amount);
  }

  function long(uint256 size, uint256 limitPriceBuy, uint256 limitPriceSell, uint256 cycleId) external whenNotPaused {
    _checkActiveCycle(cycleId);
    address trader = _msgSender();

    _placeOrder(MarketSide.CALL_BUY, size, limitPriceBuy, trader);
    _placeOrder(MarketSide.PUT_SELL, size, limitPriceSell, trader);
  }

  function short(uint256 size, uint256 limitPriceBuy, uint256 limitPriceSell, uint256 cycleId) external whenNotPaused {
    _checkActiveCycle(cycleId);
    address trader = _msgSender();

    _placeOrder(MarketSide.PUT_BUY, size, limitPriceBuy, trader);
    _placeOrder(MarketSide.CALL_SELL, size, limitPriceSell, trader);
  }

  function placeMultiOrder(
    MarketSide[] memory sides,
    uint256[] memory sizes,
    uint256[] memory limitPrices,
    uint256 cycleId
  ) external whenNotPaused {
    address trader = _msgSender();
    uint256 length = sides.length;
    for (uint256 i = 0; i < length; i++) {
      _placeOrder(sides[i], sizes[i], limitPrices[i], trader);
    }
  }

  function placeOrder(MarketSide side, uint256 size, uint256 limitPrice, uint256 cycleId)
    external
    whenNotPaused
    returns (uint256 orderId)
  {
    if (cycleId != 0 && cycleId != activeCycle) revert Errors.InvalidCycle();
    address trader = _msgSender();
    _placeOrder(side, size, limitPrice, trader);
    return 0;
  }

  function cancelOrder(uint256 orderId) external whenNotPaused {
    address trader = _msgSender();
    if (isLiquidatable(trader, _getOraclePrice())) revert Errors.TraderLiquidatable();
    // if (!_isMarketLive()) revert Errors.MarketNotLive();

    Maker storage M = ob[activeCycle].makerNodes[uint32(orderId)];
    if (M.trader != trader) revert Errors.NotOrderOwner();

    _cancelOrder(uint32(orderId));
  }

  function cancelAndClose(uint256 buyCallPrice, uint256 sellCallPrice, uint256 buyPutPrice, uint256 sellPutPrice)
    external
    whenNotPaused
  {
    address trader = _msgSender();
    _cancelAllOrders(trader);
    UserAccount memory ua = userAccounts[trader];

    // Calculate net positions
    int256 netCalls = int256(uint256(ua.longCalls)) - int256(uint256(ua.shortCalls));
    int256 netPuts = int256(uint256(ua.longPuts)) - int256(uint256(ua.shortPuts));

    // If net long, place sell orders to neutralize. If net short, place buy orders to neutralize
    if (netCalls > 0) _placeOrder(MarketSide.CALL_SELL, uint256(netCalls), sellCallPrice, trader);
    else if (netCalls < 0) _placeOrder(MarketSide.CALL_BUY, uint256(-netCalls), buyCallPrice, trader);

    if (netPuts > 0) _placeOrder(MarketSide.PUT_SELL, uint256(netPuts), sellPutPrice, trader);
    else if (netPuts < 0) _placeOrder(MarketSide.PUT_BUY, uint256(-netPuts), buyPutPrice, trader);
  }

  function liquidate(address trader) external whenNotPaused {
    if (!_isMarketLive()) revert Errors.MarketNotLive();
    uint64 price = _getOraclePrice();
    if (!isLiquidatable(trader, price)) revert Errors.StillSolvent();

    // Cancel limit orders and taker queue entries
    _cancelAllOrders(trader);

    UserAccount storage ua = userAccounts[trader];
    UserAccount storage house = userAccounts[feeRecipient];

    int256 netShortCalls = int256(uint256(ua.shortCalls)) - int256(uint256(ua.longCalls));
    int256 netShortPuts = int256(uint256(ua.shortPuts)) - int256(uint256(ua.longPuts));

    // By definition, liquidation fee is the balance of the trader, since this only happens when trader exceeds 1000x
    // leverage, which means going under 0.1% margin
    ua.liquidationQueued = true;
    ua.liquidationFeeOwed = uint64(ua.balance);

    emit Liquidated(activeCycle, trader, ua.liquidationFeeOwed);

    // Case 1: both sides net-short -> close both, confiscate nothing
    if (netShortCalls > 0 && netShortPuts > 0) {
      _marketOrder(MarketSide.CALL_BUY, uint128(uint256(netShortCalls)), trader, -_nextTakerId(ob[activeCycle]));
      _marketOrder(MarketSide.PUT_BUY, uint128(uint256(netShortPuts)), trader, -_nextTakerId(ob[activeCycle]));
    }
    // Case 2: only calls net-short. Net calls and confiscate net long puts
    else if (netShortCalls > 0) {
      _marketOrder(MarketSide.CALL_BUY, uint128(uint256(netShortCalls)), trader, -_nextTakerId(ob[activeCycle]));

      ua.longPuts -= uint32(uint256(-netShortPuts));
      house.longPuts += uint32(uint256(-netShortPuts)); // netShortPuts is negative (or 0), denoting the net long puts
      traders.push(feeRecipient); // Add this contract to ensure it gets any liquidation-sourced longs
    }
    // Case 3: only puts net-short
    else {
      _marketOrder(MarketSide.PUT_BUY, uint128(uint256(netShortPuts)), trader, -_nextTakerId(ob[activeCycle]));

      ua.longCalls -= uint32(uint256(-netShortCalls));
      house.longCalls += uint32(uint256(-netShortCalls)); // netShortCalls is negative, denoting the net long calls
      traders.push(feeRecipient); // Add this contract to ensure it gets any liquidation-sourced longs
    }
  }

  function settleChunk(uint256 max, bool pauseNextCycle) external whenNotPaused {
    if (pauseNextCycle) _onlySecurityCouncil();
    if (activeCycle == 0) revert Errors.CycleNotStarted();

    uint256 cycleId = activeCycle;
    Cycle storage C = cycles[cycleId];
    uint64 settlementPrice = C.settlementPrice;

    if (settlementPrice == 0) {
      if (block.timestamp < activeCycle) revert Errors.NotExpired();
      settlementPrice = _getOraclePrice();
      C.settlementPrice = settlementPrice;
      emit PriceFixed(activeCycle, settlementPrice);
    }

    if (C.isSettled) revert Errors.CycleAlreadySettled();

    uint256 iterationsUsed = 0;

    if (!settlementPhase) {
      // Phase 1: Calculate PnL, debit losers immediately, store winners' PnL
      uint256 phase1Iterations = _doPhase1(cycleId, settlementPrice, max);
      iterationsUsed += phase1Iterations;

      // If phase 1 is complete and we have iterations left, proceed to phase 2
      if (settlementPhase && iterationsUsed < max) {
        uint256 remainingIterations = max - iterationsUsed;
        _doPhase2(cycleId, remainingIterations, pauseNextCycle);
      }
    } else {
      // Phase 2: Credit winners pro-rata based on loss ratio
      _doPhase2(cycleId, max, pauseNextCycle);
    }
  }

  function startCycle() external whenNotPaused {
    _startCycle();
  }

  function _startCycle() internal {
    uint256 expiry = block.timestamp + DEFAULT_EXPIRY;
    if (activeCycle != 0) revert Errors.CycleActive();

    uint64 price = _getOraclePrice();

    // Create new market
    assembly {
      // Calculate storage slot for cycles[expiry]
      mstore(0x00, expiry)
      mstore(0x20, cycles.slot)
      let slot := keccak256(0x00, 0x40)

      // Pack struct: isSettled(1 byte) + strikePrice(8 bytes) + settlementPrice(8 bytes)
      // isSettled = false (0), strikePrice = price << 8, settlementPrice = 0
      let packedValue := shl(8, price)
      sstore(slot, packedValue)
    }

    // Set expiry as current market
    activeCycle = expiry;

    emit CycleStarted(expiry, uint256(price));
  }

  // #######################################################################
  // #                                                                     #
  // #                  Internal order placement helpers                   #
  // #                                                                     #
  // #######################################################################
  function _depositCollateral(uint256 amount, address trader) private {
    if (userAccounts[trader].liquidationQueued) revert Errors.AccountInLiquidation();
    if (amount == 0) revert Errors.InvalidAmount();

    IERC20(collateralToken).safeTransferFrom(trader, address(this), amount);
    unchecked {
      // Nobody is depositing 18 trillion USD to overflow this
      userAccounts[trader].balance += uint64(amount);
    }

    emit CollateralDeposited(trader, amount);
  }

  function _checkPremiumPaymentBalance(address trader, uint256 size, uint256 limitPrice) private view {
    if (size * limitPrice > userAccounts[trader].balance) revert Errors.InsufficientBalance();
  }

  function _placeOrder(
    MarketSide side,
    uint256 size,
    uint256 limitPrice, // 0 = market
    address trader
  ) private {
    if (!_isMarketLive()) revert Errors.MarketNotLive();
    if (userAccounts[trader].liquidationQueued) revert Errors.AccountInLiquidation();
    if (size == 0) revert Errors.InvalidAmount();
    userAccounts[trader].liquidationFeeOwed = 0;

    if (side == MarketSide.CALL_BUY || side == MarketSide.PUT_BUY) {
      _checkPremiumPaymentBalance(trader, size, limitPrice);
    }

    // Convert price to tick
    uint256 tick = limitPrice / TICK_SZ; // 1 tick = 0.01 USDT0

    bool isCrossing;
    uint256 orderbookLevelSize;
    (isCrossing, orderbookLevelSize) = _isCrossing(side, tick);

    int32 takerId = _nextTakerId(ob[activeCycle]);

    if (limitPrice == 0) {
      // Market order
      _marketOrder(side, uint128(size), trader, takerId);
    } else if (isCrossing) {
      // Consume orderbook levels until no longer crossing or fully filled
      uint256 remainingSize = size;

      while (isCrossing && remainingSize > 0) {
        // Consume this level (up to what's available and what we need)
        uint256 consumeSize = remainingSize < orderbookLevelSize ? remainingSize : orderbookLevelSize;

        // Execute market order for this level
        _marketOrder(side, uint128(consumeSize), trader, takerId);

        // Update remaining size
        remainingSize -= consumeSize;

        // Check if we still cross after consuming this level (and if we have remaining size)
        if (remainingSize > 0) (isCrossing, orderbookLevelSize) = _isCrossing(side, tick);
      }

      // If there's remaining size that doesn't cross, place as limit order
      if (remainingSize > 0) _limitOrder(side, remainingSize, limitPrice, trader);
    } else {
      // Limit order
      _limitOrder(side, size, limitPrice, trader);
    }

    if (userAccounts[trader].balance < _requiredMargin(trader, _getOraclePrice(), false)) {
      revert Errors.InsufficientBalance();
    }

    if (!userAccounts[trader].activeInCycle) {
      userAccounts[trader].activeInCycle = true;
      traders.push(trader);
    }
  }

  function _limitOrder(MarketSide side, uint256 size, uint256 limitPrice, address trader) private {
    uint256 tick = limitPrice / TICK_SZ;
    uint256 orderId = _nextMakerId(ob[activeCycle]);
    emit LimitOrderPlaced(activeCycle, orderId, size, tick * TICK_SZ, side, trader);
    uint256 qtyLeft = _matchQueuedTakers(side, size, uint256(tick) * TICK_SZ, uint32(orderId));
    if (qtyLeft != 0) _insertLimit(side, uint32(tick), uint128(qtyLeft), trader, uint32(orderId));
  }

  function _marketOrder(MarketSide side, uint128 want, address taker, int32 takerOrderId) private {
    emit TakerOrderPlaced(activeCycle, takerOrderId, want, side, taker);
    uint128 left = want;
    uint256 ac = activeCycle;
    OrderbookState storage _ob = ob[ac];
    mapping(uint32 => Level) storage levels = _ob.levels;
    mapping(uint32 => Maker) storage makerQ = _ob.makerNodes;

    MarketSide oppSide = _oppositeSide(side);

    while (left > 0) {
      {
        // Any liquidity left?
        uint256 sumOpp = _ob.summaries[uint256(oppSide)];
        if (sumOpp == 0) break; // No bits set in summary means empty book
      }

      // Best price level
      (uint32 bestTick, uint32 bestKey) = _best(oppSide);
      Level storage L = levels[bestKey];
      uint32 nodeId = L.head; // nodeId = orderId

      // Walk FIFO makers at this tick
      while (left > 0 && nodeId != 0) {
        Maker storage M = makerQ[nodeId];

        uint128 take = left < M.size ? left : M.size;

        uint128 taken = uint128(
          _settleFill(
            nodeId,
            takerOrderId,
            oppSide,
            uint256(bestTick) * TICK_SZ, // price
            take,
            taker, // taker
            M.trader, // maker
            _isBuy(side),
            false // isTakerQueue
          )
        );

        left -= taken;
        M.size -= taken;
        L.vol -= taken;

        if (M.size == 0) {
          // Remove node from queue
          uint32 nxt = M.next;
          if (nxt == 0) L.tail = 0;
          else makerQ[nxt].prev = 0;

          L.head = nxt;

          // Remove from user's order tracking
          _removeOrderFromTracking(M.trader, nodeId);

          delete makerQ[nodeId];
          nodeId = nxt;
        } else {
          break; // Taker satisfied
        }
      }

      // If price level empty, clear bitmaps
      if (L.vol == 0) _clearLevel(_oppositeSide(side), bestKey);
    }

    if (left > 0) _queueTaker(side, left, taker, takerOrderId);
  }

  function _matchQueuedTakers(
    MarketSide side,
    uint256 makerSize,
    uint256 price, // maker's price, 6-dec
    uint32 makerOrderId
  ) private returns (uint256 remainingMakerSize) {
    MarketSide oppSide = _oppositeSide(side);
    TakerQ[] storage Q = takerQ[uint256(oppSide)];
    uint256 i = tqHead[uint256(oppSide)];

    uint256 qLength = Q.length;
    remainingMakerSize = makerSize;

    while (remainingMakerSize > 0 && i < qLength) {
      TakerQ storage T = Q[i];
      if (T.size == 0) {
        ++i;
        continue;
      } // skip emptied slot

      TakerQ memory Tmem = Q[i]; // copy over for gas savings
      uint256 take = Tmem.size > remainingMakerSize ? remainingMakerSize : Tmem.size;

      uint256 taken = _settleFill(
        makerOrderId,
        Tmem.takerOrderId,
        side,
        price,
        take,
        Tmem.trader, // The (queued) taker
        _msgSender(), // The maker
        !_isBuy(side), // Taker is buy when maker's side is sell, which is when side is odd
        true // isTakerQueue
      );

      T.size -= uint64(taken);
      remainingMakerSize -= taken;

      if (T.size == 0 || taken == 0) ++i; // fully consumed
    }
    tqHead[uint256(_oppositeSide(side))] = i; // persist cursor
  }

  function _insertLimit(MarketSide side, uint32 tick, uint128 size, address trader, uint32 makerOrderId) private {
    // derive level bytes and key
    (uint8 l1, uint8 l2, uint8 l3) = BitScan.split(tick);
    uint32 key = _key(tick, side);

    uint256 ac = activeCycle;
    OrderbookState storage _ob = ob[ac];
    mapping(uint32 => Level) storage levels = _ob.levels;

    // if level empty, set bitmap bits
    if (levels[key].vol == 0) {
      bool firstInL1 = _addBits(_ob.dets[side], _ob.mids[side], l1, l2, l3);
      assert(_ob.mids[side][l1] & (1 << l2) != 0);

      if (firstInL1) _ob.summaries[uint256(side)] |= BitScan.mask(l1);
    }

    uint32 prev = levels[key].tail;

    // Assembly block which does:
    // _ob.makerNodes[makerOrderId] = Maker(trader, size, 0, key, prev);

    assembly {
      // Storage slot of ob[activeCycle]
      // keccak256(mapping key, mapping slot)
      mstore(0x00, ac) // key
      mstore(0x20, ob.slot) // mapping slot of `ob`
      let orderbookPos := keccak256(0x00, 0x40)

      // MakerNodes mapping inside OrderbookState, 7th slot inside OrderbookState
      let makerNodesPos := add(orderbookPos, 7)

      // Compute the slot of makerNodes[makerOrderId]
      // slot = keccak256(makerOrderId, makerNodesPos)
      mstore(0x00, makerOrderId)
      mstore(0x20, makerNodesPos)
      let nodeSlot := keccak256(0x00, 0x40)

      // Write the Maker struct (uses two storage words)
      // slot 0 : address trader
      sstore(nodeSlot, trader)

      // slot 1 -- size | next | key | prev
      // layout offsets (bytes): size[0-15] , next[16-19] , key[20-23] , prev[24-27]
      // next is zero, so we don’t OR it in.
      let packed := size // uint128  (16 bytes)
      // packed := next <---- is zero, so skip
      packed := or(packed, shl(160, key)) // key   @ byte 20
      packed := or(packed, shl(192, prev)) // prev  @ byte 24
      sstore(add(nodeSlot, 1), packed)
    }

    // Track order for user
    userOrders[trader].push(makerOrderId);

    // FIFO queue link
    if (levels[key].vol == 0) levels[key].head = makerOrderId;
    else _ob.makerNodes[levels[key].tail].next = makerOrderId;
    levels[key].tail = makerOrderId;
    levels[key].vol += size;

    UserAccount storage ua = userAccounts[trader];

    if (side == MarketSide.PUT_BUY) ua.pendingLongPuts += uint32(size);
    else if (side == MarketSide.PUT_SELL) ua.pendingShortPuts += uint32(size);
    else if (side == MarketSide.CALL_BUY) ua.pendingLongCalls += uint32(size);
    else ua.pendingShortCalls += uint32(size);
  }

  function _settleFill(
    uint32 makerOrderId,
    int32 takerOrderId,
    MarketSide side,
    uint256 price, // 6 decimals
    uint256 size,
    address taker,
    address maker,
    bool isTakerBuy,
    bool isTakerQueue
  ) internal returns (uint256) {
    UserAccount storage uaMaker = userAccounts[maker];
    UserAccount storage uaTaker = userAccounts[taker];

    // Check if this is a liquidation order (taker is being liquidated)
    bool isLiquidationOrder = takerOrderId < 0;

    // Fees accounting
    int256 cashTaker;
    int256 cashMaker;
    {
      int256 premium = int256(price) * int256(size); // always +ve

      // Dir signed direction from pov of taker: -1 when taker buys, since they're paying premium
      int256 dir = isTakerBuy ? int256(-1) : int256(1);

      // Calculate fees based on premium. makerFeeBps is negative, so it's a rebate. takerFeeBps is positive, so it's a
      // fee.
      int256 makerFee = premium * makerFeeBps / int256(denominator);
      int256 takerFee = premium * takerFeeBps / int256(denominator);

      // flip premium flow with dir
      cashMaker = -dir * premium - makerFee;
      cashTaker = dir * premium - takerFee;

      // We need a safeguard against the situation where the 'resting' party - and if they're a buyer paying premium -
      // has insufficient balance to pay the premium (for whatever reason). The 'resting party' is a limit order in the
      // orderbook, or a market order if it ends up in the takerQueue. Either of these scenarios could lead to denial of
      // service, so we remove the resting orders completelyorders
      if (!isLiquidationOrder) {
        if (isTakerQueue) {
          if (cashTaker < 0 && uaTaker.balance < uint256(-cashTaker)) {
            // Not enough USDC – leave the queue entry untouched, skip this fill
            return 0;
          }
        } else {
          if (cashMaker < 0 && uaMaker.balance < uint256(-cashMaker)) {
            // Remove maker from the book so it cannot block the market
            ob[activeCycle].makerNodes[makerOrderId].size = 0;
            return 0;
          }
        }
      }

      // Apply cash deltas - for liquidations. Max premium is user's balance, do not accrue bad debt
      if (isLiquidationOrder && uaTaker.balance < uint256(-cashTaker)) {
        // cashTaker is always negative (liquidatee is always buying)
        uint256 actualPremium = uaTaker.balance;

        // Calculate fees based on actual premium paid
        int256 adjustedMakerFee = int256(actualPremium) * makerFeeBps / int256(denominator);
        int256 adjustedTakerFee = int256(actualPremium) * takerFeeBps / int256(denominator);
        int256 houseFee = adjustedTakerFee + adjustedMakerFee;

        // Update price to how much user effectively paid. This should take into account the taker fees
        price = (actualPremium - uint256(adjustedTakerFee)) / size;

        // Maker gets the premium minus the net house fee
        int256 netToMaker = int256(actualPremium) - houseFee;

        cashMaker = netToMaker;
        cashTaker = -int256(actualPremium);
        uaTaker.balance = 0; // Zero out taker balance

        _applyCashDelta(maker, cashMaker);
        if (houseFee != 0) _applyCashDelta(feeRecipient, houseFee);
      } else {
        // Normal case: both parties have sufficient balance
        _applyCashDelta(maker, cashMaker);
        _applyCashDelta(taker, cashTaker);

        // Net to fee recipient. This should always be positive (unless makerFeeBps + takerFeeBps are set incorrectly)
        int256 houseFee = takerFee + makerFee;
        if (houseFee != 0) _applyCashDelta(feeRecipient, houseFee);
      }
    }

    // Position accounting
    {
      if (_isPut(side)) {
        if (isTakerBuy) {
          uaTaker.longPuts += uint32(size);
          uaMaker.shortPuts += uint32(size);
          if (!isTakerQueue) uaMaker.pendingShortPuts -= uint32(size);
          else uaTaker.pendingLongPuts -= uint32(size);
        } else {
          uaTaker.shortPuts += uint32(size);
          uaMaker.longPuts += uint32(size);
          if (!isTakerQueue) uaMaker.pendingLongPuts -= uint32(size);
          else uaTaker.pendingShortPuts -= uint32(size);
        }
      } else {
        if (isTakerBuy) {
          uaTaker.longCalls += uint32(size);
          uaMaker.shortCalls += uint32(size);
          if (!isTakerQueue) uaMaker.pendingShortCalls -= uint32(size);
          else uaTaker.pendingLongCalls -= uint32(size);
        } else {
          uaTaker.shortCalls += uint32(size);
          uaMaker.longCalls += uint32(size);
          if (!isTakerQueue) uaMaker.pendingLongCalls -= uint32(size);
          else uaTaker.pendingShortCalls -= uint32(size);
        }
      }
    }

    emit LimitOrderFilled(
      activeCycle, makerOrderId, takerOrderId, size, price, side, taker, maker, cashTaker, cashMaker, _getOraclePrice()
    );

    // Liquidation check
    {
      if (isLiquidationOrder) {
        uint256 shortCalls = uaTaker.shortCalls;
        uint256 shortPuts = uaTaker.shortPuts;
        uint256 longCalls = uaTaker.longCalls;
        uint256 longPuts = uaTaker.longPuts;

        if (longCalls >= shortCalls && longPuts >= shortPuts) uaTaker.liquidationQueued = false;
      }
    }

    return size;
  }

  function _queueTaker(MarketSide side, uint256 qty, address trader, int32 takerId) private {
    takerQ[uint256(side)].push(TakerQ({size: uint64(qty), trader: trader, takerOrderId: takerId}));
    UserAccount storage ua = userAccounts[trader];
    if (_isPut(side)) {
      if (_isBuy(side)) ua.pendingLongPuts += uint32(qty);
      else ua.pendingShortPuts += uint32(qty);
    } else {
      if (_isBuy(side)) ua.pendingLongCalls += uint32(qty);
      else ua.pendingShortCalls += uint32(qty);
    }

    emit TakerOrderRemaining(activeCycle, takerId, qty, side, trader);
  }

  function _cancelOrder(uint32 orderId) internal {
    uint256 ac = activeCycle;
    Maker memory M = ob[ac].makerNodes[orderId];
    uint32 key = M.key;
    Level storage L = ob[ac].levels[key];

    uint32 p = M.prev;
    uint32 n = M.next;

    if (p == 0) L.head = n;
    else ob[ac].makerNodes[p].next = n;
    if (n == 0) L.tail = p;
    else ob[ac].makerNodes[n].prev = p;

    L.vol -= M.size; // reduce resting volume
    UserAccount storage ua = userAccounts[M.trader];
    (uint32 tick, MarketSide side) = BitScan.splitKey(M.key);

    if (side == MarketSide.PUT_BUY) ua.pendingLongPuts -= uint32(M.size);
    else if (side == MarketSide.PUT_SELL) ua.pendingShortPuts -= uint32(M.size);
    else if (side == MarketSide.CALL_BUY) ua.pendingLongCalls -= uint32(M.size);
    else ua.pendingShortCalls -= uint32(M.size);

    _removeOrderFromTracking(M.trader, orderId);

    delete ob[ac].makerNodes[orderId]; // free storage

    if (L.vol == 0) _clearLevel(side, key);

    emit LimitOrderCancelled(ac, orderId, M.size, tick * TICK_SZ, M.trader);
  }

  function _cancelAllOrders(address trader) internal {
    uint32[] memory orderIds = userOrders[trader];
    for (uint256 k; k < orderIds.length; ++k) {
      uint32 id = orderIds[k];
      if (ob[activeCycle].makerNodes[id].trader == trader) _cancelOrder(id);
    }

    // Clear all taker queue entries for this trader
    _clearTakerQueueEntries(trader);

    // Clear user's order tracking
    _clearUserOrders(trader);
  }

  function _clearTakerQueueEntries(address trader) internal {
    UserAccount storage ua = userAccounts[trader];

    // Loop through all 4 taker queue buckets
    for (uint256 i = 0; i < 4; ++i) {
      TakerQ[] storage queue = takerQ[i];
      uint256 j = tqHead[i];
      uint256 end = queue.length;
      while (j < end) {
        if (queue[j].trader == trader && queue[j].size > 0) {
          uint64 size = queue[j].size;

          // Update pending positions based on market side
          MarketSide side = MarketSide(i);
          if (side == MarketSide.CALL_BUY) ua.pendingLongCalls -= uint32(size);
          else if (side == MarketSide.CALL_SELL) ua.pendingShortCalls -= uint32(size);
          else if (side == MarketSide.PUT_BUY) ua.pendingLongPuts -= uint32(size);
          else ua.pendingShortPuts -= uint32(size);

          // Set size to 0 but don't remove to preserve queue ordering
          queue[j].size = 0;
        }

        ++j;
      }
    }
  }

  function _removeOrderFromTracking(address trader, uint32 orderId) internal {
    uint32[] storage orders = userOrders[trader];
    uint256 length = orders.length;

    // Find and remove the order ID (swap with last element and pop for gas efficiency)
    for (uint256 i = 0; i < length; ++i) {
      if (orders[i] == orderId) {
        orders[i] = orders[length - 1]; // Move last element to current position
        orders.pop(); // Remove last element
        break;
      }
    }
  }

  function _isCrossing(MarketSide side, uint256 tick) internal view returns (bool, uint256) {
    MarketSide oppSide = _oppositeSide(side);

    bool isCrossing;
    uint256 size;

    if (ob[activeCycle].summaries[uint256(oppSide)] != 0) {
      (uint32 oppBest, uint32 oppKey) = _best(oppSide);

      // Check crossing: even enum values (buys) use >=, odd enum values (sells) use <=
      isCrossing = (uint256(side) & 1) == 0 ? (tick >= oppBest) : (tick <= oppBest);
      if (isCrossing) size = ob[activeCycle].levels[oppKey].vol;
    }

    return (isCrossing, size);
  }

  function _nextMakerId(OrderbookState storage _ob) private returns (uint32 id) {
    if (_ob.limitOrderPtr == 0) id = 1;
    else id = _ob.limitOrderPtr + 2;
    _ob.limitOrderPtr = id;
  }

  function _nextTakerId(OrderbookState storage _ob) private returns (int32 id) {
    if (_ob.takerOrderPtr == 0) id = 2;
    else id = _ob.takerOrderPtr + 2;
    _ob.takerOrderPtr = id;
  }

  function _clearUserOrders(address trader) internal {
    assembly {
      // Compute the storage slot of userOrders[trader].length
      mstore(0x00, trader) // left-pad addr to 32 bytes
      mstore(0x20, userOrders.slot) // mappings base slot
      let slot := keccak256(0x00, 0x40)

      // Zero the length word — O(1) gas
      sstore(slot, 0)
    }
  }

  // #######################################################################
  // #                                                                     #
  // #                  Internal Orderbook helpers                         #
  // #                                                                     #
  // #######################################################################

  function _oppositeSide(MarketSide side) internal pure returns (MarketSide) {
    return MarketSide(uint256(side) ^ 1); // XOR 1 to flip the side
  }

  function _getOraclePrice() internal view returns (uint64) {
    (bool success, bytes memory result) = MARK_PX_PRECOMPILE.staticcall(abi.encode(0));
    if (!success) revert Errors.OraclePriceCallFailed();
    // Price always returned with 1 extra decimal, so subtract by 1 from USDT0 decimals.
    uint64 price = abi.decode(result, (uint64)) * uint64(10 ** (collateralDecimals - 1));
    return price;
  }

  function _best(MarketSide side) private view returns (uint32 tick, uint32 key) {
    uint256 summary = ob[activeCycle].summaries[uint256(side)];

    function (uint256) pure returns (uint8) sb = _sb(side);

    // For bids we want highest price (msb), for asks we want lowest price (lsb)
    uint8 l1 = sb(summary);
    uint8 l2 = sb(ob[activeCycle].mids[side][l1]);
    uint16 k12 = (uint16(l1) << 8) | l2;
    uint8 l3 = sb(ob[activeCycle].dets[side][k12]);

    tick = BitScan.join(l1, l2, l3);
    key = _key(tick, side);
    return (tick, key);
  }

  function _key(uint32 tick, MarketSide side) internal pure returns (uint32) {
    if (tick >= 1 << 24) revert();
    return tick | (_isPut(side) ? 1 << 31 : 0) | (_isBuy(side) ? 1 << 30 : 0);
  }

  function _sb(MarketSide side) internal pure returns (function (uint256) pure returns (uint8)) {
    return _isBuy(side) ? BitScan.msb : BitScan.lsb;
  }

  function _isPut(MarketSide side) internal pure returns (bool) {
    return side == MarketSide.PUT_BUY || side == MarketSide.PUT_SELL;
  }

  function _isBuy(MarketSide side) internal pure returns (bool) {
    return side == MarketSide.CALL_BUY || side == MarketSide.PUT_BUY;
  }

  /**
   * @notice Add bits to the orderbook on mid and detail level, and return bool to indicate if caller must set the
   * summary bit for l1.
   * @dev  Mark tick (l1,l2,l3) as non-empty.
   *       Returns true  -> caller must set the summary bit for l1.
   *       Returns false -> No change needed to summary bit.
   *
   * ticks are defined as [uint8, uint8, uint8] from the rightmost 24 bits of the tickKey:
   *
   * [1bit, 1bit, 6bits, 8bits, 8bits, 8bits]
   * [isPut, isBid, unused, l1, l2, l3]
   *
   * where l1, l2, l3 are summary, mid, and detail bit index respectively.
   *
   * Index system is LSB-based. Meaning that index 0 is right most bit, and index 255 is left most bit.
   */
  function _addBits(
    mapping(uint16 => uint256) storage dett, // detail  (L3)  bitmap
    mapping(uint8 => uint256) storage midd, // mid     (L2)  bitmap
    uint8 l1, // high    byte
    uint8 l2, // middle  byte
    uint8 l3 // low     byte
  ) internal returns (bool firstInL1) {
    uint16 detKey = (uint16(l1) << 8) | l2; // Word key for det[] mapping
    uint256 m3 = BitScan.mask(l3); // Isolate bit l3

    // If this is the very first order at (l1,l2,l3) …
    if (dett[detKey] & m3 == 0) {
      dett[detKey] |= m3; // Flip the detail bit

      uint256 m2 = BitScan.mask(l2); // Bit mask for mid bitmap
      // If this tick is the first in its 256-tick block
      if (midd[l1] & m2 == 0) {
        midd[l1] |= m2; // Set the mid-level bit
        return true; // Caller must set summary bit for l1
      }
    }
    return false;
  }

  /**
   * @dev  Clear bits on mid and detail level, and return bool to indicate if caller must clear the summary bit for l1.
   *       Returns true  -> caller must clear summary bit for l1.
   *       Returns false -> summary still has other blocks.
   */
  function _clrBits(MarketSide side, uint8 l1, uint8 l2, uint8 l3) internal returns (bool lastInL1) {
    mapping(uint8 => uint256) storage mid = ob[activeCycle].mids[side];
    mapping(uint16 => uint256) storage det = ob[activeCycle].dets[side];

    uint16 detKey = (uint16(l1) << 8) | l2; // Locate detail word
    det[detKey] &= ~BitScan.mask(l3); // Clear bit l3

    // If no ticks left in this 256-tick word
    if (det[detKey] == 0) {
      mid[l1] &= ~BitScan.mask(l2); // Clear mid-level bit
      // If no 256-tick words left in this 65 k-tick block
      if (mid[l1] == 0) return true; // Caller must clear summary bit
    }
    return false;
  }

  function _clearLevel(MarketSide side, uint32 key) private {
    (uint32 tick,) = BitScan.splitKey(key);
    (uint8 l1, uint8 l2, uint8 l3) = BitScan.split(tick);

    // Clear bitmaps
    bool lastInL1 = _clrBits(side, l1, l2, l3);
    if (lastInL1) ob[activeCycle].summaries[uint256(side)] &= ~BitScan.mask(l1);

    delete ob[activeCycle].levels[key];
  }

  // #######################################################################
  // #                                                                     #
  // #             Internal position and settlement helpers                #
  // #                                                                     #
  // #######################################################################

  function _hasOpenPositionsOrOrders(address trader) internal view returns (bool) {
    UserAccount storage a = userAccounts[trader];

    return (
      a.longCalls | a.shortCalls | a.longPuts | a.shortPuts | a.pendingLongCalls | a.pendingShortCalls
        | a.pendingLongPuts | a.pendingShortPuts
    ) != 0;
  }

  function _isMarketLive() internal view returns (bool) {
    uint256 ac = activeCycle;
    return block.timestamp < ac && ac != 0;
  }

  function _applyCashDelta(address user, int256 delta) private {
    if (delta > 0) {
      userAccounts[user].balance += uint64(uint256(delta));
    } else if (delta < 0) {
      uint256 absVal = uint256(-delta);
      if (userAccounts[user].balance < absVal) revert Errors.InsufficientBalance();
      userAccounts[user].balance -= uint64(absVal);
    }
  }

  function _clearAllPositions(address trader) internal {
    UserAccount storage ua = userAccounts[trader];
    ua.liquidationQueued = false;
    ua.liquidationFeeOwed = 0;
    ua.activeInCycle = false;
    // Zero out second slot in UserAccount struct, which contains all the individual positions data
    assembly {
      let slot := ua.slot
      sstore(add(slot, 1), 0)
    }

    _clearUserOrders(trader);
  }

  function _requiredMargin(
    address trader,
    uint256 currentPrice, // oracle price, 6-decimals USDC
    bool isLiquidation
  ) internal view returns (uint256) {
    UserAccount memory ua = userAccounts[trader];

    uint256 netShortCalls;
    uint256 netShortPuts;
    // Net short exposure (calls & puts)
    if (isLiquidation) {
      netShortCalls = ua.shortCalls > ua.longCalls ? ua.shortCalls - ua.longCalls : 0;
      netShortPuts = ua.shortPuts > ua.longPuts ? ua.shortPuts - ua.longPuts : 0;
    } else {
      netShortCalls = ua.shortCalls + ua.pendingShortCalls > ua.longCalls + ua.pendingLongCalls
        ? ua.shortCalls + ua.pendingShortCalls - ua.longCalls - ua.pendingLongCalls
        : 0;
      netShortPuts = ua.shortPuts + ua.pendingShortPuts > ua.longPuts + ua.pendingLongPuts
        ? ua.shortPuts + ua.pendingShortPuts - ua.longPuts - ua.pendingLongPuts
        : 0;
    }

    if (netShortCalls == 0 && netShortPuts == 0) return 0;

    // Liabilities
    uint256 strike = cycles[activeCycle].strikePrice; // 6-decimals
    uint256 callLiability = currentPrice > strike ? (currentPrice - strike) * netShortCalls / CONTRACT_SIZE : 0;
    uint256 putLiability = strike > currentPrice ? (strike - currentPrice) * netShortPuts / CONTRACT_SIZE : 0;

    uint256 currentLoss = callLiability + putLiability; // USDC, 6-dec

    // 0.10 % buffer on strike notional
    uint256 notional = (netShortCalls + netShortPuts) * strike / CONTRACT_SIZE;
    uint256 buffer = notional * MM_BPS / denominator; // 0.10 % of notional

    return currentLoss + buffer;
  }

  function isLiquidatable(address trader) public view returns (bool) {
    return isLiquidatable(trader, _getOraclePrice());
  }

  function isLiquidatable(address trader, uint64 price) public view returns (bool) {
    UserAccount storage ua = userAccounts[trader];
    if (ua.liquidationQueued) return false;
    return ua.balance < _requiredMargin(trader, price, true);
  }

  function _calculateTraderPnl(uint256 cycleId, uint64 price, address trader) internal view returns (int256 pnl) {
    UserAccount memory uaMem = userAccounts[trader];
    if ((uaMem.longCalls | uaMem.shortCalls | uaMem.longPuts | uaMem.shortPuts) == 0) return 0;
    uint64 strike = cycles[cycleId].strikePrice;
    // 1) Calls in-the-money   (price > strike)
    if (price > strike) {
      uint256 intrinsic = price - strike;
      int256 netCalls = int256(uint256(uaMem.longCalls)) - int256(uint256(uaMem.shortCalls));
      pnl = int256(intrinsic) * netCalls / int256(CONTRACT_SIZE);
      return pnl;
    }
    // 2) Puts in-the-money   (price < strike)
    if (price < strike) {
      uint256 intrinsic = strike - price;
      int256 netPuts = int256(uint256(uaMem.longPuts)) - int256(uint256(uaMem.shortPuts));
      pnl = int256(intrinsic) * netPuts / int256(CONTRACT_SIZE);
      return pnl;
    }
    return 0;
  }

  function _doPhase1(uint256 cycleId, uint64 price, uint256 max) internal returns (uint256) {
    uint256 n = traders.length;
    uint256 i = cursor;
    uint256 upper = i + max;
    if (upper > n) upper = n;

    uint256 startingI = i;

    uint256 _posSum;

    while (i < upper) {
      address trader = traders[i];
      UserAccount storage ua = userAccounts[trader];

      // 1. intrinsic PnL at settlement price
      int256 pnl = _calculateTraderPnl(cycleId, price, trader);
      bool liq = (ua.liquidationFeeOwed > 0) || ua.liquidationQueued;

      if (!liq) {
        //  ──------------------ Normal Account ────────────────────────
        if (pnl < 0) {
          uint256 debit = uint256(-pnl);
          uint256 paid = debit > ua.balance ? ua.balance : debit;
          ua.balance -= uint64(paid);
          if (debit > paid) badDebt += debit - paid;
          emit Settled(cycleId, trader, pnl);
        } else if (pnl > 0) {
          ua.scratchPnL = uint64(uint256(pnl));
          _posSum += uint256(pnl);
        } else {
          emit Settled(cycleId, trader, 0);
        }
      } else {
        //  ──------------------ Liquidation Account ────────────────────────

        // Seize their entire balance, add |pnl| to badDebt
        uint64 balance = ua.balance;
        if (balance > 0) userAccounts[feeRecipient].balance += balance;

        // pnl can never be positive for liquidated accounts, since they never have leftover long exposure
        badDebt += uint256(-pnl);
        ua.balance = 0; // user never keeps anything
        ua.liquidationFeeOwed = 0;
        emit Settled(cycleId, trader, -int256(uint256(balance)));
      }

      _clearAllPositions(trader);
      unchecked {
        ++i;
      }
    }
    posSum = _posSum;
    cursor = i;

    if (i == n) {
      // Phase 1 complete - calculate loss ratio and prepare for phase 2
      settlementPhase = true;
      cursor = 0; // Reset cursor for phase 2
    }

    return i - startingI;
  }

  function _doPhase2(uint256 cycleId, uint256 max, bool pauseNextCycle) internal {
    Cycle storage C = cycles[cycleId];
    uint256 n = traders.length;
    uint256 i = cursor;
    uint256 upper = i + max;
    if (upper > n) upper = n;

    // Calculate loss ratio once (using 1e12 precision)
    uint256 lossRatio;

    if (posSum == 0 || badDebt >= posSum) {
      lossRatio = denominator;
    } else {
      // partial social-loss haircut
      lossRatio = (badDebt * denominator) / posSum;
    }

    while (i < upper) {
      address trader = traders[i];
      uint256 rawPnl = userAccounts[trader].scratchPnL;

      if (rawPnl > 0) {
        // Credit winner pro-rata
        uint256 credit = rawPnl * (denominator - lossRatio) / denominator;
        userAccounts[trader].balance += uint64(credit);

        // Emit event with the actual credited amount (after social loss)
        emit Settled(cycleId, trader, int256(credit));

        userAccounts[trader].scratchPnL = 0; // Gas refund
      }

      unchecked {
        ++i;
      }
    }
    cursor = i;

    if (i == n) {
      // Phase 2 complete - clean up everything
      assembly {
        sstore(traders.slot, 0)
      }
      delete takerQ;
      delete tqHead;

      cursor = 0;
      posSum = 0;
      badDebt = 0;
      settlementPhase = false;
      C.isSettled = true;
      activeCycle = 0;

      emit CycleSettled(cycleId);

      // Automatically start new cycle unless in settlement-only mode
      if (!pauseNextCycle) _startCycle();
    }
  }

  function _checkActiveCycle(uint256 cycleId) internal view {
    if (cycleId != 0 && cycleId != activeCycle) revert Errors.InvalidCycle();
  }

  // #######################################################################
  // #                                                                     #
  // #             Extension functions                                     #
  // #                                                                     #
  // #######################################################################

  function setExtension(address ext) external onlyOwner {
    extensionContract = ext;
  }

  /// @dev delegate everything we don’t recognise
  fallback() external {
    address ext = extensionContract;
    assembly {
      calldatacopy(0, 0, calldatasize())
      let result := delegatecall(gas(), ext, 0, calldatasize(), 0, 0)
      returndatacopy(0, 0, returndatasize())
      if iszero(result) { revert(0, returndatasize()) }
      return(0, returndatasize())
    }
  }

  // #######################################################################
  // #                                                                     #
  // #             Other helpers and views                                 #
  // #                                                                     #
  // #######################################################################

  function trustedForwarder() public view override returns (address) {
    return _trustedForwarder;
  }

  function _msgSender() internal view override(ERC2771ContextUpgradeable, ContextUpgradeable) returns (address sender) {
    return ERC2771ContextUpgradeable._msgSender();
  }

  function _msgData() internal view override(ERC2771ContextUpgradeable, ContextUpgradeable) returns (bytes calldata) {
    return ERC2771ContextUpgradeable._msgData();
  }

  function _contextSuffixLength()
    internal
    view
    override(ERC2771ContextUpgradeable, ContextUpgradeable)
    returns (uint256)
  {
    return ERC2771ContextUpgradeable._contextSuffixLength();
  }

  modifier isValidSignature(bytes memory signature) {
    if (WHITELIST_SIGNER != ECDSA.recover(keccak256(abi.encodePacked(_msgSender())), signature)) {
      revert Errors.InvalidWhitelistSignature();
    }
    _;
  }

  // #######################################################################
  // #                                                                     #
  // #                       Admin functions                               #
  // #                                                                     #
  // #######################################################################

  function pause() external {
    _onlySecurityCouncil();
    _pause();
  }

  function unpause() external {
    _onlySecurityCouncil();
    _unpause();
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

  modifier onlyWhitelisted() {
    if (!whitelist[_msgSender()]) revert Errors.NotWhitelisted();
    _;
  }

  function _onlySecurityCouncil() internal view {
    if (_msgSender() != SECURITY_COUNCIL) revert Errors.NotSecurityCouncil();
  }
}
