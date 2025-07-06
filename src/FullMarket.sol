// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Market} from "./Market.sol";
import {MarketExtension} from "./MarketExtension.sol";

contract FullMarket is Market, MarketExtension {}
