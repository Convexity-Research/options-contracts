// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

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

import "forge-std/console2.sol";

contract Market is
  IMarket,
  Initializable,
  UUPSUpgradeable,
  OwnableUpgradeable,
  PausableUpgradeable,
  ERC2771ContextUpgradeable
{
  using SafeERC20 for IERC20;

  //------- Meta -------
  string public name;
  address public feeRecipient;
  address public collateralToken;
  uint256 constant collateralDecimals = 6;
  address constant ORACLE_PX_PRECOMPILE = 0x0000000000000000000000000000000000000807;
  uint256 constant TICK_SZ = 1e4; // 0.01 USDT0 → 10 000 wei (only works for 6-decimals tokens)
  uint256 constant MAX_OPEN_LIMIT_ORDERS = 8; // Max number of open limit orders per user
  uint256 public constant MM_BPS = 10; // 0.10 % Maintenance Margin (also used in place of an initial margin)
  uint256 constant CONTRACT_SIZE = 100; // Divide by this factor for 0.01BTC
  int256 constant makerFeeBps = -20; // -0.20 %, basis points. Negative means its a fee rebate, so pay out to makers
  int256 constant takerFeeBps = 100; // +1.00 %, basis points
  uint256 constant liquidationFeeBps = 10; // 0.1 %, basis points
  uint256 constant denominator = 10_000;

  //------- Gasless TX -------
  address private _trustedForwarder;

  //------- Whitelist -------
  address private constant WHITELIST_SIGNER = 0x1FaE1550229fE09ef3e266d8559acdcFC154e72f;
  mapping(address => bool) public whitelist;

  //------- user account -------
  mapping(address => UserAccount) public userAccounts;

  struct UserAccount {
    bool activeInCycle;
    bool liquidationQueued;
    uint64 balance;
    uint64 liquidationFeeOwed;
    uint64 scratchPnL;
    uint48 _gap; // 48 remaining bits for future use. Packs position data into next slot
    uint32 longCalls;
    uint32 shortCalls;
    uint32 longPuts;
    uint32 shortPuts;
    uint32 pendingLongCalls;
    uint32 pendingShortCalls;
    uint32 pendingLongPuts;
    uint32 pendingShortPuts;
  }

  //------- Cycle state -------
  uint256 public activeCycle; // expiry unix timestamp as ID
  mapping(uint256 => Cycle) public cycles;

  //------- Trading/Settlement -------
  address[] public traders;
  mapping(address => uint32[]) public userOrders; // Track all order IDs per user
  uint256 public cursor; // settlement iterator

  TakerQ[][4] internal takerQ; // 4 buckets
  uint256[4] public tqHead; // cursor per bucket

  // Two-phase settlement for fair social loss distribution
  uint256 posSum; // total positive PnL (winners)
  uint256 badDebt; // grows whenever we meet an under-collateralised loser
  bool settlementPhase; // false = phase 1, true = phase 2

  //------- Orderbook -------
  mapping(uint256 => OrderbookState) internal ob;

  struct OrderbookState {
    // summary level of orderbook (L1): which [256*256] blocks have liquidity
    uint256[4] summaries;
    // mid level of orderbook (L2): which [256] block has liquidity
    mapping(MarketSide => mapping(uint8 => uint256)) mids;
    // detail level of orderbook (L3): which tick has liquidity
    mapping(MarketSide => mapping(uint16 => uint256)) dets;
    // mappings to fetch relevant orderbook data
    mapping(uint32 => Level) levels; // tickKey ⇒ Level
    mapping(uint32 => Maker) makerNodes; // nodeId  ⇒ Maker
    uint32 limitOrderPtr; // auto-increment id for limit orders
    uint32 takerOrderPtr; // auto-increment id for taker orders
  }

  //------- Events -------
  event CycleStarted(uint256 indexed cycleId, uint256 strike);
  event CycleSettled(uint256 indexed cycleId);
  event CollateralDeposited(address indexed trader, uint256 amount);
  event CollateralWithdrawn(address indexed trader, uint256 amount);
  event Liquidated(uint256 indexed cycleId, address indexed trader);
  event PriceFixed(uint256 indexed cycleId, uint64 price);
  event Settled(uint256 indexed cycleId, address indexed trader, int256 pnl);
  event OrderPlaced(
    uint256 indexed cycleId, uint256 orderId, uint256 size, uint256 limitPrice, MarketSide side, address indexed maker
  );
  event OrderFilled(
    uint256 indexed cycleId,
    uint256 makerOrderId,
    uint256 takerOrderId,
    uint256 size,
    uint256 limitPrice,
    MarketSide side,
    address indexed taker,
    address indexed maker,
    int256 cashTaker,
    int256 cashMaker,
    uint256 btcPrice
  );
  event OrderCancelled(
    uint256 indexed cycleId, uint256 orderId, uint256 size, uint256 limitPrice, address indexed maker
  );
  event TakerOrderPlaced(
    uint256 indexed cycleId, uint32 takerOrderId, uint256 size, MarketSide side, address indexed taker
  );
  event TakerOrderRemaining(
    uint256 indexed cycleId, uint32 takerOrderId, uint256 size, MarketSide side, address indexed taker
  );

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() ERC2771ContextUpgradeable(address(0)) {
    _disableInitializers();
  }

  function initialize(string memory _name, address _feeRecipient, address _collateralToken, address _forwarder)
    external
    initializer
  {
    __Ownable_init(_msgSender());
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
  function depositCollateral(uint256 amount, bytes memory signature) external isValidSignature(signature) {
    address trader = _msgSender();
    whitelist[trader] = true;
    _depositCollateral(amount, trader);
  }

  function depositCollateral(uint256 amount) external onlyWhitelisted {
    address trader = _msgSender();
    _depositCollateral(amount, trader);
  }

  function withdrawCollateral(uint256 amount) external onlyWhitelisted {
    address trader = _msgSender();
    _withdrawCollateral(amount, trader);
  }

  function long(uint256 size) external onlyWhitelisted {
    address trader = _msgSender();

    _placeOrder(MarketSide.CALL_BUY, size, 0, trader);
    _placeOrder(MarketSide.PUT_SELL, size, 0, trader);
  }

  function short(uint256 size) external onlyWhitelisted {
    address trader = _msgSender();

    _placeOrder(MarketSide.PUT_BUY, size, 0, trader);
    _placeOrder(MarketSide.CALL_SELL, size, 0, trader);
  }

  function placeOrder(MarketSide side, uint256 size, uint256 limitPrice)
    external
    onlyWhitelisted
    returns (uint256 orderId)
  {
    address trader = _msgSender();
    _placeOrder(side, size, limitPrice, trader);
    return 0;
  }

  function cancelOrder(uint256 orderId) external {
    require(_isMarketLive(), "Market not live");
    address trader = _msgSender();
    require(!isLiquidatable(trader, _getOraclePrice()), "Cannot cancel order while liquidatable");

    Maker storage M = ob[activeCycle].makerNodes[uint32(orderId)];
    require(M.trader == trader, "Not owner");

    uint32 tickKey = M.key;
    Level storage L = ob[activeCycle].levels[tickKey];

    mapping(uint32 => Maker) storage makerNodes = ob[activeCycle].makerNodes;

    uint32 p = M.prev;
    uint32 n = M.next;

    // unlink from neighbours
    if (p == 0) L.head = n; // cancelled head

    else makerNodes[p].next = n;

    if (n == 0) L.tail = p; // cancelled tail

    else makerNodes[n].prev = p;

    // adjust volume
    L.vol -= M.size;

    (uint32 tick, MarketSide side) = BitScan.splitKey(tickKey);
    if (L.vol == 0) _clearLevel(side, tick);

    UserAccount storage P = userAccounts[M.trader];

    if (side == MarketSide.PUT_BUY) P.pendingLongPuts -= uint32(M.size);
    else if (side == MarketSide.PUT_SELL) P.pendingShortPuts -= uint32(M.size);
    else if (side == MarketSide.CALL_BUY) P.pendingLongCalls -= uint32(M.size);
    else if (side == MarketSide.CALL_SELL) P.pendingShortCalls -= uint32(M.size);
    else revert("Invalid side");

    // Remove from user's order tracking
    _removeOrderFromTracking(M.trader, uint32(orderId));

    emit OrderCancelled(activeCycle, orderId, M.size, tick * TICK_SZ, M.trader);
    delete makerNodes[uint32(orderId)];
  }

  function liquidate(address trader) external {
    require(_isMarketLive(), "Market not live");
    uint64 price = _getOraclePrice();
    require(isLiquidatable(trader, price), "Not liquidatable");

    // Cancel all maker orders
    uint32[] memory orderIds = userOrders[trader];
    for (uint256 k; k < orderIds.length; ++k) {
      uint32 id = orderIds[k];
      // Double check order still exists before cancelling
      if (ob[activeCycle].makerNodes[id].trader == trader) _forceCancel(id);
    }

    // Clear all taker queue entries for this trader
    _clearTakerQueueEntries(trader);

    // Clear user's order tracking
    delete userOrders[trader];

    UserAccount storage ua = userAccounts[trader];
    uint256 shortCalls = ua.shortCalls > ua.longCalls ? ua.shortCalls - ua.longCalls : 0;
    uint256 shortPuts = ua.shortPuts > ua.longPuts ? ua.shortPuts - ua.longPuts : 0;

    // Calculate liquidation fee based on notional value of NET position being liquidated
    uint256 liquidationFee = (shortCalls + shortPuts) * price * liquidationFeeBps / denominator / CONTRACT_SIZE;

    ua.liquidationFeeOwed = uint64(liquidationFee);
    ua.liquidationQueued = true;

    // Now execute market orders to close positions
    // Users may have insufficient balance to cover buying the puts/calls, but this is handled in _marketOrder
    if (shortCalls > 0) _marketOrder(MarketSide.CALL_BUY, uint128(shortCalls), trader, 0);
    if (shortPuts > 0) _marketOrder(MarketSide.PUT_BUY, uint128(shortPuts), trader, 0);

    emit Liquidated(activeCycle, trader);
  }

  function settleChunk(uint256 max) external {
    uint256 cycleId = activeCycle;
    Cycle storage C = cycles[cycleId];
    uint64 settlementPrice = C.settlementPrice;

    if (settlementPrice == 0) {
      require(block.timestamp >= activeCycle, "Not expired");
      settlementPrice = _getOraclePrice();
      C.settlementPrice = settlementPrice;
      emit PriceFixed(activeCycle, settlementPrice);
    }

    require(!C.isSettled, "Cycle already settled");

    if (!settlementPhase) {
      // Phase 1: Calculate PnL, debit losers immediately, store winners' PnL
      _doPhase1(cycleId, settlementPrice, max);
    } else {
      // Phase 2: Credit winners pro-rata based on loss ratio
      _doPhase2(cycleId, max);
    }
  }

  function _doPhase1(uint256 cycleId, uint64 price, uint256 max) internal {
    uint256 n = traders.length;
    uint256 i = cursor;
    uint256 upper = i + max;
    if (upper > n) upper = n;

    while (i < upper) {
      address trader = traders[i];

      // Charge liquidation fee, if any
      _chargeLiquidationFee(trader);

      int256 pnl = _calculateTraderPnl(cycleId, price, trader);

      UserAccount storage ua = userAccounts[trader];
      if (pnl < 0) {
        // Loser - debit immediately
        uint256 debit = uint256(-pnl);
        uint256 balance = ua.balance;
        uint256 amountPaid = balance < debit ? balance : debit;

        ua.balance -= uint64(amountPaid);
        uint256 unpaid = debit - amountPaid;
        badDebt += unpaid;

        emit Settled(cycleId, trader, pnl);
      } else if (pnl > 0) {
        // Winner - store PnL for phase 2
        ua.scratchPnL = uint64(uint256(pnl));
        posSum += uint256(pnl);
      }
      // If pnl == 0, do nothing but still emit event
      else {
        emit Settled(cycleId, trader, 0);
      }

      _clearAllPositions(trader);

      unchecked {
        ++i;
      }
    }
    cursor = i;

    if (i == n) {
      // Phase 1 complete - calculate loss ratio and prepare for phase 2
      settlementPhase = true;
      cursor = 0; // Reset cursor for phase 2
    }
  }

  // Currently we eat the loss and don't socialize it if the user can't pay full liquidation fee
  function _chargeLiquidationFee(address trader) internal {
    UserAccount storage ua = userAccounts[trader];
    if (ua.liquidationFeeOwed > 0) {
      uint256 fee = ua.liquidationFeeOwed;
      uint256 pay = ua.balance < fee ? ua.balance : fee;
      ua.balance -= uint64(pay);
      ua.liquidationFeeOwed -= uint64(pay);
      _applyCashDelta(feeRecipient, int256(pay));
    }
  }

  function _doPhase2(uint256 cycleId, uint256 max) internal {
    Cycle storage C = cycles[cycleId];
    uint256 n = traders.length;
    uint256 i = cursor;
    uint256 upper = i + max;
    if (upper > n) upper = n;

    // Calculate loss ratio once (using 1e12 precision)
    uint256 lossRatio = posSum == 0 ? 1e12 : (badDebt * 1e12 < posSum ? badDebt * 1e12 / posSum : 1e12);

    while (i < upper) {
      address trader = traders[i];
      uint256 rawPnl = userAccounts[trader].scratchPnL;

      if (rawPnl > 0) {
        // Credit winner pro-rata
        uint256 credit = rawPnl * (1e12 - lossRatio) / 1e12;
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
      delete traders;
      delete takerQ;
      delete tqHead;

      cursor = 0;
      posSum = 0;
      badDebt = 0;
      settlementPhase = false;
      C.isSettled = true;
      activeCycle = 0;

      emit CycleSettled(cycleId);
    }
  }

  function _calculateTraderPnl(uint256 cycleId, uint64 price, address trader) internal view returns (int256 pnl) {
    UserAccount memory uaMem = userAccounts[trader];
    if ((uaMem.longCalls | uaMem.shortCalls | uaMem.longPuts | uaMem.shortPuts) == 0) return 0;

    /* intrinsic of calls */
    int256 diff = int256(uint256(price)) - int256(uint256(cycles[cycleId].strikePrice));
    if (diff > 0) {
      // long calls win
      pnl += diff * int256(uint256(uaMem.longCalls)) / int256(CONTRACT_SIZE);
      pnl -= diff * int256(uint256(uaMem.shortCalls)) / int256(CONTRACT_SIZE);
    } else {
      // short calls win
      pnl += diff * int256(uint256(uaMem.longCalls)) / int256(CONTRACT_SIZE);
      pnl -= diff * int256(uint256(uaMem.shortCalls)) / int256(CONTRACT_SIZE);
    }

    /* intrinsic of puts (mirror) */
    diff = int256(uint256(cycles[cycleId].strikePrice)) - int256(uint256(price));
    if (diff > 0) {
      pnl += diff * int256(uint256(uaMem.longPuts)) / int256(CONTRACT_SIZE);
      pnl -= diff * int256(uint256(uaMem.shortPuts)) / int256(CONTRACT_SIZE);
    } else {
      pnl += diff * int256(uint256(uaMem.longPuts)) / int256(CONTRACT_SIZE);
      pnl -= diff * int256(uint256(uaMem.shortPuts)) / int256(CONTRACT_SIZE);
    }

    return pnl;
  }

  function startCycle(uint256 expiry) external {
    if (activeCycle != 0) {
      // If there is an active cycle, it must be in the past
      require(activeCycle < block.timestamp, "Cycle already started");

      // The previous cycle must be settled
      require(cycles[activeCycle].isSettled, "Previous cycle not settled");
    }

    uint64 price = _getOraclePrice();
    require(price != 0, "Invalid oracle price");

    // Create new market
    cycles[expiry] = Cycle({
      isSettled: false,
      strikePrice: price,
      settlementPrice: 0 // Settlement price is set at cycle end time
    });

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
    require(amount > 0, "Invalid amount");

    IERC20(collateralToken).safeTransferFrom(trader, address(this), amount);
    unchecked {
      // Nobody is depositing 18 trillion USD to overflow this
      userAccounts[trader].balance += uint64(amount);
    }

    emit CollateralDeposited(trader, amount);
  }

  function _withdrawCollateral(uint256 amount, address trader) private {
    require(amount > 0, "Invalid amount");
    require(!_hasOpenPositionsOrOrders(trader), "In trader list");

    uint256 balance = userAccounts[trader].balance;
    require(balance >= amount, "Insufficient balance");

    unchecked {
      // We check amount above, and this saves some gas + code size
      userAccounts[trader].balance -= uint64(amount);
    }

    IERC20(collateralToken).safeTransfer(trader, amount);

    emit CollateralWithdrawn(trader, amount);
  }

  function _placeOrder(
    MarketSide side,
    uint256 size,
    uint256 limitPrice, // 0 = market
    address trader
  ) private {
    require(_isMarketLive(), "Market not live");
    require(!userAccounts[trader].liquidationQueued, "Account in liquidation");
    require(size > 0, "Invalid amount");

    // Convert price to tick
    uint256 tick = limitPrice / TICK_SZ; // 1 tick = 0.01 USDT0

    if (limitPrice == 0 || _isCrossing(side, tick)) {
      // Market order
      uint32 takerId = _nextTakerId(ob[activeCycle]);
      emit TakerOrderPlaced(activeCycle, takerId, size, side, trader);
      _marketOrder(side, uint128(size), trader, takerId);
    } else {
      // Limit order
      uint256 orderId = _nextMakerId(ob[activeCycle]);
      uint256 qtyLeft = _matchQueuedTakers(side, size, uint256(tick) * TICK_SZ, uint32(orderId));
      if (qtyLeft != 0) _insertLimit(side, uint32(tick), uint128(qtyLeft), trader, uint32(orderId));
    }

    if (userAccounts[trader].balance < _requiredMarginForOrder(trader, _getOraclePrice(), MM_BPS)) {
      require(false, "Insufficient balance");
    }
  }

  function _marketOrder(MarketSide side, uint128 want, address taker, uint32 takerOrderId) private {
    uint128 left = want;
    uint256 ac = activeCycle;
    OrderbookState storage _ob = ob[ac];
    mapping(uint32 => Level) storage levels = _ob.levels;
    mapping(uint32 => Maker) storage makerQ = _ob.makerNodes;

    while (left > 0) {
      {
        // Any liquidity left?
        uint256 sumOpp = _ob.summaries[uint256(_oppositeSide(side))];
        if (sumOpp == 0) break; // No bits set in summary means empty book
      }

      // Best price level
      (uint32 bestTick, uint32 bestKey) = _best(_oppositeSide(side));
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
            side,
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
        oppSide, // OPPSIDE PASSED HERE JUST SO EVENTS ARE ALWAYS FROM TAKER POV. This is a footgun but will do for now
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
    require(userOrders[trader].length < MAX_OPEN_LIMIT_ORDERS, "Maximum orders cap reached");

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

    _ob.makerNodes[makerOrderId] = Maker(trader, size, 0, key, levels[key].tail);

    // Track order for user
    userOrders[trader].push(makerOrderId);

    // FIFO queue link
    if (levels[key].vol == 0) levels[key].head = makerOrderId;
    else _ob.makerNodes[levels[key].tail].next = makerOrderId;
    levels[key].tail = makerOrderId;
    levels[key].vol += size;

    // position table
    if (!userAccounts[trader].activeInCycle) {
      userAccounts[trader].activeInCycle = true;
      traders.push(trader);
    }
    UserAccount storage ua = userAccounts[trader];

    if (side == MarketSide.PUT_BUY) ua.pendingLongPuts += uint32(size);
    else if (side == MarketSide.PUT_SELL) ua.pendingShortPuts += uint32(size);
    else if (side == MarketSide.CALL_BUY) ua.pendingLongCalls += uint32(size);
    else if (side == MarketSide.CALL_SELL) ua.pendingShortCalls += uint32(size);
    else revert("Invalid side");

    emit OrderPlaced(ac, makerOrderId, size, tick * TICK_SZ, side, trader);
  }

  function _settleFill(
    uint32 makerOrderId,
    uint32 takerOrderId,
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
    bool isLiquidationOrder = uaTaker.liquidationQueued;

    // Fees accounting
    int256 cashTaker;
    int256 cashMaker;
    {
      int256 premium = int256(price) * int256(size); // always +ve

      // Dir signed direction from pov of taker: -1 when taker buys, since they're paying premium
      int256 dir = isTakerBuy ? int256(-1) : int256(1);

      // Calculate fees based on premium
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
        if (isTakerQueue && isTakerBuy) {
          if (cashTaker < 0 && uaTaker.balance < uint256(-cashTaker)) {
            return 0;
          } else if (!isTakerQueue && !isTakerBuy) {
            ob[activeCycle].makerNodes[makerOrderId].size = 0;
            if (cashMaker < 0 && uaMaker.balance < uint256(-cashMaker)) return 0;
          }
        }
      }

      // Apply cash deltas - for liquidations, handle insufficient balance as bad debt
      if (isLiquidationOrder && cashTaker < 0 && uaTaker.balance < uint256(-cashTaker)) {
        // Liquidation order: taker doesn't have enough balance, add to bad debt
        uint256 shortfall = uint256(-cashTaker) - uaTaker.balance;
        badDebt += shortfall;
        uaTaker.balance = 0; // Zero out taker balance
        _applyCashDelta(maker, cashMaker); // Maker still gets paid normally
      } else {
        // Normal case: both parties have sufficient balance
        _applyCashDelta(maker, cashMaker);
        _applyCashDelta(taker, cashTaker);
      }

      // Net to fee recipient. This should always be positive (unless makerFeeBps + takerFeeBps are set incorrectly)
      int256 houseFee = takerFee + makerFee;
      if (houseFee != 0) _applyCashDelta(feeRecipient, houseFee);
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

    emit OrderFilled(
      activeCycle, makerOrderId, takerOrderId, size, price, side, taker, maker, cashTaker, cashMaker, _getOraclePrice()
    );

    return size;
  }

  function _queueTaker(MarketSide side, uint256 qty, address trader, uint32 takerId) private {
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

  function _forceCancel(uint32 orderId) internal {
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
    else if (side == MarketSide.CALL_SELL) ua.pendingShortCalls -= uint32(M.size);

    delete ob[ac].makerNodes[orderId]; // free storage

    if (L.vol == 0) _clearLevel(side, key);

    emit OrderCancelled(ac, orderId, M.size, tick * TICK_SZ, M.trader);
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
          else if (side == MarketSide.PUT_SELL) ua.pendingShortPuts -= uint32(size);

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

  function _isCrossing(MarketSide side, uint256 tick) internal view returns (bool) {
    MarketSide oppSide = _oppositeSide(side);

    if (ob[activeCycle].summaries[uint256(oppSide)] != 0) {
      (uint32 oppBest,) = _best(oppSide);

      // Check crossing: even enum values (buys) use >=, odd enum values (sells) use <=
      return (uint256(side) & 1) == 0 ? (tick >= oppBest) : (tick <= oppBest);
    }

    return false;
  }

  function _nextMakerId(OrderbookState storage _ob) private returns (uint32 id) {
    if (_ob.limitOrderPtr == 0) id = 1;
    else id = _ob.limitOrderPtr + 2;
    _ob.limitOrderPtr = id;
  }

  function _nextTakerId(OrderbookState storage _ob) private returns (uint32 id) {
    if (_ob.takerOrderPtr == 0) id = 2;
    else id = _ob.takerOrderPtr + 2;
    _ob.takerOrderPtr = id;
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
    (bool success, bytes memory result) = ORACLE_PX_PRECOMPILE.staticcall(abi.encode(0));
    require(success, "Oracle price call failed");
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
    require(tick < 1 << 24, "Tick too large");
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

  function _requiredMarginForOrder(address trader, uint256 price, uint256 marginBps) internal view returns (uint256) {
    UserAccount memory ua = userAccounts[trader];

    uint256 shortCalls = (ua.shortCalls + ua.pendingShortCalls) > (ua.longCalls + ua.pendingLongCalls)
      ? (ua.shortCalls + ua.pendingShortCalls) - (ua.longCalls + ua.pendingLongCalls)
      : 0;
    uint256 shortPuts = (ua.shortPuts + ua.pendingShortPuts) > (ua.longPuts + ua.pendingLongPuts)
      ? (ua.shortPuts + ua.pendingShortPuts) - (ua.longPuts + ua.pendingLongPuts)
      : 0;

    uint256 notional = (shortCalls + shortPuts) * price / CONTRACT_SIZE;
    return notional * marginBps / denominator;
  }

  function _applyCashDelta(address user, int256 delta) private {
    if (delta > 0) {
      userAccounts[user].balance += uint64(uint256(delta));
    } else if (delta < 0) {
      uint256 absVal = uint256(-delta);
      require(userAccounts[user].balance >= absVal, "Insufficient balance");
      userAccounts[user].balance -= uint64(absVal);
    }
  }

  function _clearAllPositions(address trader) internal {
    UserAccount storage ua = userAccounts[trader];
    ua.liquidationQueued = false;
    ua.activeInCycle = false;
    // Zero out second slot in UserAccount struct, which contains all the individual positions data
    assembly {
      let slot := ua.slot
      sstore(add(slot, 1), 0)
    }
  }

  function _requiredMarginForLiquidation(address trader, uint256 price, uint256 marginBps)
    internal
    view
    returns (uint256)
  {
    UserAccount memory ua = userAccounts[trader];

    uint256 shortCalls = ua.shortCalls > ua.longCalls ? ua.shortCalls - ua.longCalls : 0;
    uint256 shortPuts = ua.shortPuts > ua.longPuts ? ua.shortPuts - ua.longPuts : 0;

    uint256 notional = (shortCalls + shortPuts) * price / CONTRACT_SIZE;

    return notional * marginBps / denominator;
  }

  function isLiquidatable(address trader, uint64 price) public view returns (bool) {
    UserAccount storage ua = userAccounts[trader];
    if (ua.liquidationQueued) return false;
    return ua.balance < _requiredMarginForLiquidation(trader, price, MM_BPS);
  }

  // #######################################################################
  // #                                                                     #
  // #             Other helpers                                           #
  // #                                                                     #
  // #######################################################################

  function getNumTraders() public view returns (uint256) {
    return traders.length;
  }

  function trustedForwarder() public view override returns (address) {
    return _trustedForwarder;
  }

  function setTrustedForwarder(address _forwarder) external onlyOwner {
    _trustedForwarder = _forwarder;
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

  modifier onlyWhitelisted() {
    require(whitelist[_msgSender()], "Not whitelisted");
    _;
  }

  modifier isValidSignature(bytes memory signature) {
    if (WHITELIST_SIGNER != ECDSA.recover(keccak256(abi.encodePacked(_msgSender())), signature)) {
      require(false, "Invalid signature");
    }
    _;
  }

  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
