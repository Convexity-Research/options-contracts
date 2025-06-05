// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

library Errors {
  string constant INVALID_ORACLE_PRICE = "1";
  string constant CYCLE_ALREADY_STARTED = "2";
  string constant PREVIOUS_CYCLE_NOT_SETTLED = "3";
  string constant INVALID_AMOUNT = "4";
  string constant INSUFFICIENT_BALANCE = "5";
  string constant NOT_OWNER = "6";
  string constant NOT_WHITELISTED = "7";
  string constant INVALID_SIGNATURE = "8";
  string constant ORACLE_PRICE_CALL_FAILED = "9";
  string constant CYCLE_ACTIVE = "10";
  string constant STILL_SOLVENT = "11";
  string constant IN_TRADER_LIST = "12";
  string constant NOT_EXPIRED = "13";
  string constant PRICE_NOT_FIXED = "14";
  string constant CYCLE_ALREADY_SETTLED = "15";
  string constant MARKET_NOT_LIVE = "16";
  string constant TICK_TOO_LARGE = "17";

  error InvalidOraclePrice();
  error CycleAlreadyStarted();
  error PreviousCycleNotSettled();
  error InvalidAmount();
  error InsufficientBalance();
  error NotOwner();
  error NotWhitelisted();
  error InvalidSignature();
  error OraclePriceCallFailed();
  error CycleActive();
  error StillSolvent();
  error InTraderList();
  error NotExpired();
  error PriceNotFixed();
  error CycleAlreadySettled();
  error MarketNotLive();
  error TickTooLarge();
}
