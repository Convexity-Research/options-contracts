// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Create3} from "@create3/contracts/Create3.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Market} from "./Market.sol";


contract Deployer is Ownable {
  constructor() Ownable(msg.sender) {
  }

  function _deploy(bytes32 salt, address implementation, bytes memory initialize) internal returns (address) {
    return Create3.create3(salt, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initialize)));
  }

  function deployMarket(
    string memory name,
    address feeRecipient,
    address usdt0,
    address forwarder,
    address implementation,
    bytes32 salt
  ) external onlyOwner returns (address) {
    bytes memory initialize = abi.encodeWithSelector(Market.initialize.selector, name, feeRecipient, usdt0, forwarder);

    address proxy = _deploy(salt, implementation, initialize);
    return proxy;
  }

  function computeAddress(bytes32 _salt) external view returns (address) {
    return Create3.addressOf(_salt);
  }
}
