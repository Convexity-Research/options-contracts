// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

enum Side {
  BUY,
  SELL
}

enum OptionType {
  CALL,
  PUT
}

struct Cycle {
  bool active;
  bool isSettled;
  uint96 strikePrice;
  uint96 settlementPrice;
}

struct Pos {
  uint96 longCalls;
  uint96 shortCalls;
  uint96 longPuts;
  uint96 shortPuts;
}

struct Level {
  // one storage slot
  uint128 vol;
  uint16 head; // first maker node
  uint16 tail; // last  maker node
}

struct Maker {
  address trader;
  uint128 size;
  uint16 next;
  uint32 key;
  uint16 prev; // back-pointer for cancel
}

interface IMarket {
  function name() external view returns (string memory);
  function startCycle(uint256 expiry) external;
  function activeCycle() external view returns (uint256);

  function depositCollateral(uint256 amount) external;
  function withdrawCollateral(uint256 amount) external;

  function placeOrder(OptionType option, Side side, uint256 size, uint256 limitPrice)
    external
    returns (uint256 orderId);
  function cancelOrder(uint256 cycleId, uint256 orderId) external;

  function matchOrders(uint256 cycleId) external;
  function liquidate(uint256 orderId, address trader) external;
  function settle(uint256 cycleId) external;

  function updateFees(uint16 makerFee, uint16 takerFee) external;
  function pause() external;
  function unpause() external;
}
