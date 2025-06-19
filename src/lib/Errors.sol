// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

library Errors {
  error InvalidAmount();
  error InsufficientBalance();
  error NotOrderOwner();
  error NotWhitelisted();
  error InvalidWhitelistSignature();
  error OraclePriceCallFailed();
  error CycleActive();
  error StillSolvent();
  error InTraderList();
  error NotExpired();
  error CycleAlreadySettled();
  error MarketNotLive();
  error TickTooLarge();
  error AccountInLiquidation();
  error TraderLiquidatable();
  error NotSecurityCouncil();
}
