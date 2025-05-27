// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOptionsEngine, OptionType, Side} from "./interfaces/IOptionsEngine.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

struct Market {
  bool active;
  bool isSettled;
  uint256 strike;
  uint256 fee;
}

struct Order {
  uint256 marketId;
  address trader;
  OptionType option;
  Side side;
  uint256 size;
  uint256 limitPrice; // 0 = MARKET ORDER
  uint256 lockedCollateral;
  uint256 timestamp;
}

contract OptionsEngine is IOptionsEngine, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable {

  string public name;
  uint256 public activeMarket;

  address public priceOracle;
  IERC20  public collateralToken;

  mapping(uint256 => mapping(uint256 => Order))   public orders;
  mapping(uint256 => Market)                      public markets;
  mapping(address => uint256)                     public balances;
  mapping(uint256 => mapping(address => uint256)) public lockedCollateral;

  event MarketStarted(uint256 expiry, uint256 strike);
  event MarketSettled(uint256 marketId);

  event CollateralDeposited(address trader, uint256 amount);
  event CollateralWithdrawn(address trader, uint256 amount);

  event OrderPlaced(
    uint256 marketId,
    uint256 orderId,
    address trader,
    uint256 size,
    uint256 limitPrice
  );

  event Liquidated(
    uint256 marketId,
    uint256 orderId,
    address trader,
    uint256 collateral,
    bool completed // <- was collateral enough? yes/no
  );

  // Less gas efficient, easier to debug
  string constant INVALID_ORACLE_PRICE = "0";
  string constant MARKET_ALREADY_STARTED = "1";
  string constant PREVIOUS_MARKET_NOT_SETTLED = "2";
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
  
  function startMarket(uint256 expiry) external onlyOwner {
    if (activeMarket != 0) {
      // If there is an active market, it must be in the past
      require(activeMarket < block.timestamp, MARKET_ALREADY_STARTED);

      // The previous market must be settled
      require(markets[activeMarket].isSettled, PREVIOUS_MARKET_NOT_SETTLED);
    }

    //(, int256 price, , , ) = AggregatorV3Interface(priceOracle).latestRoundData();
    int256 price = 1;
    require(price > 0, INVALID_ORACLE_PRICE);
    
    // Create new market
    markets[expiry] = Market({
      active: true,
      isSettled: false,
      strike: uint256(price),
      fee: 0 // @TODO: add fees
    });
    
    // Set as current market
    activeMarket = expiry;
    
    emit MarketStarted(expiry, uint256(price));
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
    uint256 balance = balances[trader] - lockedCollateral[activeMarket][trader];

    require(balance >= amount, INSUFFICIENT_BALANCE);
    
    // Update user's balance
    balances[trader] -= amount;
    
    // Transfer collateral token from contract to user
    collateralToken.transfer(trader, amount);
    
    emit CollateralWithdrawn(trader, amount);
  }
  
  function placeOrder(
    uint256 marketId,
    OptionType option,
    Side side,
    uint256 size,
    uint256 limitPrice
  ) external returns (uint256 orderId) {
    
  }
  
  function cancelOrder(uint256 marketId, uint256 orderId) external {
    
  }
  
  function matchOrders(uint256 marketId) external {
    
  }
  
  function liquidate(uint256 orderId, address trader) external {
    
  }
  
  function settle(uint256 marketId) external {
    
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
