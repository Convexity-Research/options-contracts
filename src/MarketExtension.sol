// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SharedStorage} from "./SharedStorage.sol";
import {Cycle, Level, TakerQ} from "./interfaces/IMarket.sol";

contract MarketExtension is SharedStorage {
  function getName() external view returns (string memory) {
    return name;
  }

  function getCollateralToken() external view returns (address) {
    return collateralToken;
  }

  function getWhitelist(address account) external view returns (bool) {
    return whitelist[account];
  }

  function getMmBps() external pure returns (uint256) {
    return MM_BPS;
  }

  function getActiveCycle() external view returns (uint256) {
    return activeCycle;
  }

  function getCycles(uint256 cycleId) external view returns (Cycle memory) {
    return cycles[cycleId];
  }

  function getUserAccounts(address trader) external view returns (UserAccount memory) {
    return userAccounts[trader];
  }

  function getUserOrders(address trader) external view returns (uint32[] memory) {
    return userOrders[trader];
  }

  function getLevels(uint32 key) external view returns (Level memory) {
    return ob[activeCycle].levels[key];
  }

  function getTakerQ(uint256 side) external view returns (TakerQ[] memory) {
    return takerQ[side];
  }

  function getNumTraders() public view returns (uint256) {
    return traders.length;
  }
}
