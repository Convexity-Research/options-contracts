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
    string[153] memory userStrings = [
      "0x4fe21e0befae8259a06b00d66086ed9f391bb702",
      "0xb18e8f19003974064ecab2baca5fe721f284830f",
      "0xfc4644b26895482ff1409b6c9854825a55510691",
      "0xaff0605798931f266816befc5f39e23ebd798769",
      "0x562f6ac10723ef6af9f077a83cf25135fb369612",
      "0x69835d480110e4919b7899f465aab101e21c8a87",
      "0xbafa7e191e3109bd0d779f1cb88aaa27ffcc9b3d",
      "0xb8d3eae0abe8895255e6863ba655a5baccae5f78",
      "0xfeebf441ae17e39d4bd0c402de3a682e54c1982d",
      "0x9c330a97c3dd093f4b514af6cc2f531ac0cb084b",
      "0x5cb58bfa6916c501cd3d0839df2318a6e288d05f",
      "0xe0ccd622e1af719070bf76377d1135a96cba5ee7",
      "0xe1160e853acb8cac0bbede5c594015c28ae4e43f",
      "0xa8e25753cbddbd926c900c2157780e468335d232",
      "0x22fd0a67109b1db617848bcf438fd9ec021dfc0c",
      "0xe3f85d418be7dc940bf067a8d612b5dabeb4d8a7",
      "0xce3396aa582ce20a9e439de4c48c85598c5ca98f",
      "0xde0aef70a7ae324045b7722c903aaaec2ac175f5",
      "0x073319db47b8273656461498cb1db95bd8df4414",
      "0x9c77d05f945ae4127905f55a0ff8341a203de331",
      "0xa464abbf049fb75585484addcbc00169062e813a",
      "0xefc05bf6f5e00b826a1917379cf5800988d57b19",
      "0xaeb82911b72a3baaba841dc52a1f675c1b51afcf",
      "0x6a8a351b81833a2a04818de3bb4b36d38cec90b5",
      "0x114925652ccf16d7cbde86691f207064028f8357",
      "0x5130adb61e4da07b0b84c0983369663f49ea78c3",
      "0xd823fee380ec1755902b35e69c1c3438c5f31a17",
      "0x9ae70bbaffbfa07a5a67b7b02f05addf033b0b55",
      "0x7b27ce044978a2f64e1956b24ac9c9e3a26a9ff3",
      "0x567b5a45dc20cff3629c3b476ddadb8fb47dc57e",
      "0xaee33d473c68f9b4946020d79021416ff0587005",
      "0x0b5943294f11599e2bd0728659d1cdd69704e0ec",
      "0x43c51ab4a1890196e54ec75247e998d1c0bebea8",
      "0xc175ad6c4748cb9ae23fc4230f2bc45ab41a4612",
      "0xfd7584cd3c267399477151a494f3fda43141d5bd",
      "0xe421342e6d39a1f552b0cc41c912d04aea96c2bc",
      "0x5dbab2d4a3aea73cd6c6c2494a062e07a630430f",
      "0xd791427e372186e90637caf1d6d6afb054beec7a",
      "0x6f413b49673d2f918cde926256ab1b7191a87287",
      "0x2d76fc50442255d4b5d656b99b3061484abf4b72",
      "0x7e3b6f966f3666f77813db84dd352173749d24d8",
      "0xe7bc1ed115b368b946d97e45ee79f47a14ebf179",
      "0x316778512b7a2ea2e923a99f4e7257c837a7123b",
      "0x9730299b10a30bdbaf81815c99b4657c685314ab",
      "0xde7d4ca820d141d655420d959affa3920bb1e07a",
      "0x97626b6283ebdd883b320600d2a4e2c295231b52",
      "0xb6290348c15f6812348e27a9c5a4d435f5fc952c",
      "0x15c39e1e6843b01ebc30c491395209a618d314cd",
      "0xc0b65553916ff90b08fc7c2ae91faa59b5a82d8d",
      "0x8b0473e5f2871d420b7891c01a45ef84ee2d523d",
      "0xcb11673592cc6c4b9584f33bbba6c6cf07dde3f7",
      "0xa5a8f13e256c458c8df724fed24fe75c9a465835",
      "0xff257777c3b297678f7b57e0896f4decbad6982a",
      "0x8b4218bc20285160189ebcfe9669937667dcadaf",
      "0xad1fb851e54c55d65d8cefe65f9e4c64a83650fd",
      "0x5de6cd48eaf279b2b9f2e5e3b55464c208699f87",
      "0xaead9e9190f27b757e798ed256e3193c4fb381e1",
      "0x38a9520018d6d6b5ebcf310698a091efb08df1cd",
      "0x3ffbce2e9c7aa0013d2015de33a12908da30975b",
      "0xa0d36a1b10abc9a6a23c36052af8c2a708c33f36",
      "0x2af5fb9ac5abb3b157690ae3b6efe4609deae421",
      "0xfcaeb69e6ba01092015fc2207048d42cac46892a",
      "0x86d3ee9ff0983bc33b93cc8983371a500f873446",
      "0xfa83b0fca3568e12061b7f9109175de63f506dcc",
      "0xf6f5314f82a766ad71098fb3b8de0c74454c7521",
      "0xffb326e46c4d171ea4c613c84fe35b2fee8112a5",
      "0x1000c6f2b40cba13b661c3c20eb7b9bcdead8581",
      "0xf30743d463387293266006b188bea69e247265f8",
      "0x4cdd92b93e3df7ea482982de2d15688666f99827",
      "0x2bb6d51491d3353e73465bcec04d86234e5e57e3",
      "0x5a73c07b0d0c04396ae93d2f23c020c2401dedd5",
      "0x1e6a29e9c42839e982a68dd6e42d465ba99323ff",
      "0xb4ce0c954bb129d8039230f701bb6503dca1ee8c",
      "0x5f24af124116defcf69936123c5683723ccc9de9",
      "0x2513ea64c45675674f62bb141e65c7c8fc913ff4",
      "0x6b73da988210e7b5f9c024434626f9f463964e74",
      "0x2a5b1ac8056b01751d2d413ab24fa1589f700e87",
      "0x38df5eab959095f4589686f4d725c7d0a7ba8f75",
      "0xa6febc99f12558e4a531a509e3ed0a6fc1078ce9",
      "0xf1f5d35c46fd62fdd9150c39acc4a1b6a8327ae4",
      "0xb95619317834aea741a3ce3ee59ac7d621f989a4",
      "0xb67e55884096f203a423c80fe6f6b1c1bd791782",
      "0xc46200731b2a56b423f818c53f66025ef5ec6d7a",
      "0xa567027c7a7a5f3b2e2e58de823cef0c3d5e1e1f",
      "0x795de8e4e6c3db1b42ea658c42332ccb5927bae8",
      "0xa394ac5fab69542a9f2c8e291c4770078aa12d0a",
      "0x565b3b224f9f83573ca560b51cd772171380f826",
      "0xb46828c7d13d0e60f509cb22df35eb6ab0cac3df",
      "0x3e54b700d4a3e525e49ca5d4a8fb4282bd3be70f",
      "0x41ea7e9113bc00d3f7ce54130eb2f6d152bf91fd",
      "0xcc6454d3b32592f6960cc5e1989b7e4000c4b86d",
      "0xf04fd8595b52f530a775c5aefca7a7c7afd00aa8",
      "0x699ddc98ad9ff8b3b86c1d9ed2615a531b388bda",
      "0xc35e63e55821052678a727ca92610f428cd11efa",
      "0xc5f1c489cfca582c0d47fa2c036f84833e8ab700",
      "0x48002082cda92a7e3b87d022c95228f1df8598af",
      "0xf2e7156aea602b4670e78b1903933d729194fc68",
      "0x61fb776aad0b574f7783f26f0f9eedc53cfdc3f5",
      "0x881a5129d13a77e0cb2d93c688f4fb282f8df66c",
      "0x70a9e17fe82446a8144647899a597db851f9d64f",
      "0x8626f4cbb8a16f1e0a5e680b7c8125b18e088d14",
      "0x7a7cc83fe52d1d88c59865f122c89e2b1eca2a64",
      "0x352f82211583f051f27f020b131f5ecada42dcf7",
      "0xa5c2afefedaa04b9cbb2d946336c84798badf16f",
      "0xac6cd231c22919a9d0fc2b619e73134c380ca0ff",
      "0x001383f1723a205d760e57a21082d3ec85c89d81",
      "0xf0199be4eb1e56df218a6e87d52687d8ac892bfc",
      "0x072e382e590ed992953f2746fc281ae6e0d9232b",
      "0x8eb0603d8fa0fe67fe0fe02e367d95584e21d2a3",
      "0x67acd8b6b1e94c9131e2f6dd627f1396ac8f0b4b",
      "0x07a7fd7e12c626d1d1b4eb798e21a29455ed9e8b",
      "0x691e9635348b1eddd287e6db3e4431d6633ab047",
      "0x909fa4b53a7ec466af9f0f1f9732f8cd7509e574",
      "0xaf12f95a23f79c541e079924ec3089280373f692",
      "0x05cd4623c48553a3070061f557bc38a1d00f716c",
      "0xb843de66d048e87d986c6dda826a79e9a724d894",
      "0x2516115b336e3a5a0790d8b6efdf5bd8d7d263dd",
      "0x8088ef683c9d82d03445aee326a79855a639c58b",
      "0x4efd3ccfb7a1de70e1b9553cd96f9579dad10ba3",
      "0x9599996689368989f787e3537fe565823c9f32f3",
      "0xc30ae999e2efd260ebe8fe5b39ccc1ee3f3c29be",
      "0xd786bf9c23c5aefbaea5675d071680e0e8d15bff",
      "0x1b076946ba920e3489c544b45a6ec36595a191b9",
      "0x94422a95f525307bcaeb68956649b3cdb12c4855",
      "0x291e4ebb46c04d87c2fb10582b20e9258a1a83f8",
      "0x4751917e24eed8286894de9f5302df8daf510acc",
      "0xe24da1c8f33e1dd8b7993b8b028c7109698ddaa5",
      "0x535a658600aeaa7e15d537f49bd5cebb376708e5",
      "0xbb0f753321e2b5fd29bd1d14b532f5b54959ae63",
      "0x8438e4095783ebef8c951788ad42c3bcd084fb41",
      "0xd4105ee862023c362b10c8eacbd54916c22b96da",
      "0xf6ebfce2b97366f143a3b6fc2bf911765761ceae",
      "0x77d779e9af430f223980c22335a1dde00ebfe155",
      "0x58fcb11c78ec20eb6ae07134316d211e34008f83",
      "0xb8b8633d4cfd1983ac2ffa6843d9e556414d9a2e",
      "0xc3210b6609d32c6e4d3db0075375dc182aa67482",
      "0x109cbdcf9e4f6cb9ea56c810bc26f06f8b1f399f",
      "0x6a112cb926508b309f45d2155dd118950a1b9068",
      "0xc6221b456a4bbece215d211bfe32b81d8c1c1c3c",
      "0x39a329cdd8ac9d61155c6f15b36c7f95d3ea98c1",
      "0x0646fa00dd8f8d7166b6d58f741f656db0e78444",
      "0xe68c93e73d6841a0640e8acc528494287366f084",
      "0x3447c98edee975524e1fc9062211d7a4b453457e",
      "0xad920cd7046c3e3c5b562bbf61c60d7a0b5d85cf",
      "0x1a6b11218907cce7e25962ef39356f21fdc72832",
      "0x1191eb392e1d23357c344db11ffe6744c3998a55",
      "0xc276f3f25979d0724bec3f745c340ac4b8640c5a",
      "0xd476f83a84fea9a4f3da67a322f5873338784d95",
      "0x2a79421e5bd8676889b77905628285ca9ea38be8",
      "0xf75c6bb6ae1e91bf4892525c0d3e99f2e4e4de3e",
      "0x495ce8e423173eacaeb10d851d3b78a8ae09b4e1",
      "0x79f49449a106d290e697c3492694b80171052a8c",
      "0x8aa9e7004f6736b8471efe59b670b5d561063a1a" /*,
        "0x17f8dec583ab9af5de05fbbb4d4c2bfe767a0ac3"*/
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
