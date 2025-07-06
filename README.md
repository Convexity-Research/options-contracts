# opt.fun Contract Documentation

## Overview

opt.fun is a decentralized options trading platform on HyperEVM that enables traders to buy and sell 1-minute expiry at-the-money (ATM) options. The platform provides a streamlined trading experience for short-term options strategies with automated settlement and collateral management.

### Key Features
- **High leverage**: Up to 1000x leverage on deposited collateral
- **1-minute expiry cycles**: Each trading cycle lasts exactly 60 seconds from initiation to settlement
- **At-the-money strikes**: All options are automatically struck at the current oracle price when the cycle begins
- **Binary settlement**: Options expire either in-the-money (ITM) or out-of-the-money (OTM)
- **Gasless trading**: Sponsored by the opt.fun team using ERC2771 meta-transactions
- **Automated liquidations**: Protect system solvency through automated position liquidation

### Use Cases
- **Speculating**: Capitalize on small price movements with minimal capital via high leverage
- **Hedging**: Quickly hedge spot positions over a 1-minute period
- **Yield Farming**: Provide liquidity by selling options and collecting premiums
- **Market Making**: Simultaneous buying and selling to capture bid-ask spreads

## Architecture & Implementation Choices

### 1. Upgradeable Proxy Pattern
The contract uses OpenZeppelin's UUPS (Universal Upgradeable Proxy Standard) pattern, allowing for future improvements while maintaining state continuity.

### 2. ERC2771 Meta-Transactions
Implements gasless trading through trusted forwarders, enabling users to trade without holding native tokens for gas.

### 3. Cycle-Based Trading
- Each cycle is identified by its expiry timestamp (Unix timestamp)
- Strike price is set to the oracle price at cycle initiation
- Trading is only allowed during active cycles (before expiry)

### 4. Three-Level Bitmap Orderbook
The orderbook uses an efficient three-level bitmap structure for O(1) best price discovery:
- **L1 (Summary)**: 256-bit summary of which 65k-tick blocks have liquidity
- **L2 (Mid)**: 256-bit bitmap for each L1 block, showing which 256-tick sub-blocks have orders
- **L3 (Detail)**: 256-bit bitmap for each L2 block, showing exact ticks with liquidity

### 5. Position Tracking
User positions are tracked efficiently in a packed struct:
```solidity
struct UserAccount {
    bool activeInCycle;
    bool liquidationQueued;
    uint64 balance;              // Collateral balance
    uint64 liquidationFeeOwed;
    uint64 scratchPnL;           // Temporary PnL storage during settlement
    uint48 _gap;                 // Reserved for future use
    uint32 longCalls;            // Actual positions
    uint32 shortCalls;
    uint32 longPuts;
    uint32 shortPuts;
    uint32 pendingLongCalls;     // Pending limit orders
    uint32 pendingShortCalls;
    uint32 pendingLongPuts;
    uint32 pendingShortPuts;
}
```

### 6. Two-Phase Settlement
To ensure fair social loss distribution:
- **Phase 1**: Calculate PnL, debit losers immediately, store winners' PnL
- **Phase 2**: Credit winners pro-rata based on available funds after accounting for bad debt

### 7. Taker Queue System
Unfilled market orders are queued in buckets corresponding to each market side, allowing them to be filled by incoming limit orders.

### 8. Oracle Integration
Uses a precompile at address `0x0000000000000000000000000000000000000806` for price feeds, ensuring reliable and gas-efficient price updates. This is the `Mark price` used by the Hyperliquid perps dex.

## Constants & Configuration

```solidity
uint256 constant TICK_SZ = 1e4;              // 0.01 USDT tick size
uint256 constant MM_BPS = 10;                 // 0.10% Maintenance Margin
uint256 constant CONTRACT_SIZE = 100;         // Position size divisor
uint256 constant liquidationFeeBps = 10;     // 0.1% liquidation fee
uint256 constant DEFAULT_EXPIRY = 1 minutes; // Cycle duration
```

## Public/External Functions

### Collateral Management

#### `depositCollateral(uint256 amount, bytes memory signature)`
Deposits USDT collateral with whitelist signature verification.
- **Parameters**: 
  - `amount`: Amount of USDT to deposit (6 decimals)
  - `signature`: Signature from whitelist signer to authorize the address
- **Effects**: Adds user to whitelist and credits their balance
- **Events**: `CollateralDeposited`

#### `depositCollateral(uint256 amount)`
Deposits USDT collateral for already whitelisted users.
- **Parameters**: `amount`: Amount of USDT to deposit
- **Requirements**: User must be whitelisted
- **Events**: `CollateralDeposited`

#### `withdrawCollateral(uint256 amount)`
Withdraws USDT collateral from the platform.
- **Parameters**: `amount`: Amount to withdraw
- **Requirements**: 
  - User must have no open positions or orders
  - Sufficient balance available
- **Events**: `CollateralWithdrawn`

### Trading Functions

#### `long(uint256 size, uint256 limitPriceBuy, uint256 limitPriceSell, uint256 cycleId)`
Places a "long" position (buy call + sell put) for directional upward exposure.
- **Parameters**:
  - `size`: Number of contracts (scaled by CONTRACT_SIZE)
  - `limitPriceBuy`: Limit price for the call buy order
  - `limitPriceSell`: Limit price for the put sell order
  - `cycleId`: Target cycle (0 for current active cycle)
- **Effects**: Places limit orders for CALL_BUY and PUT_SELL
- **Use Case**: Betting that price will go up

#### `short(uint256 size, uint256 limitPriceBuy, uint256 limitPriceSell, uint256 cycleId)`
Places a "short" position (buy put + sell call) for directional downward exposure.
- **Parameters**:
  - `size`: Number of contracts
  - `limitPriceBuy`: Limit price for the put buy order
  - `limitPriceSell`: Limit price for the call sell order
  - `cycleId`: Target cycle (0 for current active cycle)
- **Effects**: Places limit orders for PUT_BUY and CALL_SELL
- **Use Case**: Betting that price will go down

#### `placeOrder(MarketSide side, uint256 size, uint256 limitPrice, uint256 cycleId)`
Places individual orders with full control over side and price.
- **Parameters**:
  - `side`: Market side (CALL_BUY, CALL_SELL, PUT_BUY, PUT_SELL)
  - `size`: Order size
  - `limitPrice`: Limit price (0 for market order)
  - `cycleId`: Target cycle
- **Returns**: Order ID
- **Effects**: 
  - Market orders: Immediately matched against orderbook, remainder queued
  - Limit orders: Added to orderbook if not crossing

#### `placeMultiOrder(MarketSide[] memory sides, uint256[] memory sizes, uint256[] memory limitPrices, uint256 cycleId)`
Places multiple orders in a single transaction.
- **Parameters**:
  - `sides`: Array of market sides for each order
  - `sizes`: Array of order sizes
  - `limitPrices`: Array of limit prices
  - `cycleId`: Target cycle
- **Effects**: Executes multiple `placeOrder` calls atomically
- **Use Case**: Efficiently placing complex multi-leg strategies

#### `cancelOrder(uint256 orderId)`
Cancels an existing limit order.
- **Parameters**: `orderId`: ID of order to cancel
- **Requirements**: 
  - Market must be live
  - Caller must own the order
  - User cannot be liquidatable
- **Effects**: Removes order from orderbook and updates position tracking
- **Events**: `LimitOrderCancelled`

#### `cancelAndClose(uint256 buyCallPrice, uint256 sellCallPrice, uint256 buyPutPrice, uint256 sellPutPrice)`
Cancels all existing orders and places neutralizing orders to close net positions.
- **Parameters**:
  - `buyCallPrice`: Limit price for buying calls (if net short calls)
  - `sellCallPrice`: Limit price for selling calls (if net long calls)
  - `buyPutPrice`: Limit price for buying puts (if net short puts)
  - `sellPutPrice`: Limit price for selling puts (if net long puts)
- **Effects**: 
  - Cancels all maker orders and taker queue entries
  - Places orders to neutralize net call and put positions
- **Use Case**: Emergency position closure and risk management

### Risk Management

#### `liquidate(address trader)`
Liquidates an undercollateralized trader.
- **Parameters**: `trader`: Address to liquidate
- **Requirements**: 
  - Market must be live
  - Trader must be liquidatable (balance < required margin)
- **Effects**:
  - Cancels all maker orders
  - Clears taker queue entries
  - Places market orders to close net short positions
  - Queues liquidation fee collection
- **Events**: `Liquidated`

### Cycle Management

#### `startCycle()`
Initiates a new 1-minute trading cycle.
- **Requirements**:
  - No active cycle, or active cycle is expired and settled
  - Valid oracle price available
- **Effects**:
  - Creates new cycle with current timestamp + 1 minute as expiry
  - Sets strike price to current oracle price
  - Resets settlement state
- **Events**: `CycleStarted`

#### `settleChunk(uint256 max, bool pauseNextCycle)`
Processes settlement for a batch of traders.
- **Parameters**: 
  - `max`: Maximum number of traders to process
  - `pauseNextCycle`: If true, prevents automatic cycle start after settlement (always false unless you are Security Council)
- **Two-Phase Process**:
  - **Phase 1**: Calculate PnL, debit losers, accumulate winners' PnL
  - **Phase 2**: Credit winners proportionally after social loss calculation
- **Effects**: Updates trader balances and positions
- **Events**: `PriceFixed`, `Settled`, `CycleSettled`

### View Functions

#### `getName()`
Returns the market name.
- **Returns**: String market name

#### `getCollateralToken()`
Returns the address of the collateral token.
- **Returns**: Address of the collateral token (USDT)

#### `getWhitelist(address account)`
Checks if an address is whitelisted.
- **Parameters**: `account`: Address to check
- **Returns**: Boolean indicating whitelist status

#### `getMmBps()`
Returns the maintenance margin in basis points.
- **Returns**: Maintenance margin (MM_BPS constant)

#### `getActiveCycle()`
Returns the current active cycle ID.
- **Returns**: Active cycle timestamp/ID

#### `getCycles(uint256 cycleId)`
Returns cycle information for a given cycle ID.
- **Parameters**: `cycleId`: Cycle to query
- **Returns**: Cycle struct with strike price, settlement price, and settled status

#### `getUserAccounts(address trader)`
Returns complete user account information.
- **Parameters**: `trader`: Address to query
- **Returns**: UserAccount struct with all position and balance data

#### `getUserOrders(address trader)`
Returns all order IDs for a given trader.
- **Parameters**: `trader`: Address to query
- **Returns**: Array of order IDs

#### `getLevels(uint32 key)`
Returns orderbook level information for a given key.
- **Parameters**: `key`: Level key to query
- **Returns**: Level struct with volume, head, and tail order IDs

#### `getTakerQ(uint256 side)`
Returns the taker queue for a given market side.
- **Parameters**: `side`: Market side (0-3 for CALL_BUY, CALL_SELL, PUT_BUY, PUT_SELL)
- **Returns**: Array of queued taker orders

#### `getNumTraders()`
Returns the number of active traders in the current cycle.
- **Returns**: Number of traders

#### `isLiquidatable(address trader)` / `isLiquidatable(address trader, uint64 price)`
Checks if a trader can be liquidated.
- **Parameters**: 
  - `trader`: Address to check
  - `price`: Oracle price (optional, fetches current if not provided)
- **Returns**: Boolean indicating liquidation eligibility

## Settlement Mechanics

### PnL Calculation
For each trader, PnL is calculated based on the intrinsic value of their positions:

**Call Options**: `max(settlementPrice - strikePrice, 0) * longCalls - max(settlementPrice - strikePrice, 0) * shortCalls`

**Put Options**: `max(strikePrice - settlementPrice, 0) * longPuts - max(strikePrice - settlementPrice, 0) * shortPuts`



## Risk Parameters

### Margin Requirements
- **Maintenance Margin**: 0.10% of strike notional value
- **Buffer**: Current loss + maintenance margin on net short exposure
- **Liquidation Trigger**: Balance < required margin

### Position Limits
- **No Position Limits**: Users can take unlimited size positions if they have sufficient collateral

## Events

The contract emits comprehensive events for all major operations:
- `CycleStarted`, `CycleSettled`
- `CollateralDeposited`, `CollateralWithdrawn`
- `LimitOrderPlaced`, `LimitOrderFilled`, `LimitOrderCancelled`
- `TakerOrderPlaced`, `TakerOrderRemaining`
- `Liquidated`, `Settled`, `PriceFixed`

## Security Features

1. **Pausable**: Emergency pause functionality
2. **Upgradeable**: UUPS proxy pattern for controlled upgrades
3. **Access Control**: Owner-only functions for critical operations
4. **Reentrancy Protection**: SafeERC20 for token transfers
5. **Overflow Protection**: Solidity 0.8+ automatic overflow checks
6. **Liquidation Protection**: Automatic liquidation prevents system insolvency 
