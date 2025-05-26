// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOptionsEngine, OptionType, Side} from "./interfaces/IOptionsEngine.sol";

contract OptionsEngine is IOptionsEngine {
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

  string public name;
  uint256 public activeMarket;

  address public immutable priceOracle;
  IERC20  public immutable collateralToken;

  mapping(uint256 => mapping(uint256 => Order))   public orders;
  mapping(uint256 => Market)                      public markets;
  mapping(address => uint256)                     public balances;
  mapping(uint256 => mapping(address => uint256)) public lockedCollateral;

  constructor(
    string memory _name,
    address _oracleFeed,
    address _collateralToken
  ) {
    name = _name;
    priceOracle = _oracleFeed;
    collateralToken = IERC20(_collateralToken);
  }
  
  function startMarket(uint256 _strike) external {

  }
  
  function depositCollateral(uint256 amount) external {
    
  }
  
  function withdrawCollateral(uint256 amount) external {
    
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
  
  function updateFees(uint16 makerFee, uint16 takerFee) external {
    
  }

  function pause() external {
    
  }

  function unpause() external {
    
  }
}
