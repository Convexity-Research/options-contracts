// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarket} from "../src/interfaces/IMarket.sol";
import {IMulticall3} from "forge-std/interfaces/IMulticall3.sol";

struct UserAccount {
  bool activeInCycle;
  bool liquidationQueued;
  uint64 balance;
  uint64 liquidationFeeOwed;
  uint64 scratchPnL;
  uint48 _gap;
  uint32 longCalls;
  uint32 shortCalls;
  uint32 longPuts;
  uint32 shortPuts;
  uint32 pendingLongCalls;
  uint32 pendingShortCalls;
  uint32 pendingLongPuts;
  uint32 pendingShortPuts;
}

interface IMarketBalances {
  function userAccounts(address user) external view returns (UserAccount memory);
}

contract CheckBalances is Script {
  address constant MARKET = 0xB7C609cFfa0e47DB2467ea03fF3e598bF59361A5;
  address constant USDT = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
  address constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;

  function getUsers() internal pure returns (address[] memory users) {
    string[122] memory userStrings = [
      "0x69835D480110e4919B7899f465aAB101e21c8A87",
      "0x909Fa4b53a7ec466af9f0F1f9732f8Cd7509E574",
      "0xd786BF9c23C5aeFbaEa5675D071680E0e8d15Bff",
      "0xE7Bc1Ed115b368B946d97e45eE79f47a14eBF179",
      "0x5dbAb2D4a3aea73CD6c6C2494A062E07a630430f",
      "0xc0b65553916fF90b08fC7C2AE91FaA59b5A82D8D",
      "0x316778512b7a2ea2e923A99F4E7257C837a7123b",
      "0xFF257777c3b297678F7b57e0896f4DeCBad6982A",
      "0xD823FEe380EC1755902b35E69C1C3438C5F31a17",
      "0xdE0AEf70a7ae324045B7722C903aaaec2ac175F5",
      "0xFeeBf441AE17E39D4bD0c402dE3a682E54c1982d",
      "0x9730299b10A30bDbAF81815c99b4657c685314AB",
      "0x97626B6283eBDD883b320600d2a4e2C295231B52",
      "0x43C51aB4A1890196E54ec75247e998D1c0BEbEA8",
      "0xd791427e372186E90637caF1D6D6AFb054BeeC7A",
      "0x0B5943294f11599e2BD0728659D1cDD69704E0EC",
      "0xC175AD6c4748CB9aE23Fc4230F2Bc45ab41A4612",
      "0xaEb82911B72a3BaABa841dC52A1F675c1b51Afcf",
      "0x6A8a351B81833A2A04818dE3bb4b36D38ceC90b5",
      "0xCB11673592cC6C4B9584F33BBBA6C6cF07Dde3f7",
      "0x9ae70bBaFfbfA07A5a67B7B02f05Addf033b0B55",
      "0x114925652cCF16d7CbDE86691f207064028F8357",
      "0x22FD0A67109B1db617848bcf438fD9EC021Dfc0c",
      "0xa5A8f13e256C458c8df724fEd24Fe75c9A465835",
      "0x6F413B49673d2f918cdE926256AB1b7191a87287",
      "0xFD7584cd3C267399477151A494F3fDa43141d5bd",
      "0xa464aBBf049fb75585484ADDcbC00169062e813A",
      "0xBAfa7E191E3109bd0d779f1cB88AAa27ffCc9B3d",
      "0xAee33D473C68f9B4946020d79021416ff0587005",
      "0x9C330a97c3DD093F4b514aF6CC2f531AC0Cb084b",
      "0xE3F85D418be7dc940Bf067a8D612B5dABEb4D8A7",
      "0x4FE21E0beFaE8259a06b00d66086ED9F391bB702",
      "0x9c77d05F945ae4127905F55a0ff8341A203dE331",
      "0x567B5a45DC20CfF3629C3b476DdAdb8fb47DC57E",
      "0xcE3396aA582cE20a9E439de4c48C85598c5cA98F",
      "0xE421342e6D39a1F552b0Cc41c912D04aea96C2Bc",
      "0xe1160E853acb8CaC0bbeDE5c594015C28aE4e43f",
      "0xFC4644b26895482Ff1409b6C9854825a55510691",
      "0xe0CcD622E1AF719070Bf76377d1135A96cbA5ee7",
      "0x5130AdB61e4Da07B0b84c0983369663f49ea78C3",
      "0xA8E25753CBddbD926c900C2157780E468335d232",
      "0xB6290348c15f6812348E27A9c5a4D435F5Fc952C",
      "0x15C39E1e6843B01eBC30c491395209a618D314CD",
      "0x2d76fC50442255D4b5D656B99b3061484abF4B72",
      "0xB8d3eAE0Abe8895255e6863ba655A5bACCAE5F78",
      "0xde7D4ca820d141d655420D959AfFa3920bb1E07A",
      "0xb18e8f19003974064ecAb2bAca5fe721f284830F",
      "0x7E3b6f966f3666F77813db84DD352173749D24d8",
      "0x8b0473E5f2871d420b7891c01a45eF84eE2d523D",
      "0x7B27Ce044978A2F64E1956b24AC9C9e3A26A9fF3",
      "0xf2E7156AeA602b4670e78b1903933d729194Fc68",
      "0xEFC05bF6F5e00b826A1917379cF5800988D57B19",
      "0x562F6ac10723ef6AF9F077A83cF25135FB369612",
      "0xafF0605798931f266816Befc5f39E23ebd798769",
      "0x5Cb58BfA6916c501cD3D0839Df2318A6e288d05f",
      "0x073319db47b8273656461498CB1dB95bd8df4414",
      "0x072e382e590Ed992953F2746fc281Ae6e0d9232b",
      "0xC5f1C489cfcA582c0D47Fa2C036F84833E8aB700",
      "0x48002082CDa92A7e3B87d022C95228f1Df8598Af",
      "0xC35e63E55821052678A727Ca92610F428CD11efa",
      "0xa6FEbC99f12558e4a531a509e3Ed0a6Fc1078CE9",
      "0x3FFbCe2E9C7aA0013D2015dE33A12908DA30975b",
      "0x5DE6Cd48EAf279b2b9F2E5E3B55464C208699F87",
      "0x1000c6F2b40cBa13B661C3C20Eb7b9bCDeAd8581",
      "0x61fb776AaD0B574f7783F26f0f9EEdC53cFDc3f5",
      "0x5A73C07b0d0c04396ae93D2f23c020C2401dEDd5",
      "0xB46828C7D13D0e60F509cB22Df35eB6aB0cAc3df",
      "0x5F24aF124116DeFCf69936123C5683723ccc9dE9",
      "0xf1f5D35c46Fd62fDD9150C39acc4A1b6A8327Ae4",
      "0xA394AC5FAB69542A9F2c8e291c4770078aa12D0a",
      "0x8626F4cBB8a16F1E0A5e680B7c8125B18e088d14",
      "0x4cDd92b93e3dF7eA482982DE2D15688666f99827",
      "0x38df5EaB959095F4589686f4D725c7d0a7ba8F75",
      "0x881A5129D13a77e0Cb2D93c688F4Fb282f8dF66C",
      "0x352F82211583f051F27f020b131f5ECAdA42dCF7",
      "0x7a7cC83fe52d1d88C59865f122c89e2b1ECa2A64",
      "0xAEAd9E9190f27b757E798eD256e3193C4fB381e1",
      "0x8Eb0603d8fa0FE67Fe0fe02E367d95584E21d2a3",
      "0x2Af5fB9Ac5aBb3B157690Ae3b6EfE4609dEae421",
      "0x8b4218bc20285160189EBcFe9669937667dCadAF",
      "0x38A9520018D6D6b5EBcf310698A091eFb08DF1CD",
      "0xFCaeb69e6bA01092015fC2207048D42cAc46892A",
      "0xC46200731b2a56b423f818C53f66025ef5ec6d7a",
      "0xFfB326e46c4d171eA4C613C84Fe35B2FeE8112A5",
      "0xf6f5314f82A766AD71098fB3B8dE0C74454C7521",
      "0xA0d36A1B10abc9a6A23C36052AF8C2A708C33F36",
      "0x70A9e17FE82446a8144647899A597db851f9d64F",
      "0x2bb6d51491d3353e73465BcEC04D86234E5e57e3",
      "0x2a5b1ac8056B01751d2D413ab24FA1589F700e87",
      "0xf04Fd8595b52f530a775C5AefCA7a7c7afd00Aa8",
      "0x86d3ee9ff0983Bc33b93cc8983371a500f873446",
      "0x795DE8E4E6c3DB1b42ea658c42332CCB5927bAe8",
      "0xB95619317834Aea741A3cE3ee59aC7D621f989A4",
      "0x6B73dA988210e7b5f9c024434626F9F463964e74",
      "0xaD1fB851e54C55D65D8CEfE65f9E4c64A83650fd",
      "0x2513eA64C45675674F62bb141E65c7C8Fc913Ff4",
      "0x565b3b224f9F83573ca560b51cD772171380f826",
      "0xb67E55884096f203A423C80fe6F6b1c1Bd791782",
      "0xfa83B0FcA3568E12061b7F9109175de63f506Dcc",
      "0xa567027C7a7a5f3b2E2e58De823CEF0c3d5e1E1F",
      "0xF30743d463387293266006B188beA69e247265f8",
      "0x41ea7e9113Bc00D3f7cE54130eB2F6d152BF91fd",
      "0xc276F3f25979d0724BeC3f745c340ac4b8640c5a",
      "0xCC6454d3B32592f6960CC5E1989B7e4000c4b86d",
      "0x3E54b700D4A3E525E49CA5D4A8Fb4282Bd3Be70F",
      "0xAC6cd231C22919a9d0FC2B619e73134C380Ca0FF",
      "0x699DDC98aD9ff8b3b86C1d9ed2615A531B388bda",
      "0xA5C2afefEDaA04B9CBb2d946336C84798baDF16F",
      "0xf0199bE4eB1e56DF218a6e87D52687d8ac892bFc",
      "0x001383F1723a205d760E57A21082D3eC85c89D81",
      "0xb4cE0c954bB129D8039230F701bb6503dca1Ee8c",
      "0x1E6a29e9c42839e982a68DD6E42d465BA99323ff",
      "0x535A658600AEaA7E15d537f49BD5Cebb376708e5",
      "0x4efd3CcFb7a1DE70e1B9553CD96f9579dAD10Ba3",
      "0x109CbDCf9e4F6Cb9EA56c810bc26F06f8b1F399F",
      "0x77D779e9AF430f223980c22335A1ddE00ebFE155",
      "0x07A7fD7e12c626d1D1b4eb798E21A29455ED9E8b",
      "0x0646Fa00dd8F8D7166b6D58f741F656DB0E78444",
      "0x9599996689368989f787e3537FE565823c9F32F3",
      "0xE24dA1C8f33E1Dd8B7993B8b028C7109698DdAa5",
      "0x8438E4095783EBef8C951788AD42c3BcD084FB41",
      "0x17f8dec583Ab9af5De05FBBb4d4C2bfE767A0AC3"
    ];

    users = new address[](userStrings.length);
    for (uint256 i = 0; i < userStrings.length; i++) {
      users[i] = vm.parseAddress(userStrings[i]);
    }

    return users;
  }

  function run() external {
    console.log("=== Balance Check Report ===");
    console.log("Market Address:", MARKET);
    console.log("USDT Address:", USDT);
    console.log("Using Multicall3 for efficient batch calls");
    console.log("");

    IERC20 usdt = IERC20(USDT);
    IMulticall3 multicall = IMulticall3(MULTICALL3);

    uint256 totalUserBalance = 0;
    uint256 usersWithBalance = 0;

    address[] memory users = getUsers();

    console.log("Fetching all user balances via multicall3...");

    // Prepare multicall3 calls
    IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](users.length);
    for (uint256 i = 0; i < users.length; i++) {
      calls[i] = IMulticall3.Call3({
        target: MARKET,
        allowFailure: false,
        callData: abi.encodeWithSelector(IMarketBalances.userAccounts.selector, users[i])
      });
    }

    // Execute multicall3
    IMulticall3.Result[] memory results = multicall.aggregate3(calls);

    console.log("Processing individual user balances...");
    console.log("");

    for (uint256 i = 0; i < users.length; i++) {
      address user = users[i];
      if (user == address(0x001383F1723a205d760E57A21082D3eC85c89D81)) continue; // skip attacker

      require(results[i].success, "Failed to get user account data");
      UserAccount memory account = abi.decode(results[i].returnData, (UserAccount));
      uint256 balance = uint256(account.balance);

      if (balance > 0) usersWithBalance++;

      totalUserBalance += balance;
    }

    // Get USDT balance of market contract
    uint256 marketUsdtBalance = usdt.balanceOf(MARKET);

    console.log("=== SUMMARY ===");
    console.log("Total users checked:", users.length);
    console.log("Users with balance > 0:", usersWithBalance);
    console.log("Total user balances sum:", totalUserBalance);
    console.log("Market USDT balance:", marketUsdtBalance);
    console.log("");

    if (totalUserBalance > marketUsdtBalance) {
      console.log("WARNING: User balances exceed market USDT balance!");
      console.log("Shortfall:", totalUserBalance - marketUsdtBalance);
    } else if (marketUsdtBalance > totalUserBalance) {
      console.log("Market has excess USDT over user balances");
      console.log("Excess:", marketUsdtBalance - totalUserBalance);
    } else {
      console.log("User balances match market USDT balance exactly");
    }
  }
}
