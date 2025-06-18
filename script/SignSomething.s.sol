// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Market} from "../src/Market.sol";
import {Token} from "../test/mocks/Token.sol";

contract SignSomething is Script {
  address public constant ADMIN = 0xE7Bc1Ed115b368B946d97e45eE79f47a14eBF179;

  // address usdt0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
  address usdt0 = 0xAA480C5F5EB436D0645189Ca20E5AdE13aecAf27;
  address forwarder = 0x44122Dd43cF39Fb47853dBd2232D63B4C9eb5B7E;
  address whitelistSigner = 0xf059b24cE0C34D44fb271dDC795a7C0E71576fd2;
  address market = 0xE57425afC7662E8D151F5249A8E621e167BBE6aB;

  function run() external {
    vm.createSelectFork("hyperevm");
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

    uint256 signerKey = 1;

    IERC20(usdt0).approve(market, type(uint256).max);
    Token(usdt0).mint(0x1FaE1550229fE09ef3e266d8559acdcFC154e72f, 50000000 * 1e6);

    bytes32 hash = keccak256(abi.encodePacked(0xE7Bc1Ed115b368B946d97e45eE79f47a14eBF179));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, hash);
    bytes memory signature = abi.encodePacked(r, s, v);

    console.logBytes(signature);

    _mockOracle(105000);

    Market(market).depositCollateral(50000000 * 1e6);
    // Market(market).startCycle(1749898567);
    Market(market).long(1, 1749898567);
  }

  function _mockOracle(uint256 price) internal {
    vm.mockCall(
      address(0x0000000000000000000000000000000000000807),
      abi.encodeWithSelector(0x00000000),
      abi.encode(price * 10) // Oracle and Mark price feeds return with 1 decimal when reading L1 from HyperEVM
    );
  }
}
