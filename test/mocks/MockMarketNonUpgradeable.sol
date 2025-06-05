// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MarketNonUpgradeable} from "../../src/MarketNonUpgradeable.sol";
import {TakerQ} from "../../src/interfaces/IMarket.sol";
import {BitScan} from "../../src/lib/Bitscan.sol";

struct OBLevel {
  uint32 tick; // raw tick
  uint128 vol; // resting contracts at that tick
}

contract MockMarketNonUpgradeable is MarketNonUpgradeable {
  constructor(
    string memory _name,
    address _feeRecipient,
    address _collateralToken,
    address _forwarder,
    address _whitelistSigner
  ) MarketNonUpgradeable(_name, _feeRecipient, _collateralToken, _forwarder, _whitelistSigner) {}

  function viewTakerQueue(bool isPut, bool isBid) external view returns (TakerQ[] memory) {
    return takerQ[isPut ? 1 : 0][isBid ? 1 : 0];
  }

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
}
