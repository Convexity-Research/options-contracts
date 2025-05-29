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
}
