// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarket, OptionType, Side} from "./interfaces/IMarket.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

struct Cycle {
  bool active;
  bool isSettled;
  uint256 strike;
  uint256 fee;
}

struct Order {
  uint256 cycleId;
  address trader;
  OptionType option;
  Side side;
  uint256 size;
  uint256 limitPrice; // 0 = MARKET ORDER
  uint256 lockedCollateral;
  uint256 timestamp;
}

contract Market is IMarket, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable {

  string public name;
  uint256 public activeCycle;

  address public priceOracle;
  IERC20  public collateralToken;

  mapping(uint256 => mapping(uint256 => Order))   public orders;
  mapping(uint256 => Cycle)                      public cycles;
  mapping(address => uint256)                     public balances;
  mapping(uint256 => mapping(address => uint256)) public lockedCollateral;

  event CycleStarted(uint256 expiry, uint256 strike);
  event CycleSettled(uint256 cycleId);

  event CollateralDeposited(address trader, uint256 amount);
  event CollateralWithdrawn(address trader, uint256 amount);

  event OrderPlaced(
    uint256 cycleId,
    uint256 orderId,
    address trader,
    uint256 size,
    uint256 limitPrice
  );

  event Liquidated(
    uint256 cycleId,
    uint256 orderId,
    address trader,
    uint256 collateral,
    bool completed // <- was collateral enough? yes/no
  );

  // Less gas efficient, easier to debug
  string constant INVALID_ORACLE_PRICE = "0";
  string constant CYCLE_ALREADY_STARTED = "1";
  string constant PREVIOUS_CYCLE_NOT_SETTLED = "2";
  string constant INVALID_AMOUNT = "3";
  string constant INSUFFICIENT_BALANCE = "4";

  constructor() {
    _disableInitializers();
  }

  function initialize(
    string memory _name,
    address _oracleFeed,
    address _collateralToken
  ) external initializer {
    __Ownable_init(_msgSender());
    __Pausable_init();
    __UUPSUpgradeable_init();

    name = _name;
    priceOracle = _oracleFeed;
    collateralToken = IERC20(_collateralToken);
  }
  
  function startCycle(uint256 expiry) external onlyOwner {
    if (activeCycle != 0) {
      // If there is an active cycle, it must be in the past
      require(activeCycle < block.timestamp, CYCLE_ALREADY_STARTED);

      // The previous cycle must be settled
      require(cycles[activeCycle].isSettled, PREVIOUS_CYCLE_NOT_SETTLED);
    }

    //(, int256 price, , , ) = AggregatorV3Interface(priceOracle).latestRoundData();
    int256 price = 1;
    require(price > 0, INVALID_ORACLE_PRICE);
    
    // Create new market
    cycles[expiry] = Cycle({
      active: true,
      isSettled: false,
      strike: uint256(price),
      fee: 0 // @TODO: add fees
    });
    
    // Set as current market
    activeCycle = expiry;
    
    emit CycleStarted(expiry, uint256(price));
  }
  
  function depositCollateral(uint256 amount) external {
    require(amount > 0, INVALID_AMOUNT);

    address trader = _msgSender();
    
    // Transfer collateral token from user to contract
    collateralToken.transferFrom(trader, address(this), amount);

    // Update user's balance
    balances[trader] += amount;

    emit CollateralDeposited(trader, amount);
  }
  
  function withdrawCollateral(uint256 amount) external {
    require(amount > 0, INVALID_AMOUNT);

    address trader = _msgSender();
    uint256 balance = balances[trader] - lockedCollateral[activeCycle][trader];

    require(balance >= amount, INSUFFICIENT_BALANCE);
    
    // Update user's balance
    balances[trader] -= amount;
    
    // Transfer collateral token from contract to user
    collateralToken.transfer(trader, amount);
    
    emit CollateralWithdrawn(trader, amount);
  }
  
  function placeOrder(
    uint256 cycleId,
    OptionType option,
    Side side,
    uint256 size,
    uint256 limitPrice
  ) external returns (uint256 orderId) {
    
  }
  
  function cancelOrder(uint256 cycleId, uint256 orderId) external {
    
  }
  
  function matchOrders(uint256 cycleId) external {
    
  }
  
  function liquidate(uint256 orderId, address trader) external {
    
  }
  
  function settle(uint256 cycleId) external {
    
  }
  
  function updateFees(uint16 makerFee, uint16 takerFee) external onlyOwner {
    
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
