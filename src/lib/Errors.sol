// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

library Errors {
  string constant INVALID_ORACLE_PRICE = "INVALID_ORACLE_PRICE";
  string constant CYCLE_ALREADY_STARTED = "CYCLE_ALREADY_STARTED";
  string constant PREVIOUS_CYCLE_NOT_SETTLED = "PREVIOUS_CYCLE_NOT_SETTLED";
  string constant INVALID_AMOUNT = "INVALID_AMOUNT";
  string constant INSUFFICIENT_BALANCE = "INSUFFICIENT_BALANCE";
  string constant NOT_OWNER = "NOT_OWNER";
  string constant NOT_WHITELISTED = "NOT_WHITELISTED";
  string constant INVALID_SIGNATURE = "INVALID_SIGNATURE";
  string constant ORACLE_PRICE_CALL_FAILED = "ORACLE_PRICE_CALL_FAILED";
  string constant CYCLE_ACTIVE = "CYCLE_ACTIVE";
  string constant STILL_SOLVENT = "STILL_SOLVENT";
  string constant IN_TRADER_LIST = "IN_TRADER_LIST";
  string constant NOT_EXPIRED = "NOT_EXPIRED";
  string constant PRICE_NOT_FIXED = "PRICE_NOT_FIXED";
  string constant CYCLE_ALREADY_SETTLED = "CYCLE_ALREADY_SETTLED";
  string constant MARKET_NOT_LIVE = "MARKET_NOT_LIVE";
}
