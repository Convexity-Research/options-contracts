// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MarketSide} from "../interfaces/IMarket.sol";

/**
 * - Credit to: https://github.com/estarriolvetch/solidity-bits
 *
 * Slightly modified to return msb() with LSB-based indexing.
 */
library BitScan {
  uint256 private constant DEBRUIJN_256 = 0x818283848586878898a8b8c8d8e8f929395969799a9b9d9e9faaeb6bedeeff;
  bytes private constant LOOKUP_TABLE_256 =
    hex"0001020903110a19042112290b311a3905412245134d2a550c5d32651b6d3a7506264262237d468514804e8d2b95569d0d495ea533a966b11c886eb93bc176c9071727374353637324837e9b47af86c7155181ad4fd18ed32c9096db57d59ee30e2e4a6a5f92a6be3498aae067ddb2eb1d5989b56fd7baf33ca0c2ee77e5caf7ff0810182028303840444c545c646c7425617c847f8c949c48a4a8b087b8c0c816365272829aaec650acd0d28fdad4e22d6991bd97dfdcea58b4d6f29fede4f6fe0f1f2f3f4b5b6b607b8b93a3a7b7bf357199c5abcfd9e168bcdee9b3f1ecf5fd1e3e5a7a8aa2b670c4ced8bbe8f0f4fc3d79a1c3cde7effb78cce6facbf9f8";

  /**
   * @dev Isolate the least significant set bit.
   */
  function isolateLS1B256(uint256 bb) internal pure returns (uint256) {
    require(bb > 0);
    unchecked {
      return bb & (0 - bb);
    }
  }

  /**
   * @dev Isolate the most significant set bit.
   */
  function isolateMS1B256(uint256 bb) internal pure returns (uint256) {
    require(bb > 0);
    unchecked {
      bb |= bb >> 128;
      bb |= bb >> 64;
      bb |= bb >> 32;
      bb |= bb >> 16;
      bb |= bb >> 8;
      bb |= bb >> 4;
      bb |= bb >> 2;
      bb |= bb >> 1;

      return (bb >> 1) + 1;
    }
  }

  /**
   * @dev Find the index of the lest significant set bit. (trailing zero count)
   */
  function lsb(uint256 bb) internal pure returns (uint8) {
    unchecked {
      return uint8(LOOKUP_TABLE_256[(isolateLS1B256(bb) * DEBRUIJN_256) >> 248]);
    }
  }

  /**
   * @dev Find the index of the most significant set bit.
   */
  function msb(uint256 bb) internal pure returns (uint8) {
    require(bb > 0, "msb(0)");
    unchecked {
      // isolate MS1B
      bb = isolateMS1B256(bb);
      // De-Bruijn branchless log2
      return uint8(LOOKUP_TABLE_256[(bb * DEBRUIJN_256) >> 248]);
    }
  }

  function mask(uint8 ix) internal pure returns (uint256) {
    return uint256(1) << ix;
  }

  function log2(uint256 bb) internal pure returns (uint8) {
    unchecked {
      return uint8(LOOKUP_TABLE_256[(isolateMS1B256(bb) * DEBRUIJN_256) >> 248]);
    }
  }

  function join(uint8 l1, uint8 l2, uint8 l3) internal pure returns (uint32 result) {
    assembly {
      // Shift into their 24-bit positions:
      let p1 := shl(16, l1) // l1 << 16
      let p2 := shl(8, l2) // l2 << 8

      // Combine: (l1<<16) | (l2<<8) | l3
      result := or(or(p1, p2), l3)
    }
  }

  function split(uint32 t) internal pure returns (uint8 l1, uint8 l2, uint8 l3) {
    assembly {
      // byte(i, x) returns the i-th byte of x (0 = most-significant,
      // 31 = least-significant).  A uint32 sits in the low 4 bytes of
      // the 32-byte word, so the three bytes we care about are 29-31.
      l1 := byte(29, t)
      l2 := byte(30, t)
      l3 := byte(31, t)
    }
  }

  function splitKey(uint32 key) internal pure returns (uint32 tick, MarketSide side) {
    bool isPut = (key & (1 << 31)) != 0;
    bool isBid = (key & (1 << 30)) != 0;
    tick = key & 0x00FF_FFFF; // Only take rightmost 24 bits for tick

    // Convert bools to MarketSide enum
    // CALL_BUY=0, CALL_SELL=1, PUT_BUY=2, PUT_SELL=3
    side = MarketSide((isPut ? 2 : 0) | (isBid ? 0 : 1));
  }
}
