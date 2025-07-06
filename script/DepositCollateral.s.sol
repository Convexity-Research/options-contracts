// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Market} from "../src/Market.sol";
import {MarketExtension} from "../src/MarketExtension.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC20Mintable is IERC20 {
  function mint(address to, uint256 amount) external;
}

contract DepositCollateral is Script {
  Market mkt = Market(0xEaCCc2025Ee34Be0b6F1F8c8B18f074a1568335C);

  function run() external {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
    address wallet = vm.addr(vm.envUint("PRIVATE_KEY"));
    console.log("Deploying with account:", wallet);
    console.log("Account balance:", wallet.balance);

    console.log(MarketExtension(address(mkt)).getCollateralToken());
    IERC20Mintable token = IERC20Mintable(MarketExtension(address(mkt)).getCollateralToken());
    token.mint(wallet, 1000000 ether);
    console.log(token.balanceOf(wallet));

    token.approve(address(mkt), 5000 ether);

    uint256 balance;

    balance = MarketExtension(address(mkt)).getUserAccounts(wallet).balance;
    console.log("balance", balance);

    mkt.depositCollateral(5000 * 1e6);

    balance = MarketExtension(address(mkt)).getUserAccounts(wallet).balance;
    console.log("balance", balance);

    vm.stopBroadcast();
  }
}
