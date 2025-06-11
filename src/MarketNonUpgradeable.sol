// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BitScan} from "./lib/Bitscan.sol";
import {Errors} from "./lib/Errors.sol";
import {IMarket, Cycle, Pos, Level, Maker, OptionType, Side, TakerQ} from "./interfaces/IMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";

contract MarketNonUpgradeable is ERC2771Context {
  using BitScan for uint256;

  //------- Meta -------
  string public name;
  IERC20 public collateralToken;
  uint64 constant collateralDecimals = 6;
  address immutable ORACLE_PX_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000807;
  uint256 constant TICK_SZ = 1e4; // 0.01 USDT0 → 10 000 wei (only works for 6-decimals tokens)
  uint256 constant IM_BPS = 10; // 0.10 % Initial Margin
  uint256 constant MM_BPS = 10; // 0.10 % Maintenance Margin (same as IM_BPS for now)
  uint256 constant CONTRACT_SIZE = 100; // Divide by this factor for 0.01BTC
  int256 constant makerFeeBps = 10; // +0.10 %, basis points
  int256 constant takerFeeBps = -40; // –0.40 %, basis points
  uint256 constant denominator = 10_000;
  address feeRecipient;
  uint256 badDebt; // grows whenever we meet an under-collateralised loser
  uint256 paidOut; // raw sum of *gross* positive deltas we have met so far

  //------- Gasless TX -------
  address private _trustedForwarder;

  //------- Whitelist -------
  address whitelistSigner;
  mapping(address => bool) public whitelist;

  //------- Vault -------
  mapping(address => uint256) public balances;

  //------- Cycle state -------
  uint256 public activeCycle; // expiry unix timestamp as ID
  mapping(uint256 => Cycle) public cycles;

  //------- Trading/Positions -------
  address[] public traders;
  mapping(uint256 => Pos) public positions;
  mapping(address => bool) inList;
  uint256 cursor; // settlement iterator

  TakerQ[][2][2] internal takerQ; // 4 buckets
  uint256[2][2] public tqHead; // cursor per bucket

  //------- Orderbook -------
  mapping(uint32 => Level) levels; // tickKey ⇒ Level
  mapping(uint16 => Maker) public makerQ; // nodeId  ⇒ Maker
  uint16 nodePtr; // auto-increment id for makers

  // summary (L1): which [256*256] blocks have liquidity
  uint256[4] public summaries;

  /**
   * `summaryIdx` (0-3)  →  L1-byte  → bitmap
   *     0 : call-asks (CA)
   *     1 : call-bids (CB)
   *     2 : put-asks  (PA)
   *     3 : put-bids  (PB)
   */
  mapping(uint8 => mapping(uint8 => uint256)) private mid; // mid[summaryIdx][l1]

  /**
   * `summaryIdx` (0-3)  →  detKey (= l1<<8 | l2)  → bitmap
   */
  mapping(uint8 => mapping(uint16 => uint256)) private det; // det[summaryIdx][detKey]

  event CycleStarted(uint256 indexed cycleId, uint256 strike);
  event CycleSettled(uint256 indexed cycleId);
  event CollateralDeposited(address indexed trader, uint256 amount);
  event CollateralWithdrawn(address indexed trader, uint256 amount);
  event OrderPlaced(
    uint256 indexed cycleId,
    uint256 orderId,
    uint256 size,
    uint256 limitPrice,
    bool isBuy,
    bool isPut,
    address indexed maker
  );
  event OrderFilled(
    uint256 indexed cycleId,
    uint256 orderId,
    uint128 size,
    uint256 limitPrice,
    bool isBuy,
    bool isPut,
    address indexed taker,
    address indexed maker,
    uint256 btcPrice
  );
  event OrderCancelled(
    uint256 indexed cycleId, uint256 orderId, uint128 size, uint256 limitPrice, address indexed maker
  );
  event Liquidated(uint256 indexed cycleId, address indexed trader);
  event PriceFixed(uint256 indexed cycleId, uint64 price);
  event Settled(uint256 indexed cycleId, address indexed trader, int256 pnl);

  constructor(
    string memory _name,
    address _feeRecipient,
    address _collateralToken,
    address _forwarder,
    address _whitelistSigner
  ) ERC2771Context(address(0)) {
    name = _name;
    feeRecipient = _feeRecipient;
    collateralToken = IERC20(_collateralToken);
    _trustedForwarder = _forwarder;
    whitelistSigner = _whitelistSigner;
  }

  function startCycle(uint256 expiry) external {
    if (activeCycle != 0) {
      // If there is an active cycle, it must be in the past
      if (activeCycle >= block.timestamp) revert Errors.CycleAlreadyStarted();

      // The previous cycle must be settled
      if (!cycles[activeCycle].isSettled) revert Errors.PreviousCycleNotSettled();
    }

    uint64 price = _getOraclePrice();
    if (price == 0) revert Errors.InvalidOraclePrice();

    // Create new market
    cycles[expiry] = Cycle({
      isSettled: false,
      strikePrice: price,
      settlementPrice: 0 // Set at cycle end time
    });

    // Set as current market
    activeCycle = expiry;

    emit CycleStarted(expiry, uint256(price));
  }

  function depositCollateral(uint256 amount) external {
    if (amount == 0) revert Errors.InvalidAmount();

    address trader = _msgSender();

    // Transfer collateral token from user to contract
    collateralToken.transferFrom(trader, address(this), amount);

    // Update user's balance
    balances[trader] += amount;

    emit CollateralDeposited(trader, amount);
  }

  function withdrawCollateral(uint256 amount) external {
    if (amount == 0) revert Errors.InvalidAmount();

    address trader = _msgSender();
    if (!_noOpenPositionsOrOrders(trader)) revert Errors.InTraderList();

    uint256 balance = balances[trader];

    if (balance < amount) revert Errors.InsufficientBalance();

    // Update user's balance
    balances[trader] -= amount;

    // Transfer collateral token from contract to user
    collateralToken.transfer(trader, amount);
    emit CollateralWithdrawn(trader, amount);
  }

  function long(uint256 size, bytes memory signature) external isValidSignature(signature) {
    whitelist[_msgSender()] = true;

    // Long call
    _placeOrder(OptionType.CALL, Side.BUY, size, 0);

    // Short put
    _placeOrder(OptionType.PUT, Side.SELL, size, 0);
  }

  function long(uint256 size) external onlyWhitelisted {
    // Long call
    _placeOrder(OptionType.CALL, Side.BUY, size, 0);

    // Short put
    _placeOrder(OptionType.PUT, Side.SELL, size, 0);
  }

  function short(uint256 size, bytes memory signature) external isValidSignature(signature) {
    whitelist[_msgSender()] = true;

    // Long put
    _placeOrder(OptionType.PUT, Side.BUY, size, 0);

    // Short call
    _placeOrder(OptionType.CALL, Side.SELL, size, 0);
  }

  function short(uint256 size) external onlyWhitelisted {
    // Long put
    _placeOrder(OptionType.PUT, Side.BUY, size, 0);

    // Short call
    _placeOrder(OptionType.CALL, Side.SELL, size, 0);
  }

  function placeOrder(
    OptionType option,
    Side side,
    uint256 size,
    uint256 limitPrice, // 0 = market
    bytes memory signature
  ) external isValidSignature(signature) returns (uint256 orderId) {
    whitelist[_msgSender()] = true;
    return _placeOrder(option, side, size, limitPrice);
  }

  function placeOrder(
    OptionType option,
    Side side,
    uint256 size,
    uint256 limitPrice // 0 = market
  ) external onlyWhitelisted returns (uint256 orderId) {
    return _placeOrder(option, side, size, limitPrice);
  }

  function _placeOrder(
    OptionType option,
    Side side,
    uint256 size,
    uint256 limitPrice // 0 = market
  ) private returns (uint256 orderId) {
    if (!_isMarketLive()) revert Errors.MarketNotLive();

    if (size == 0) revert Errors.InvalidAmount();

    uint64 price = _getOraclePrice();

    bool isPut = (option == OptionType.PUT);
    bool isBuy = (side == Side.BUY);

    // Convert price to tick
    uint32 tick = limitPrice == 0
      ? 0 // dummy (market)
      : uint32(limitPrice / TICK_SZ); // 1 tick = 0.01 USDT0

    // Limit price of 0 means market order
    if (limitPrice == 0) {
      _marketOrder(isBuy, isPut, uint128(size), _msgSender());
      return 0;
    }

    // If opposite side has liquidity and price is crossing, then also treat as market order
    uint256 oppSummary = summaries[_summaryIx(!isBuy, isPut)];

    if (oppSummary != 0) {
      (uint32 oppBest,) = _best(!isBuy, isPut);

      if ((isBuy && tick >= oppBest) || (!isBuy && tick <= oppBest)) {
        _marketOrder(isBuy, isPut, uint128(size), _msgSender());
        return 0;
      }
    }

    // Is a limit order
    uint128 qtyLeft = _matchQueuedTakers(isBuy, isPut, uint128(size), uint256(tick) * TICK_SZ);

    if (qtyLeft == 0) return 0;

    orderId = _insertLimit(isBuy, isPut, tick, qtyLeft);

    if (balances[_msgSender()] < _requiredMargin(_msgSender(), price, IM_BPS)) revert Errors.InsufficientBalance();
  }

  function cancelOrder(uint256 orderId) external {
    if (!_isMarketLive()) revert Errors.MarketNotLive();
    Maker storage M = makerQ[uint16(orderId)];

    if (M.trader != _msgSender()) revert Errors.NotOwner();

    uint32 tickKey = M.key;
    Level storage L = levels[tickKey];

    uint16 p = M.prev;
    uint16 n = M.next;

    // unlink from neighbours
    if (p == 0) L.head = n; // cancelled head

    else makerQ[p].next = n;

    if (n == 0) L.tail = p; // cancelled tail

    else makerQ[n].prev = p;

    // adjust volume
    L.vol -= M.size;

    (uint32 tick, bool isPut, bool isBid) = _splitKey(tickKey);
    if (L.vol == 0) _clearLevel(isBid, isPut, tickKey);

    Pos storage P = positions[activeCycle | uint256(uint160(M.trader))];
    if (isPut) isBid ? P.pendingLongPuts -= uint32(M.size) : P.pendingShortPuts -= uint32(M.size);
    else isBid ? P.pendingLongCalls -= uint32(M.size) : P.pendingShortCalls -= uint32(M.size);

    emit OrderCancelled(activeCycle, orderId, M.size, tick * TICK_SZ, M.trader);
    delete makerQ[uint16(orderId)];
  }

  /**
   * @notice Anyone may call this when a trader's equity has fallen below maintenance margin.
   * @param makerIds open maker-order nodeIds that belong to `trader`
   *                 (pass an empty array if the trader has no orders)
   */
  function liquidate(uint16[] calldata makerIds, address trader) external {
    if (!_isMarketLive()) revert Errors.MarketNotLive();
    uint64 price = _getOraclePrice();
    if (!_isLiquidatable(trader, price)) revert Errors.StillSolvent();

    for (uint256 k; k < makerIds.length; ++k) {
      uint16 id = makerIds[k];
      Maker storage M = makerQ[id];
      if (M.trader != trader) continue; // skip others' orders
      _forceCancel(id);
    }

    Pos storage P = positions[activeCycle | uint256(uint160(trader))];
    uint256 shortCalls = _netShortCalls(P);
    uint256 shortPuts = _netShortPuts(P);

    if (shortCalls > 0) _marketOrder(true, false, uint128(shortCalls), trader);
    if (shortPuts > 0) _marketOrder(true, true, uint128(shortPuts), trader);

    emit Liquidated(activeCycle, trader);
  }

  function settleChunk(uint256 max) external returns (bool done) {
    uint256 cycleId = activeCycle;
    Cycle storage C = cycles[cycleId];
    uint64 settlementPrice = C.settlementPrice;

    if (settlementPrice == 0) {
      if (block.timestamp < activeCycle) revert Errors.NotExpired();
      C.settlementPrice = _getOraclePrice();
      emit PriceFixed(activeCycle, C.settlementPrice);
    }
    if (C.isSettled) revert Errors.CycleAlreadySettled();

    uint256 n = traders.length;
    uint256 i = cursor;
    uint256 upper = i + max;
    if (upper > n) upper = n;

    while (i < upper) {
      address t = traders[i];
      uint256 key = cycleId | uint256(uint160(t));
      _settleTrader(cycleId, key, settlementPrice, t);
      unchecked {
        ++i;
      }
    }
    cursor = i;

    if (i == n) {
      // Finished settling all traders
      delete traders;
      delete takerQ;
      delete tqHead;

      cursor = 0;
      C.isSettled = true;
      activeCycle = 0;
      _purgeBook();

      badDebt = 0;
      paidOut = 0;

      emit CycleSettled(cycleId);
      done = true;
    }
  }

  // #######################################################################
  // #                                                                     #
  // #                  Internal bit helpers                               #
  // #                                                                     #
  // #######################################################################

  // Convert tick, isPut, isBid to key
  function _key(uint32 tick, bool isPut, bool isBid) internal pure returns (uint32) {
    if (tick >= 1 << 24) revert Errors.TickTooLarge();
    return tick | (isPut ? 1 << 31 : 0) | (isBid ? 1 << 30 : 0);
  }

  // Convert key to tick, isPut, isBid
  function _splitKey(uint32 key) private pure returns (uint32 tick, bool isPut, bool isBid) {
    isPut = (key & (1 << 31)) != 0;
    isBid = (key & (1 << 30)) != 0;
    tick = key & 0x00FF_FFFF; // Only take rightmost 24 bits for tick
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
  function _clrBits(
    mapping(uint16 => uint256) storage dett,
    mapping(uint8 => uint256) storage midd,
    uint8 l1,
    uint8 l2,
    uint8 l3
  ) internal returns (bool lastInL1) {
    uint16 detKey = (uint16(l1) << 8) | l2; // Locate detail word
    dett[detKey] &= ~BitScan.mask(l3); // Clear bit l3

    // If no ticks left in this 256-tick word
    if (dett[detKey] == 0) {
      midd[l1] &= ~BitScan.mask(l2); // Clear mid-level bit
      // If no 256-tick words left in this 65 k-tick block
      if (midd[l1] == 0) return true; // Caller must clear summary bit
    }
    return false;
  }

  // Returns the best tick and key for the given side and option type
  function _best(bool isBid, bool isPut) private view returns (uint32 tick, uint32 key) {
    uint256 summary = summaries[_summaryIx(isBid, isPut)];
    (mapping(uint8 => uint256) storage midd, mapping(uint16 => uint256) storage dett) = _maps(isBid, isPut);

    // For bids we want highest price (msb), for asks we want lowest price (lsb)
    uint8 l1 = isBid ? summary.msb() : summary.lsb();

    // Same for l2 and l3
    uint8 l2 = isBid ? midd[l1].msb() : midd[l1].lsb();
    uint16 k12 = (uint16(l1) << 8) | l2;
    uint8 l3 = isBid ? dett[k12].msb() : dett[k12].lsb();

    tick = BitScan.join(l1, l2, l3);
    key = _key(tick, isPut, isBid);
    return (tick, key);
  }

  // Add bit to summary bitmap
  function _sumAddBit(bool isBid, bool isPut, uint8 l1) internal {
    // Bitwise OR the mask with the summary bitmap, flipping that bit on
    summaries[_summaryIx(isBid, isPut)] |= BitScan.mask(l1);
  }

  // Clear bit from summary bitmap
  function _sumClrBit(bool isBid, bool isPut, uint8 l1) internal {
    // Bitwise AND the inverse of the mask with the summary bitmap, flipping that bit off
    summaries[_summaryIx(isBid, isPut)] &= ~BitScan.mask(l1);
  }

  // Get summary index
  function _summaryIx(bool isBid, bool isPut) internal pure returns (uint8) {
    return (isBid ? 1 : 0) | ((isPut ? 1 : 0) << 1); // 0-3
  }

  // #######################################################################
  // #                                                                     #
  // #                  Internal orderbook helpers                         #
  // #                                                                     #
  // #######################################################################

  function _insertLimit(bool isBuy, bool isPut, uint32 tick, uint128 size) private returns (uint16 nodeId) {
    // pick the right bitmap ladders
    (mapping(uint8 => uint256) storage midd, mapping(uint16 => uint256) storage dett) = _maps(isBuy, isPut);

    // derive level bytes and key
    (uint8 l1, uint8 l2, uint8 l3) = BitScan.split(tick);
    uint32 key = _key(tick, isPut, isBuy);

    // if level empty, set bitmap bits
    if (levels[key].vol == 0) {
      bool firstInL1 = _addBits(dett, midd, l1, l2, l3);
      assert(midd[l1] & (1 << l2) != 0);

      if (firstInL1) _sumAddBit(isBuy, isPut, l1);
    }

    // maker node
    nodeId = ++nodePtr;
    makerQ[nodeId] = Maker(_msgSender(), size, 0, key, levels[key].tail);

    // FIFO queue link
    if (levels[key].vol == 0) levels[key].head = nodeId;
    else makerQ[levels[key].tail].next = nodeId;
    levels[key].tail = nodeId;
    levels[key].vol += size;

    // position table
    if (!inList[_msgSender()]) {
      inList[_msgSender()] = true;
      traders.push(_msgSender());
    }
    Pos storage P = positions[activeCycle | uint256(uint160(_msgSender()))]; // key by cycle+trader

    if (isPut) isBuy ? P.pendingLongPuts += uint32(size) : P.pendingShortPuts += uint32(size);
    else isBuy ? P.pendingLongCalls += uint32(size) : P.pendingShortCalls += uint32(size);
  }

  function _settleFill(
    uint32 orderId,
    bool takerIsBuy,
    bool isPut,
    uint256 price, // 6 decimals
    uint128 size,
    address taker,
    address maker,
    bool isTakerQueue
  ) internal returns (uint128) {
    // Fees accounting
    {
      int256 notionalPremium = int256(price) * int256(uint256(size)); // always +ve

      // signed direction: +1 when taker buys, -1 when taker sells
      int256 dir = takerIsBuy ? int256(1) : int256(-1);

      int256 makerFee = notionalPremium * makerFeeBps / int256(denominator);
      int256 takerFee = notionalPremium * takerFeeBps / int256(denominator);

      // flip premium flow with dir
      int256 cashMaker = dir * notionalPremium + makerFee;
      int256 cashTaker = -dir * notionalPremium + takerFee;

      // Check if taker has enough cash to pay premium. If not, return 0
      if (isTakerQueue && balances[taker] < uint256((cashTaker * -1))) return 0;

      _applyCashDeltaSocial(maker, cashMaker);
      _applyCashDeltaSocial(taker, cashTaker);

      int256 houseFee = -(makerFee + takerFee); // net to fee recipient
      if (houseFee != 0) _applyCashDelta(feeRecipient, houseFee);
    }

    // Position accounting
    {
      Pos storage PM = positions[activeCycle | uint256(uint160(maker))];
      Pos storage PT = positions[activeCycle | uint256(uint160(taker))];

      if (isPut) {
        if (takerIsBuy) {
          PT.longPuts += uint32(size);
          PM.shortPuts += uint32(size);
          if (!isTakerQueue) PM.pendingShortPuts -= uint32(size);
          else PT.pendingLongPuts -= uint32(size);
        } else {
          PT.shortPuts += uint32(size);
          PM.longPuts += uint32(size);
          if (!isTakerQueue) PM.pendingLongPuts -= uint32(size);
          else PT.pendingShortPuts -= uint32(size);
        }
      } else {
        if (takerIsBuy) {
          PT.longCalls += uint32(size);
          PM.shortCalls += uint32(size);
          if (!isTakerQueue) PM.pendingShortCalls -= uint32(size);
          else PT.pendingLongCalls -= uint32(size);
        } else {
          PT.shortCalls += uint32(size);
          PM.longCalls += uint32(size);
          if (!isTakerQueue) PM.pendingLongCalls -= uint32(size);
          else PT.pendingShortCalls -= uint32(size);
        }
      }
    }

    // event OrderMatched(uint256 indexed cycleId, uint256 orderId, uint128 size, uint256 limitPrice, bool isBuy, bool
    // isPut, address indexed taker, address indexed maker);
    emit OrderFilled(activeCycle, orderId, size, price, takerIsBuy, isPut, taker, maker, _getOraclePrice() / 10000000);

    return size;
  }

  /**
   * @dev Fills against the opposite side until either a) qty exhausted, or b) book empty
   */
  function _marketOrder(bool isBuy, bool isPut, uint128 want, address taker) private {
    uint128 left = want;

    while (left > 0) {
      {
        // Any liquidity left?
        uint256 sumOpp = summaries[_summaryIx(!isBuy, isPut)];
        if (sumOpp == 0) break; // No bits set in summary means empty book
      }

      // Best price level
      (uint32 bestTick, uint32 bestKey) = _best(!isBuy, isPut);
      Level storage L = levels[bestKey];
      uint16 nodeId = L.head; // nodeId = orderId

      // Walk FIFO makers at this tick
      while (left > 0 && nodeId != 0) {
        Maker storage M = makerQ[nodeId];

        uint128 take = left < M.size ? left : M.size;

        uint128 taken = _settleFill(
          nodeId,
          isBuy, // taker side
          isPut,
          uint256(bestTick) * TICK_SZ, // price
          take,
          taker, // taker
          M.trader, // maker
          false // isTakerQueue
        );

        if (taken == 0) revert Errors.InsufficientBalance();

        left -= taken;
        M.size -= taken;
        L.vol -= taken;

        if (M.size == 0) {
          // Remove node from queue
          uint16 nxt = M.next;
          if (nxt == 0) L.tail = 0;
          else makerQ[nxt].prev = 0;

          L.head = nxt;
          delete makerQ[nodeId];
          nodeId = nxt;
        } else {
          break; // Taker satisfied
        }
      }

      // If price level empty, clear bitmaps
      if (L.vol == 0) _clearLevel(!isBuy, isPut, bestKey);
    }

    if (left > 0) _queueTaker(isBuy, isPut, left, taker);
  }

  function _queueTaker(bool isBuy, bool isPut, uint128 qty, address trader) private {
    takerQ[isPut ? 1 : 0][isBuy ? 1 : 0].push(TakerQ({size: uint96(qty), trader: trader}));
    Pos storage P = positions[activeCycle | uint256(uint160(trader))];
    if (isPut) isBuy ? P.pendingLongPuts += uint32(qty) : P.pendingShortPuts += uint32(qty);
    else isBuy ? P.pendingLongCalls += uint32(qty) : P.pendingShortCalls += uint32(qty);
  }

  function _matchQueuedTakers(
    bool makerIsBid,
    bool isPut,
    uint128 makerSize,
    uint256 price // maker's price, 6-dec
  ) private returns (uint128 remainingMakerSize) {
    TakerQ[] storage Q = takerQ[isPut ? 1 : 0][makerIsBid ? 0 : 1];
    uint256 i = tqHead[isPut ? 1 : 0][makerIsBid ? 0 : 1];

    remainingMakerSize = makerSize;

    while (remainingMakerSize > 0 && i < Q.length) {
      TakerQ storage T = Q[i];
      if (T.size == 0) {
        ++i;
        continue;
      } // skip emptied slot

      uint128 take = T.size > remainingMakerSize ? remainingMakerSize : T.size;

      uint128 taken = _settleFill(
        0, // Imaginary orderId to denote that this is a takerQueue match
        !makerIsBid, // same as takerIsBuy
        isPut,
        price,
        take,
        T.trader, // The (queued) taker
        _msgSender(), // The maker
        true // isTakerQueue
      );

      T.size -= uint96(taken);
      remainingMakerSize -= taken;

      if (T.size == 0) ++i; // fully consumed
    }
    tqHead[isPut ? 1 : 0][makerIsBid ? 0 : 1] = i; // persist cursor
  }

  // Safely apply pnl
  function _applyCashDelta(address user, int256 delta) private {
    if (delta > 0) {
      balances[user] += uint256(delta);
    } else if (delta < 0) {
      uint256 absVal = uint256(-delta);
      if (balances[user] < absVal) revert Errors.InsufficientBalance();
      balances[user] -= absVal;
    }
  }

  function _applyCashDeltaSocial(address u, int256 d) internal {
    if (d < 0) {
      uint256 debit = uint256(-d);
      uint256 bal = balances[u];
      if (bal >= debit) {
        balances[u] = bal - debit;
      } else {
        balances[u] = 0;
        badDebt += debit - bal;
      }
      return;
    }

    uint256 credit = uint256(d);
    uint256 newPaid = paidOut + credit;

    if (badDebt == 0) {
      balances[u] += credit;
      paidOut = newPaid;
      return;
    }

    if (newPaid <= badDebt) {
      // still underwater – winner gets nothing yet
      paidOut = newPaid;
      return;
    }

    // partially underwater: distribute only the surplus
    uint256 distributable = newPaid - badDebt; // > 0
    uint256 give = credit * distributable / newPaid;

    balances[u] += give;

    // plug the hole and keep only the surplus as new paidOut
    paidOut = distributable;
    badDebt = 0;
  }

  function _clearLevel(bool isBuy, bool isPut, uint32 key) private {
    (uint32 tick,,) = _splitKey(key);
    (uint8 l1, uint8 l2, uint8 l3) = BitScan.split(tick);

    // The opposite book
    (mapping(uint8 => uint256) storage midOpp, mapping(uint16 => uint256) storage detOpp) = _maps(isBuy, isPut);

    // Clear bitmaps
    bool lastInL1 = _clrBits(detOpp, midOpp, l1, l2, l3);
    if (lastInL1) _sumClrBit(isBuy, isPut, l1);

    delete levels[key];
  }

  function _forceCancel(uint16 orderId) internal {
    Maker storage M = makerQ[orderId];
    uint32 key = M.key;
    Level storage L = levels[key];

    uint16 p = M.prev;
    uint16 n = M.next;

    if (p == 0) L.head = n;
    else makerQ[p].next = n;
    if (n == 0) L.tail = p;
    else makerQ[n].prev = p;

    L.vol -= M.size; // reduce resting volume
    Pos storage P = positions[activeCycle | uint256(uint160(M.trader))];
    (uint32 tick, bool isPut, bool isBid) = _splitKey(M.key);

    if (isPut) isBid ? P.pendingLongPuts -= uint32(M.size) : P.pendingShortPuts -= uint32(M.size);
    else isBid ? P.pendingLongCalls -= uint32(M.size) : P.pendingShortCalls -= uint32(M.size);
    delete makerQ[orderId]; // free storage

    if (L.vol == 0) _clearLevel(isBid, isPut, key);

    emit OrderCancelled(activeCycle, orderId, M.size, tick * TICK_SZ, M.trader);
  }

  // Return the mid and detailed bitmaps for the given side.
  function _maps(bool isBid, bool isPut)
    internal
    view
    returns (mapping(uint8 => uint256) storage midMap, mapping(uint16 => uint256) storage detMap)
  {
    uint8 idx = _summaryIx(isBid, isPut); // 0-3
    midMap = mid[idx]; // one “column” of the nested mapping
    detMap = det[idx];
  }

  function _purgeBook() internal {
    // Loop over all 4 book sides
    for (uint8 put = 0; put < 2; ++put) {
      for (uint8 bid = 0; bid < 2; ++bid) {
        _purgeSide(bid == 1, put == 1);
      }
    }
  }

  // walk one side of the book, removing every price-level
  function _purgeSide(bool isBid, bool isPut) private {
    uint8 sIx = _summaryIx(isBid, isPut);

    // while there is still at least one block with liquidity …
    while (summaries[sIx] != 0) {
      // start clearing from best price level
      (, uint32 key) = _best(isBid, isPut);

      // unlink all maker nodes at that tick
      Level storage L = levels[key];
      uint16 node = L.head;
      while (node != 0) {
        uint16 nxt = makerQ[node].next;
        delete makerQ[node];
        node = nxt;
      }

      // clear bitmap bits and Level struct
      _clearLevel(isBid, isPut, key);
    }
  }

  // #######################################################################
  // #                                                                     #
  // #             Internal position and settlement helpers                #
  // #                                                                     #
  // #######################################################################

  function _getOraclePrice() internal view returns (uint64) {
    bool success;
    bytes memory result;
    (success, result) = ORACLE_PX_PRECOMPILE_ADDRESS.staticcall(abi.encode(0));
    if (!success) revert Errors.OraclePriceCallFailed();
    uint64 price = abi.decode(result, (uint64)) * uint64(10 ** (collateralDecimals - 1)); // Price always returned with
      // 1 extra decimal, so subtract by 1 from USDT0 decimals.
    return price;
  }

  /**
   * @dev Check if the market is live by checking timestamp
   * @return true if the market is live, false otherwise.
   * @dev Market is live if the settlement price is not set.
   */
  function _isMarketLive() internal view returns (bool) {
    return block.timestamp < activeCycle;
  }

  function _totalNotional(uint256 contracts, uint64 spot) internal pure returns (uint256) {
    // contracts * spot * 0.01 = total notional
    return contracts * uint256(spot) / CONTRACT_SIZE;
  }

  function _netShortCalls(Pos memory p) internal pure returns (uint256) {
    return (p.shortCalls + p.pendingShortCalls) > (p.longCalls + p.pendingLongCalls)
      ? (p.shortCalls + p.pendingShortCalls) - (p.longCalls + p.pendingLongCalls)
      : 0;
  }

  function _netShortPuts(Pos memory p) internal pure returns (uint256) {
    return (p.shortPuts + p.pendingShortPuts) > (p.longPuts + p.pendingLongPuts)
      ? (p.shortPuts + p.pendingShortPuts) - (p.longPuts + p.pendingLongPuts)
      : 0;
  }

  function _requiredMargin(address trader, uint64 price, uint256 marginBps) internal view returns (uint256 rm) {
    Pos storage P = positions[activeCycle | uint256(uint160(trader))];

    uint256 shortCalls = _netShortCalls(P);
    uint256 shortPuts = _netShortPuts(P);

    uint256 notional = _totalNotional(shortCalls + shortPuts, price);

    rm = notional * marginBps / denominator;
  }

  function _isLiquidatable(address trader, uint64 price) internal view returns (bool) {
    uint256 mm6 = _requiredMargin(trader, price, MM_BPS);

    return balances[trader] < mm6;
  }

  function _settleTrader(uint256 cycleId, uint256 key, uint64 price, address trader) internal {
    Pos storage P = positions[key];
    if (P.longCalls | P.shortCalls | P.longPuts | P.shortPuts == 0) {
      delete positions[key];
      return;
    }

    int256 pnl;

    /* intrinsic of calls */
    int256 diff = int256(uint256(price)) - int256(uint256(cycles[activeCycle].strikePrice));
    if (diff > 0) {
      // long calls win
      pnl += diff * int256(uint256(P.longCalls)) / int256(CONTRACT_SIZE);
      pnl -= diff * int256(uint256(P.shortCalls)) / int256(CONTRACT_SIZE);
    } else {
      // short calls win
      pnl += diff * int256(uint256(P.longCalls)) / int256(CONTRACT_SIZE);
      pnl -= diff * int256(uint256(P.shortCalls)) / int256(CONTRACT_SIZE);
    }

    /* intrinsic of puts (mirror) */
    diff = int256(uint256(cycles[activeCycle].strikePrice)) - int256(uint256(price));
    if (diff > 0) {
      pnl += diff * int256(uint256(P.longPuts)) / int256(CONTRACT_SIZE);
      pnl -= diff * int256(uint256(P.shortPuts)) / int256(CONTRACT_SIZE);
    } else {
      pnl += diff * int256(uint256(P.longPuts)) / int256(CONTRACT_SIZE);
      pnl -= diff * int256(uint256(P.shortPuts)) / int256(CONTRACT_SIZE);
    }

    _applyCashDeltaSocial(trader, pnl);
    inList[trader] = false;
    emit Settled(cycleId, trader, pnl);

    delete positions[key]; // gas refund
  }

  function _noOpenPositionsOrOrders(address trader) internal view returns (bool) {
    uint256 key = activeCycle | uint256(uint160(trader));
    return positions[key].longCalls | positions[key].shortCalls | positions[key].longPuts | positions[key].shortPuts
      | positions[key].pendingLongCalls | positions[key].pendingShortCalls | positions[key].pendingLongPuts
      | positions[key].pendingShortPuts == 0;
  }

  // #######################################################################
  // #                                                                     #
  // #                  View functions                                     #
  // #                                                                     #
  // #######################################################################
  function getNumTraders() public view returns (uint256) {
    return traders.length;
  }

  function trustedForwarder() public view override returns (address) {
    return _trustedForwarder;
  }

  function _msgSender() internal view override(ERC2771Context) returns (address sender) {
    return ERC2771Context._msgSender();
  }

  function _msgData() internal view override(ERC2771Context) returns (bytes calldata) {
    return ERC2771Context._msgData();
  }

  function _contextSuffixLength() internal view override(ERC2771Context) returns (uint256) {
    return ERC2771Context._contextSuffixLength();
  }

  modifier onlyWhitelisted() {
    if (!whitelist[_msgSender()]) revert Errors.NotWhitelisted();
    _;
  }

  modifier isValidSignature(bytes memory signature) {
    if (whitelistSigner != ECDSA.recover(keccak256(abi.encodePacked(_msgSender())), signature)) {
      revert Errors.InvalidSignature();
    }
    _;
  }

  // #######################################################################
  // #                                                                     #
  // #                  Admin functions                                    #
  // #                                                                     #
  // #######################################################################

  // function setTrustedForwarder(address _forwarder) external onlyOwner {
  //   _trustedForwarder = _forwarder;
  // }
}
