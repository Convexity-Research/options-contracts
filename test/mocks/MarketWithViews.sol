// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Market, MarketSide} from "../../src/Market.sol";
import {BitScan} from "../../src/lib/Bitscan.sol";
import {Level} from "../../src/interfaces/IMarket.sol";
import {Errors} from "../../src/lib/Errors.sol";
import {TakerQ} from "../../src/interfaces/IMarket.sol";

struct OBLevel {
  uint32 tick; // raw tick
  uint128 vol; // resting contracts at that tick
}

/**
 * A thin test-only wrapper that lets unit-tests “see” the private order-book of
 * the upgraded Market contract.
 *
 * Nothing here is intended for production-deployment.
 */
contract MarketWithViews is Market {
  /**
   * Dump one side of the current cycle’s book.
   *
   * @param  side  Which of the 4 sides (CALL/PUT × BID/ASK) to walk.
   */
  function dumpBook(MarketSide side) external view returns (OBLevel[] memory levels_) {
    // ───────────────────────────────────────────────────────────────
    // 1. How many live price-levels?  ──>  pre-size the array
    // ───────────────────────────────────────────────────────────────
    uint256 levelCnt;
    {
      OrderbookState storage o = ob[activeCycle];

      uint256 summary = o.summaries[uint256(side)];
      mapping(uint8 => uint256) storage mid = o.mids[side];
      mapping(uint16 => uint256) storage det = o.dets[side];

      uint256 s = summary;
      while (s != 0) {
        uint8 l1 = BitScan.lsb(s);
        uint256 m = mid[l1];
        while (m != 0) {
          uint8 l2 = BitScan.lsb(m);
          uint16 detKey = (uint16(l1) << 8) | l2;
          uint256 d = det[detKey];
          while (d != 0) {
            ++levelCnt;
            d &= d - 1; // clear lowest set bit
          }
          m &= m - 1;
        }
        s &= s - 1;
      }
    }

    // ───────────────────────────────────────────────────────────────
    // 2. Populate the return array
    // ───────────────────────────────────────────────────────────────
    levels_ = new OBLevel[](levelCnt);
    {
      OrderbookState storage o = ob[activeCycle];

      uint256 summary = o.summaries[uint256(side)];
      mapping(uint8 => uint256) storage mid = o.mids[side];
      mapping(uint16 => uint256) storage det = o.dets[side];
      mapping(uint32 => Level) storage lvl = o.levels;

      uint256 s = summary;
      uint256 idx;
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
            uint32 key = _keyy(tick, side); // helper from Market

            levels_[idx++] = OBLevel({tick: tick, vol: lvl[key].vol});

            d &= d - 1;
          }
          m &= m - 1;
        }
        s &= s - 1;
      }
    }
  }

  function viewTakerQueue(MarketSide side) external view returns (TakerQ[] memory) {
    return takerQ[uint256(side)];
  }

  function getUserAccount(address trader) external view returns (UserAccount memory) {
    return userAccounts[trader];
  }

  function levels(uint32 key) external view returns (Level memory) {
    return ob[activeCycle].levels[key];
  }

  function summaries(uint256 side) external view returns (uint256) {
    return ob[activeCycle].summaries[side];
  }

  function mids(MarketSide side, uint8 l1) external view returns (uint256) {
    return ob[activeCycle].mids[side][l1];
  }

  function dets(MarketSide side, uint16 detKey) external view returns (uint256) {
    return ob[activeCycle].dets[side][detKey];
  }

  /* ─────────────────────────── helpers ─────────────────────────── */
  function _keyy(uint32 tick, MarketSide side) internal pure returns (uint32) {
    // copied verbatim from the new Market
    if (tick >= 1 << 24) revert Errors.TickTooLarge();
    bool isPut = (side == MarketSide.PUT_BUY || side == MarketSide.PUT_SELL);
    bool isBid = (side == MarketSide.CALL_BUY || side == MarketSide.PUT_BUY);
    return tick | (isPut ? 1 << 31 : 0) | (isBid ? 1 << 30 : 0);
  }

  function liquidationPrices(address trader) external view returns (uint64 upperPx, uint64 lowerPx) {
    UserAccount memory ua = userAccounts[trader];

    uint256 netShortCalls = ua.shortCalls > ua.longCalls ? ua.shortCalls - ua.longCalls : 0;
    uint256 netShortPuts = ua.shortPuts > ua.longPuts ? ua.shortPuts - ua.longPuts : 0;

    if (netShortCalls == 0 && netShortPuts == 0) return (0, 0);

    uint256 strike = cycles[activeCycle].strikePrice; // 6-dp
    uint256 balance = ua.balance;

    uint256 notional = (netShortCalls + netShortPuts) * strike / CONTRACT_SIZE;
    uint256 buffer = notional * MM_BPS / denominator; // 0.10 %

    if (netShortCalls > 0) {
      if (balance <= buffer) {
        upperPx = uint64(strike); // already unsafe
      } else {
        uint256 delta = (balance - buffer) * CONTRACT_SIZE / netShortCalls;
        // add one extra increment so that price == upperPx is unsafe
        upperPx = uint64(strike + delta + CONTRACT_SIZE);
      }
    }

    if (netShortPuts > 0) {
      if (balance <= buffer) {
        lowerPx = uint64(strike);
      } else {
        uint256 delta = (balance - buffer) * CONTRACT_SIZE / netShortPuts;
        // subtract extra increment; guard against under-flow
        lowerPx = uint64(
          strike > delta + CONTRACT_SIZE ? strike - delta - CONTRACT_SIZE : 0 // never below zero
        );
      }
    }
  }
}
