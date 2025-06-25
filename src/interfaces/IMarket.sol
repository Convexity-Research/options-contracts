// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

enum MarketSide {
  CALL_BUY,
  CALL_SELL,
  PUT_BUY,
  PUT_SELL
}

struct Cycle {
  bool isSettled;
  uint64 strikePrice;
  uint64 settlementPrice;
}

struct Level {
  // one storage slot
  uint128 vol;
  uint32 head; // first maker node
  uint32 tail; // last  maker node
}

struct Maker {
  address trader;
  uint128 size;
  uint32 next;
  uint32 key;
  uint32 prev; // back-pointer for cancel
}

struct TakerQ {
  address trader;
  uint64 size;
  int32 takerOrderId;
}

interface IMarket {
  function name() external view returns (string memory);
  function startCycle() external;
  function activeCycle() external view returns (uint256);

  function depositCollateral(uint256 amount) external;
  function withdrawCollateral(uint256 amount) external;

  function long(uint256 size, uint256 cycleId) external;
  function short(uint256 size, uint256 cycleId) external;
  function cancelOrder(uint256 orderId) external;
  function placeOrder(MarketSide side, uint256 size, uint256 limitPrice, uint256 cycleId)
    external
    returns (uint256 orderId);

  function liquidate(address trader) external;
  function settleChunk(uint256 max) external;
}
