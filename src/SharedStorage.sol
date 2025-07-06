// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarket, Cycle, Level, Maker, TakerQ, MarketSide} from "./interfaces/IMarket.sol";

contract SharedStorage {
  //------- Meta -------
  string internal name;
  address internal feeRecipient;
  address internal collateralToken;
  uint256 constant collateralDecimals = 6;
  address constant MARK_PX_PRECOMPILE = 0x0000000000000000000000000000000000000806;
  uint256 constant TICK_SZ = 1e2; // 0.0001 USDT0 → 100 wei (only works for 6-decimals tokens)
  uint256 constant MM_BPS = 10; // 0.10 % Maintenance Margin (also used in place of an initial margin)
  uint256 constant CONTRACT_SIZE = 100; // Divide by this factor for 0.01BTC
  int256 constant makerFeeBps = -200; // -2.00 %, basis points. Negative means its a fee rebate, so pay out to makers
  int256 constant takerFeeBps = 700; // +7.00 %, basis points
  uint256 constant liquidationFeeBps = 10; // 0.1 %, basis points
  uint256 constant denominator = 10_000;
  uint256 constant DEFAULT_EXPIRY = 1 minutes;
  address constant SECURITY_COUNCIL = 0xAd8997fAaAc3DA36CA0aA88a0AAf948A6C3a5338;

  //------- Gasless TX -------
  address internal _trustedForwarder;

  //------- Whitelist -------
  address internal constant WHITELIST_SIGNER = 0x988EeB53b37f5418aCdaD66cF09B60991ED01f45;
  mapping(address => bool) internal whitelist;

  //------- user account -------
  mapping(address => UserAccount) internal userAccounts;

  struct UserAccount {
    bool activeInCycle;
    bool liquidationQueued;
    uint64 balance;
    uint64 liquidationFeeOwed;
    uint64 scratchPnL;
    uint48 _gap; // 48 remaining bits for future use. Packs position data into next slot
    uint32 longCalls;
    uint32 shortCalls;
    uint32 longPuts;
    uint32 shortPuts;
    uint32 pendingLongCalls;
    uint32 pendingShortCalls;
    uint32 pendingLongPuts;
    uint32 pendingShortPuts;
  }

  //------- Cycle state -------
  uint256 internal activeCycle; // expiry unix timestamp as ID
  mapping(uint256 => Cycle) internal cycles;

  //------- Trading/Settlement -------
  address[] traders;
  mapping(address => uint32[]) userOrders; // Track all order IDs per user
  uint256 cursor; // settlement iterator

  TakerQ[][4] takerQ; // 4 buckets
  uint256[4] tqHead; // cursor per bucket

  // Two-phase settlement for fair social loss distribution
  uint256 posSum; // total positive PnL (winners)
  uint256 badDebt; // grows whenever we meet an under-collateralised loser
  bool settlementPhase; // false = phase 1, true = phase 2
  bool _gap1; // true = only allow settlement, no new cycles

  //------- Orderbook -------
  mapping(uint256 => OrderbookState) internal ob;

  struct OrderbookState {
    // summary level of orderbook (L1): which [256*256] blocks have liquidity
    uint256[4] summaries;
    // mid level of orderbook (L2): which [256] block has liquidity
    mapping(MarketSide => mapping(uint8 => uint256)) mids;
    // detail level of orderbook (L3): which tick has liquidity
    mapping(MarketSide => mapping(uint16 => uint256)) dets;
    // mappings to fetch relevant orderbook data
    mapping(uint32 => Level) levels; // tickKey ⇒ Level
    mapping(uint32 => Maker) makerNodes; // nodeId  ⇒ Maker
    uint32 limitOrderPtr; // auto-increment id for limit orders
    int32 takerOrderPtr; // auto-increment id for taker orders
  }

  //------- Extension -------
  address internal extensionContract;
}
