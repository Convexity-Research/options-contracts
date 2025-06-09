// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

contract OracleTester {
  address immutable ORACLE_PX_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000807;

  uint256 btcPrice = 3;

  function oraclePx(uint32 index) public view returns (uint64) {
    bool success;
    bytes memory result;
    (success, result) = ORACLE_PX_PRECOMPILE_ADDRESS.staticcall(abi.encode(index));
    require(success, "OraclePx precompile call failed");
    return abi.decode(result, (uint64));
  }

  function setBtcPrice() public {
    btcPrice = uint256(oraclePx(0));
  }

  function getBtcPrice() public view returns (uint256) {
    return btcPrice;
  }
}
