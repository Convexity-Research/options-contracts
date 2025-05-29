// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BitScan} from "./lib/Bitscan.sol";
import {Errors} from "./lib/Errors.sol";
import {IMarket, Cycle, Pos, Level, Maker, OptionType, Side, TakerQ} from "./interfaces/IMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "forge-std/console.sol";

struct OBLevel {
  uint32 tick; // raw tick
  uint128 vol; // resting contracts at that tick
}

contract Market is IMarket, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable {
  using BitScan for uint256;

  //------- Meta -------
  uint256 private constant TICK_SZ = 1e4; // 0.01 USDT0 → 10 000 wei (6-decimals)
  int16 public constant makerFeeBps = 10; // +0.10 %, basis points
  int16 public constant takerFeeBps = -40; // –0.40 %, basis points
  string public name;
  address public priceOracle;
  IERC20 public collateralToken;
  address public feeRecipient;

  //------- Vault -------
  mapping(address => uint256) public balances;
  mapping(uint256 => mapping(address => uint256)) public lockedCollateral;

  //------- Cycle state -------
  uint256 public activeCycle; // expiry unix timestamp as ID
  mapping(uint256 => Cycle) public cycles;

  //------- Trading/Positions -------

  address[] public traders;
  mapping(uint256 => Pos) public positions;
  mapping(address => bool) public inList;
  uint256 public cursor; // settlement iterator

  TakerQ[][2][2] private takerQ; // 4 buckets
  uint256[2][2] public tqHead; // cursor per bucket

  //------- Orderbook -------
  mapping(uint32 => Level) public levels; // tickKey ⇒ Level
  mapping(uint16 => Maker) public makerQ; // nodeId  ⇒ Maker
  uint16 nodePtr; // auto-increment id for makers

  // summary (L1): which [256*256] blocks have liquidity
  uint256[4] public summaries;

  // mid (L2): which [256] block has liquidity
  mapping(uint8 => uint256) public midCB;
  mapping(uint8 => uint256) public midCA;
  mapping(uint8 => uint256) public midPB;
  mapping(uint8 => uint256) public midPA;

  // detail (L3): which tick has liquidity
  mapping(uint16 => uint256) public detCB;
  mapping(uint16 => uint256) public detCA;
  mapping(uint16 => uint256) public detPB;
  mapping(uint16 => uint256) public detPA;

  event CycleStarted(uint256 expiry, uint256 strike);
  event CycleSettled(uint256 cycleId);
  event CollateralDeposited(address trader, uint256 amount);
  event CollateralWithdrawn(address trader, uint256 amount);
  event OrderPlaced(uint256 cycleId, uint256 orderId, address trader, uint256 size, uint256 limitPrice);
  event Liquidated(uint256 cycleId, uint256 orderId, address trader, uint256 collateral, bool completed);
  event PriceFixed(uint256 expiry, uint64 price);
  event Trade(uint32 tick, bool isBuy, bool isPut, uint128 size, address taker, address maker);
  event Cancel(uint32 nodeId, address maker, uint128 vol);
  event Settled(address trader, int256 pnl);

  constructor() {
    _disableInitializers();
  }

  function initialize(string memory _name, address _feeRecipient, address _oracleFeed, address _collateralToken)
    external
    initializer
  {
    __Ownable_init(_msgSender());
    __Pausable_init();
    __UUPSUpgradeable_init();

    name = _name;
    feeRecipient = _feeRecipient;
    priceOracle = _oracleFeed;
    collateralToken = IERC20(_collateralToken);
  }

  function startCycle(uint256 expiry) external onlyOwner {
    if (activeCycle != 0) {
      // If there is an active cycle, it must be in the past
      require(activeCycle < block.timestamp, Errors.CYCLE_ALREADY_STARTED);

      // The previous cycle must be settled
      require(cycles[activeCycle].isSettled, Errors.PREVIOUS_CYCLE_NOT_SETTLED);
    }

    //(, int256 price, , , ) = AggregatorV3Interface(priceOracle).latestRoundData();
    int256 price = 1;
    require(price > 0, Errors.INVALID_ORACLE_PRICE);

    // Create new market
    cycles[expiry] = Cycle({
      active: true,
      isSettled: false,
      strikePrice: uint96(uint256(price)),
      settlementPrice: 0 // Set at cycle end time
    });

    // Set as current market
    activeCycle = expiry;

    emit CycleStarted(expiry, uint256(price));
  }

  function depositCollateral(uint256 amount) external {
    require(amount > 0, Errors.INVALID_AMOUNT);

    address trader = _msgSender();

    // Transfer collateral token from user to contract
    collateralToken.transferFrom(trader, address(this), amount);

    // Update user's balance
    balances[trader] += amount;

    emit CollateralDeposited(trader, amount);
  }

  function withdrawCollateral(uint256 amount) external {
    require(amount > 0, Errors.INVALID_AMOUNT);

    address trader = _msgSender();
    uint256 balance = balances[trader] - lockedCollateral[activeCycle][trader];

    require(balance >= amount, Errors.INSUFFICIENT_BALANCE);

    // Update user's balance
    balances[trader] -= amount;

    // Transfer collateral token from contract to user
    collateralToken.transfer(trader, amount);

    emit CollateralWithdrawn(trader, amount);
  }

  function placeOrder(
    OptionType option,
    Side side,
    uint256 size,
    uint256 limitPrice // 0 = market
  ) external returns (uint256 orderId) {
    require(size > 0, Errors.INVALID_AMOUNT);
    uint256 cycleId = activeCycle;

    bool isPut = (option == OptionType.PUT);
    bool isBuy = (side == Side.BUY);

    // Convert price to tick
    uint32 tick = limitPrice == 0
      ? 0 // dummy (market)
      : uint32(limitPrice / TICK_SZ); // 1 tick = 0.01 USDT0

    // Limit price of 0 means market order
    if (limitPrice == 0) {
      _marketOrder(isBuy, isPut, uint128(size));

      emit OrderPlaced(cycleId, 0, msg.sender, size, 0);
      return 0;
    }

    // If opposite side has liquidity and price is crossing, then also treat as market order
    uint256 oppSummary = summaries[_summaryIx(!isBuy, isPut)];

    if (oppSummary != 0) {
      (uint32 oppBest,) = _best(!isBuy, isPut);

      if ((isBuy && tick >= oppBest) || (!isBuy && tick <= oppBest)) {
        _marketOrder(isBuy, isPut, uint128(size));

        emit OrderPlaced(cycleId, 0, msg.sender, size, limitPrice);
        return 0;
      }
    }

    // Is a limit order
    uint128 qtyLeft = _matchQueuedTakers(isBuy, isPut, uint128(size), uint256(tick) * TICK_SZ);

    if (qtyLeft == 0) {
      emit OrderPlaced(cycleId, 0, msg.sender, size, limitPrice); // fully filled
      return 0;
    }

    orderId = _insertLimit(isBuy, isPut, tick, qtyLeft);
    emit OrderPlaced(cycleId, orderId, msg.sender, qtyLeft, limitPrice);
  }

  function cancelOrder(uint256 orderId) external {
    Maker storage M = makerQ[uint16(orderId)];

    require(M.trader == msg.sender, Errors.NOT_OWNER);

    uint32 key = M.key;
    Level storage L = levels[key];

    uint16 p = M.prev;
    uint16 n = M.next;

    // unlink from neighbours
    if (p == 0) L.head = n; // cancelled head

    else makerQ[p].next = n;

    if (n == 0) L.tail = p; // cancelled tail

    else makerQ[n].prev = p;

    // adjust volume
    L.vol -= M.size;

    delete makerQ[uint16(orderId)];

    if (L.vol == 0) {
      (, bool isPut, bool isBid) = _splitKey(key);
      _clearLevel(isBid, isPut, key);
    }

    emit Cancel(uint32(orderId), msg.sender, M.size);
  }

  function liquidate(uint256[] calldata orderIds, address trader) external {}

  function settle(uint256 cycleId) external {}

  // #######################################################################
  // #                                                                     #
  // #                  Internal bit helpers                               #
  // #                                                                     #
  // #######################################################################

  // Convert tick, isPut, isBid to key
  function _key(uint32 tick, bool isPut, bool isBid) private pure returns (uint32) {
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
    mapping(uint16 => uint256) storage det, // detail  (L3)  bitmap
    mapping(uint8 => uint256) storage mid, // mid     (L2)  bitmap
    uint8 l1, // high    byte
    uint8 l2, // middle  byte
    uint8 l3 // low     byte
  ) internal returns (bool firstInL1) {
    uint16 detKey = (uint16(l1) << 8) | l2; // Word key for det[] mapping
    uint256 m3 = BitScan.mask(l3); // Isolate bit l3

    // If this is the very first order at (l1,l2,l3) …
    if (det[detKey] & m3 == 0) {
      det[detKey] |= m3; // Flip the detail bit

      uint256 m2 = BitScan.mask(l2); // Bit mask for mid bitmap
      // If this tick is the first in its 256-tick block
      if (mid[l1] & m2 == 0) {
        mid[l1] |= m2; // Set the mid-level bit
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
    mapping(uint16 => uint256) storage det,
    mapping(uint8 => uint256) storage mid,
    uint8 l1,
    uint8 l2,
    uint8 l3
  ) internal returns (bool lastInL1) {
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

  // Returns the best tick and key for the given side and option type
  function _best(bool isBid, bool isPut) private view returns (uint32 tick, uint32 key) {
    uint256 summary = summaries[_summaryIx(isBid, isPut)];
    (mapping(uint8 => uint256) storage mid, mapping(uint16 => uint256) storage det) = _maps(isBid, isPut);

    // For bids we want highest price (msb), for asks we want lowest price (lsb)
    uint8 l1 = isBid ? summary.msb() : summary.lsb();

    // Same for l2 and l3
    uint8 l2 = isBid ? mid[l1].msb() : mid[l1].lsb();
    uint16 k12 = (uint16(l1) << 8) | l2;
    uint8 l3 = isBid ? det[k12].msb() : det[k12].lsb();

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
    (mapping(uint8 => uint256) storage mid, mapping(uint16 => uint256) storage det) = _maps(isBuy, isPut);

    // derive level bytes and key
    (uint8 l1, uint8 l2, uint8 l3) = BitScan.split(tick);
    uint32 key = _key(tick, isPut, isBuy);

    // if level empty, set bitmap bits
    if (levels[key].vol == 0) {
      bool firstInL1 = _addBits(det, mid, l1, l2, l3);
      assert(mid[l1] & (1 << l2) != 0);

      if (firstInL1) _sumAddBit(isBuy, isPut, l1);
    }

    // maker node
    nodeId = ++nodePtr;
    makerQ[nodeId] = Maker(msg.sender, size, 0, key, levels[key].tail);

    // FIFO queue link
    if (levels[key].vol == 0) levels[key].head = nodeId;
    else makerQ[levels[key].tail].next = nodeId;
    levels[key].tail = nodeId;
    levels[key].vol += size;

    // position table
    if (!inList[msg.sender]) {
      inList[msg.sender] = true;
      traders.push(msg.sender);
    }
    Pos storage P = positions[activeCycle | uint256(uint160(msg.sender))]; // key by cycle+trader

    if (isPut) isBuy ? P.longPuts += uint96(size) : P.shortPuts += uint96(size);
    else isBuy ? P.longCalls += uint96(size) : P.shortCalls += uint96(size);
  }

  function _settleFill(
    bool takerIsBuy,
    bool isPut,
    uint256 price, // 6-decimals
    uint128 size, // contracts
    address taker,
    address maker
  ) internal {
    // Fees accounting
    int256 premium = int256(price) * int256(uint256(size)); // always +ve
    int256 makerFee = premium * makerFeeBps / 10_000; // Can be +ve or -ve
    int256 takerFee = premium * takerFeeBps / 10_000; // Can be +ve or -ve

    int256 cashMaker = premium + makerFee; // maker receives premium
    int256 cashTaker = -premium + takerFee; // taker pays premium

    _applyCashDelta(maker, cashMaker);
    _applyCashDelta(taker, cashTaker);

    int256 feeHouse = -(makerFee + takerFee); // net to house
    if (feeHouse != 0) _applyCashDelta(feeRecipient, feeHouse);

    // Position acounting
    Pos storage PM = positions[activeCycle | uint256(uint160(maker))];
    Pos storage PT = positions[activeCycle | uint256(uint160(taker))];

    if (isPut) {
      if (takerIsBuy) {
        PT.longPuts += uint96(size);
        PM.shortPuts += uint96(size);
      } else {
        PT.shortPuts += uint96(size);
        PM.longPuts += uint96(size);
      }
    } else {
      if (takerIsBuy) {
        PT.longCalls += uint96(size);
        PM.shortCalls += uint96(size);
      } else {
        PT.shortCalls += uint96(size);
        PM.longCalls += uint96(size);
      }
    }
  }

  /**
   * @dev Fills against the opposite side until either a) qty exhausted, or b) book empty
   */
  function _marketOrder(bool isBuy, bool isPut, uint128 want) private {
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
      uint16 node = L.head;

      // Walk FIFO makers at this tick
      while (left > 0 && node != 0) {
        Maker storage M = makerQ[node];

        uint128 take = left < M.size ? left : M.size;
        left -= take;
        M.size -= take;
        L.vol -= take;

        _settleFill(
          isBuy, // taker side
          isPut,
          uint256(bestTick) * TICK_SZ, // price
          take,
          msg.sender, // taker
          M.trader // maker
        );

        if (M.size == 0) {
          // Remove node from queue
          uint16 nxt = M.next;
          if (nxt == 0) L.tail = 0;
          else makerQ[nxt].prev = 0;

          L.head = nxt;
          delete makerQ[node];
          node = nxt;
        } else {
          break; // Taker satisfied
        }
      }

      // If price level empty, clear bitmaps
      if (L.vol == 0) _clearLevel(!isBuy, isPut, bestKey);
    }

    if (left > 0) _queueTaker(isBuy, isPut, left, msg.sender);
  }

  function _queueTaker(bool isBuy, bool isPut, uint128 qty, address trader) private {
    takerQ[isPut ? 1 : 0][isBuy ? 1 : 0].push(TakerQ({size: uint96(qty), trader: trader}));
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
      T.size -= uint96(take);
      remainingMakerSize -= take;

      _settleFill(
        !makerIsBid, // same as takerIsBuy
        isPut,
        price,
        take,
        T.trader, // The (queued) taker
        msg.sender // The maker
      );

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
      require(balances[user] >= absVal, "INSUFFICIENT_BALANCE");
      balances[user] -= absVal;
    }
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

  // Return the mid and detailed bitmaps for the given side.
  function _maps(bool isBid, bool isPut)
    private
    view
    returns (mapping(uint8 => uint256) storage mid, mapping(uint16 => uint256) storage det)
  {
    if (isBid) {
      if (isPut) {
        mid = midPB;
        det = detPB;
      } else {
        mid = midCB;
        det = detCB;
      }
    } else {
      if (isPut) {
        mid = midPA;
        det = detPA;
      } else {
        mid = midCA;
        det = detCA;
      }
    }
  }

  // #######################################################################
  // #                                                                     #
  // #                  View functions                                     #
  // #                                                                     #
  // #######################################################################

  function viewTakerQueue(bool isPut, bool isBid) external view returns (TakerQ[] memory) {
    return takerQ[isPut ? 1 : 0][isBid ? 1 : 0];
  }

  // Claude copy pasta. Remove this before deployment, only for visualizing during tests.
  // Needs IR optimizer for compilation to work.
  function dumpBook(bool isBid, bool isPut) external view returns (OBLevel[] memory levels_) {
    // ---------- Pass 1: how many live price-levels? ----------
    uint256 levelCnt;
    {
      uint256 summary = summaries[_summaryIx(isBid, isPut)];
      (mapping(uint8 => uint256) storage mid, mapping(uint16 => uint256) storage det) = _maps(isBid, isPut);

      uint256 s = summary;
      while (s != 0) {
        uint8 l1 = BitScan.lsb(s); // index of lowest-set bit
        uint256 m = mid[l1];
        while (m != 0) {
          uint8 l2 = BitScan.lsb(m);
          uint16 detKey = (uint16(l1) << 8) | l2;
          uint256 d = det[detKey];
          while (d != 0) {
            ++levelCnt;
            d &= d - 1; // clear lowest-set bit
          }
          m &= m - 1;
        }
        s &= s - 1;
      }
    }

    // ---------- Pass 2: write the data ----------
    levels_ = new OBLevel[](levelCnt);
    {
      uint256 idx;
      uint256 summary = summaries[_summaryIx(isBid, isPut)];
      (mapping(uint8 => uint256) storage mid, mapping(uint16 => uint256) storage det) = _maps(isBid, isPut);

      uint256 s = summary;
      while (s != 0) {
        uint8 l1 = BitScan.lsb(s);
        uint256 m = mid[l1];
        while (m != 0) {
          uint8 l2 = BitScan.lsb(m);
          uint16 detKey = (uint16(l1) << 8) | l2;
          uint256 d = det[detKey];
          while (d != 0) {
            uint8 l3 = BitScan.lsb(d);
            uint32 tick = BitScan.join(l1, l2, l3);
            uint32 key = _key(tick, isPut, isBid);

            levels_[idx++] = OBLevel({tick: tick, vol: levels[key].vol});
            d &= d - 1;
          }
          m &= m - 1;
        }
        s &= s - 1;
      }
    }
  }

  // #######################################################################
  // #                                                                     #
  // #                  Admin functions                                    #
  // #                                                                     #
  // #######################################################################

  function pause() external override onlyOwner {
    _pause();
  }

  function unpause() external override onlyOwner {
    _unpause();
  }

  /**
   * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract.
   * Called by
   * {upgradeTo} and {upgradeToAndCall}.
   * @param newImplementation Address of the new implementation contract
   */
  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
