// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Utils} from "../lib/Utils.sol";
import {Create3} from "@create3/contracts/Create3.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title Deployer
 * @dev Contract for deploying BondToken and LeverageToken instances
 */
contract Deployer {
  bytes32 public salt;

  constructor() {
  }

  function deploy(address implementation, bytes memory initialize) internal returns (address) {
    ERC1967Proxy proxy = new ERC1967Proxy(implementation, initialize);

    return address(proxy);
  }

  function deployBondToken(
    address bondBeacon,
    string memory name,
    string memory symbol,
    address minter,
    address governance,
    address,
    uint256 sharesPerToken
  ) external onlyPoolFactory returns (address) {
    bytes memory initData =
      abi.encodeCall(BondToken.initialize, (name, symbol, minter, governance, address(poolFactory), sharesPerToken));

    address addr =
      Create3.create3(bondSalt, abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(bondBeacon, initData)));

    bondSalt = bytes32(uint256(uint256(bondSalt) + 1)); // Increment salt for next deployment

    return addr;
  }

  function setSalts(bytes32 _bondSalt, bytes32 _leverageSalt, bytes32 _distributorSalt) external onlySecurityCouncil {
    bondSalt = _bondSalt;
    leverageSalt = _leverageSalt;
    distributorSalt = _distributorSalt;
  }

  function computeAddress(bytes32 salt) external view returns (address) {
    return Create3.addressOf(salt);
  }
}
