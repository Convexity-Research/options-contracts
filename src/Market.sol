// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BitScan} from "./lib/Bitscan.sol";
import {Errors} from "./lib/Errors.sol";
import {IMarket, Cycle, Pos, Level, Maker, OptionType, Side} from "./interfaces/IMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract Market is IMarket, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable {
  using BitScan for uint256;

  //------- Meta -------
  uint256 private constant TICK_SZ = 1e4; // 0.01 USDC → 10 000 wei (6-decimals)
  string public name;
  address public priceOracle;
  IERC20 public collateralToken;
  int16 public makerFeeBps = 10; // +0.10 %, basis points
  int16 public takerFeeBps = -40; // –0.40 %, basis points
  address public feeRecipient; //

  //------- Vault -------
  mapping(address => uint256) public balances;
  mapping(uint256 => mapping(address => uint256)) public lockedCollateral;

  //------- Cycle state -------
  uint256 public activeCycle; // expiry unix timestamp as ID
  mapping(uint256 => Cycle) public cycles;

  //------- Trading/Positions -------
  address[] public traders;
  mapping(uint256 => Pos) public positions;
  mapping(address => bool) public inList;
  uint256 public cursor; // settlement iterator

  //------- Orderbook -------
  mapping(uint32 => Level) levels; // tickKey ⇒ Level
  mapping(uint16 => Maker) makerQ; // nodeId  ⇒ Maker
  uint16 nodePtr; // auto-increment id for makers

  // summary (L1): which [256*256] blocks have liquidity
  uint256 summaryCB;
  uint256 summaryCA;
  uint256 summaryPB;
  uint256 summaryPA;

  // mid (L2): which [256] block has liquidity
  mapping(uint8 => uint256) midCB;
  mapping(uint8 => uint256) midCA;
  mapping(uint8 => uint256) midPB;
  mapping(uint8 => uint256) midPA;

  // detail (L3): which tick has liquidity
  mapping(uint16 => uint256) detCB;
  mapping(uint16 => uint256) detCA;
  mapping(uint16 => uint256) detPB;
  mapping(uint16 => uint256) detPA;

  event CycleStarted(uint256 expiry, uint256 strike);
  event CycleSettled(uint256 cycleId);
  event CollateralDeposited(address trader, uint256 amount);
  event CollateralWithdrawn(address trader, uint256 amount);
  event OrderPlaced(uint256 cycleId, uint256 orderId, address trader, uint256 size, uint256 limitPrice);
  event Liquidated(uint256 cycleId, uint256 orderId, address trader, uint256 collateral, bool completed);
  event PriceFixed(uint256 expiry, uint64 price);
  event Trade(uint32 tick, bool isBuy, bool isPut, uint128 size, address taker, address maker);
  event Cancel(uint32 nodeId, address maker, uint128 vol);
  event Settled(address trader, int256 pnl);

  constructor() {
    _disableInitializers();
  }

  function initialize(string memory _name, address _feeRecipient, address _oracleFeed, address _collateralToken)
    external
    initializer
  {
    __Ownable_init(_msgSender());
    __Pausable_init();
    __UUPSUpgradeable_init();

    name = _name;
    feeRecipient = _feeRecipient;
    priceOracle = _oracleFeed;
    collateralToken = IERC20(_collateralToken);
  }

  function startCycle(uint256 expiry) external onlyOwner {
    if (activeCycle != 0) {
      // If there is an active cycle, it must be in the past
      require(activeCycle < block.timestamp, Errors.CYCLE_ALREADY_STARTED);

      // The previous cycle must be settled
      require(cycles[activeCycle].isSettled, Errors.PREVIOUS_CYCLE_NOT_SETTLED);
    }

    //(, int256 price, , , ) = AggregatorV3Interface(priceOracle).latestRoundData();
    int256 price = 1;
    require(price > 0, Errors.INVALID_ORACLE_PRICE);

    // Create new market
    cycles[expiry] = Cycle({
      active: true,
      isSettled: false,
      strikePrice: uint96(uint256(price)),
      settlementPrice: 0 // Set at cycle end time
    });

    // Set as current market
    activeCycle = expiry;

    emit CycleStarted(expiry, uint256(price));
  }

  function depositCollateral(uint256 amount) external {
    require(amount > 0, Errors.INVALID_AMOUNT);

    address trader = _msgSender();

    // Transfer collateral token from user to contract
    collateralToken.transferFrom(trader, address(this), amount);

    // Update user's balance
    balances[trader] += amount;

    emit CollateralDeposited(trader, amount);
  }

  function withdrawCollateral(uint256 amount) external {
    require(amount > 0, Errors.INVALID_AMOUNT);

    address trader = _msgSender();
    uint256 balance = balances[trader] - lockedCollateral[activeCycle][trader];

    require(balance >= amount, Errors.INSUFFICIENT_BALANCE);

    // Update user's balance
    balances[trader] -= amount;

    // Transfer collateral token from contract to user
    collateralToken.transfer(trader, amount);

    emit CollateralWithdrawn(trader, amount);
  }

  function placeOrder(
    OptionType option,
    Side side,
    uint256 size,
    uint256 limitPrice // 0 = market
  ) external returns (uint256 orderId) {
    uint256 cycleId = activeCycle;
    require(size > 0, Errors.INVALID_AMOUNT);

    bool isPut = (option == OptionType.PUT);
    bool isBuy = (side == Side.BUY);

    if (limitPrice == 0) {
      _marketOrder(isBuy, isPut, uint128(size));
      emit OrderPlaced(cycleId, 0, msg.sender, size, 0);
      return 0;
    }

    uint32 tick = uint32(limitPrice / TICK_SZ);

    // Check if the order is better than the best order on the opposite side. Treat as market order if it is.
    (uint32 oppBest,) = _best(!isBuy, isPut);
    if ((isBuy && tick >= oppBest) || (!isBuy && tick <= oppBest)) {
      _marketOrder(isBuy, isPut, uint128(size)); // taker path
      emit OrderPlaced(cycleId, 0, msg.sender, size, 0);
      return 0;
    }

    orderId = _insertLimit(isBuy, isPut, tick, uint128(size));
    emit OrderPlaced(cycleId, orderId, msg.sender, size, limitPrice);
  }

  function cancelOrder(uint256 cycleId, uint256 orderId) external {}

  function matchOrders(uint256 cycleId) external {}

  function liquidate(uint256 orderId, address trader) external {}

  function settle(uint256 cycleId) external {}

  function updateFees(uint16 makerFee, uint16 takerFee) external onlyOwner {}

  // ################## Internal bit manipulation helpers ##################
  // Convert tick, isPut, isBid to key
  function _key(uint32 tick, bool isPut, bool isBid) private pure returns (uint32) {
    return (isPut ? 1 << 31 : 0) | (isBid ? 1 << 30 : 0) | tick;
  }

  // Convert key to tick, isPut, isBid
  function _splitKey(uint32 key) private pure returns (uint32 tick, bool isPut, bool isBid) {
    isPut = (key & (1 << 31)) != 0;
    isBid = (key & (1 << 30)) != 0;
    tick = key & 0x3FFF_FFFF;
  }

  // Returns which of the 4 orderbook sides to use
  function _maps(bool isBid, bool isPut)
    private
    view
    returns (uint256 summary, mapping(uint8 => uint256) storage mid, mapping(uint16 => uint256) storage det)
  {
    if (isBid) {
      if (isPut) {
        summary = summaryPB;
        mid = midPB;
        det = detPB;
      } else {
        summary = summaryCB;
        mid = midCB;
        det = detCB;
      }
    } else {
      // asks
      if (isPut) {
        summary = summaryPA;
        mid = midPA;
        det = detPA;
      } else {
        summary = summaryCA;
        mid = midCA;
        det = detCA;
      }
    }
  }

  /**
   * @notice Add bits to the orderbook on mid and detail level, and return bool to indicate if caller must set the
   * summary bit for l1.
   * @dev  Mark tick (l1,l2,l3) as non-empty.
   *       Returns true  -> caller must set the summary bit for l1.
   *       Returns false -> No change needed to summary bit.
   *
   * ticks are defined as [uint8, uint8, uint8] from the rightmost 24 bits of the tickKey:
   *
   * [1bit, 1bit, 6bits, 8bits, 8bits, 8bits]
   * [isPut, isBid, unused, l1, l2, l3]
   *
   * where l1, l2, l3 are summary, mid, and detail bit index respectively.
   */
  function _addBits(
    mapping(uint16 => uint256) storage det, // detail  (L3)  bitmap
    mapping(uint8 => uint256) storage mid, // mid     (L2)  bitmap
    uint8 l1, // high    byte
    uint8 l2, // middle  byte
    uint8 l3 // low     byte
  ) internal returns (bool firstInL1) {
    uint16 detKey = (uint16(l1) << 8) | l2; // Word key for det[] mapping
    uint256 m3 = BitScan.mask(l3); // Isolate bit l3

    // If this is the very first order at (l1,l2,l3) …
    if (det[detKey] & m3 == 0) {
      det[detKey] |= m3; // Flip the detail bit

      uint256 m2 = BitScan.mask(l2); // Bit mask for mid bitmap
      // If this tick is the first in its 256-tick block
      if (mid[l1] & m2 == 0) {
        mid[l1] |= m2; // Set the mid-level bit
        return true; // Caller must set summary bit for l1
      }
    }
    return false;
  }

  /**
   * @dev  Clear bits on mid and detail level, and return bool to indicate if caller must clear the summary bit for l1.
   *       Returns true  -> caller must clear summary bit for l1.
   *       Returns false -> summary still has other blocks.
   */
  function _clrBits(
    mapping(uint16 => uint256) storage det,
    mapping(uint8 => uint256) storage mid,
    uint8 l1,
    uint8 l2,
    uint8 l3
  ) internal returns (bool lastInL1) {
    uint16 detKey = (uint16(l1) << 8) | l2; // Locate detail word
    det[detKey] &= ~BitScan.mask(l3); // Clear bit l3

    // If no ticks left in this 256-tick word
    if (det[detKey] == 0) {
      mid[l1] &= ~BitScan.mask(l2); // Clear mid-level bit
      // If no 256-tick words left in this 65 k-tick block
      if (mid[l1] == 0) return true; // Caller must clear summary bit
    }
    return false;
  }

  // Returns the best tick and key for the given side and option type
  function _best(bool isBid, bool isPut) private view returns (uint32 tick, uint32 key) {
    (uint256 summary, mapping(uint8 => uint256) storage mid, mapping(uint16 => uint256) storage det) =
      _maps(isBid, isPut);

    uint8 l1 = isBid ? summary.msb() : summary.lsb();
    uint8 l2 = isBid ? mid[l1].msb() : mid[l1].lsb();
    uint16 k12 = (uint16(l1) << 8) | l2;
    uint8 l3 = isBid ? det[k12].msb() : det[k12].lsb();

    tick = BitScan.join(l1, l2, l3);
    key = _key(tick, isPut, isBid);
  }

  // ################## Internal orderbook helpers ##################
  function _insertLimit(bool isBuy, bool isPut, uint32 tick, uint128 size) private returns (uint16 nodeId) {
    // pick the right bitmap ladders
    (uint256 summary, mapping(uint8 => uint256) storage mid, mapping(uint16 => uint256) storage det) =
      _maps(isBuy, isPut);

    // derive level bytes and key
    (uint8 l1, uint8 l2, uint8 l3) = BitScan.split(tick);
    uint32 key = _key(tick, isPut, isBuy);

    // if level empty, set bitmap bits
    if (levels[key].vol == 0) {
      bool firstInL1 = _addBits(det, mid, l1, l2, l3);
      if (firstInL1) summary |= BitScan.mask(l1);
    }

    // maker node
    nodeId = ++nodePtr;
    makerQ[nodeId] = Maker(msg.sender, size, 0, key, levels[key].tail);

    // FIFO queue link
    if (levels[key].vol == 0) levels[key].head = nodeId;
    else makerQ[levels[key].tail].next = nodeId;
    levels[key].tail = nodeId;
    levels[key].vol += size;

    // position table
    if (!inList[msg.sender]) {
      inList[msg.sender] = true;
      traders.push(msg.sender);
    }
    Pos storage P = positions[activeCycle | uint256(uint160(msg.sender))]; // key by cycle+trader

    if (isPut) isBuy ? P.longPuts += uint96(size) : P.shortPuts += uint96(size);
    else isBuy ? P.longCalls += uint96(size) : P.shortCalls += uint96(size);
  }

  function _marketOrder(bool isBuy, bool isPut, uint128 size) private {
    // TODO: Implement market order logic
  }

  function pause() external override onlyOwner {
    _pause();
  }

  function unpause() external override onlyOwner {
    _unpause();
  }

  /**
   * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract.
   * Called by
   * {upgradeTo} and {upgradeToAndCall}.
   * @param newImplementation Address of the new implementation contract
   */
  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
