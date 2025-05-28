// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title BitScan
/// @notice Uses De Bruijn algorithm to determine index of least/most significant set bit
library BitScan {
  uint256 private constant DEBR =
    0x06_2E_90_88_45_45_96_44_1C_1D_F7_1F_DF_BE_5B_BF_77_7C_A6_1B_37_54_AF_F5_CB_1A_EC_DB_8F_BB_BB_4F;

  /// Packed 0x00 01 02 … 1F
  bytes32 private constant LOOK = 0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f;

  /// @dev return byte `idx` of LOOK (0-31) as uint8
  function _lookup(uint256 idx) private pure returns (uint8 r) {
    assembly {
      r := byte(idx, LOOK)
    }
  }

  /// least-significant-set-bit index (0-255).  Reverts on w == 0.
  function lsb(uint256 w) internal pure returns (uint8) {
    unchecked {
      return _lookup(((w & (~w + 1)) * DEBR) >> 248);
    }
  }

  /// most-significant-set-bit index (0-255).  Reverts on w == 0.
  function msb(uint256 w) internal pure returns (uint8) {
    unchecked {
      w |= w >> 1;
      w |= w >> 2;
      w |= w >> 4;
      w |= w >> 8;
      w |= w >> 16;
      w |= w >> 32;
      w |= w >> 64;
      w |= w >> 128;
      uint256 iso = (w + 1) >> 1; // isolate msb
      return _lookup((iso * DEBR) >> 248);
    }
  }

  function mask(uint8 ix) internal pure returns (uint256) {
    return uint256(1) << ix;
  }

  /*—— optional helpers to pack/unpack tick bytes ———*/
  function split(uint32 t) internal pure returns (uint8 l1, uint8 l2, uint8 l3) {
    l1 = uint8(t >> 16);
    l2 = uint8(t >> 8);
    l3 = uint8(t);
  }

  function join(uint8 l1, uint8 l2, uint8 l3) internal pure returns (uint32) {
    return (uint32(l1) << 16) | (uint32(l2) << 8) | l3;
  }
}
