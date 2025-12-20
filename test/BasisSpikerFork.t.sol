// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import {BasisSpiker} from "src/BasisSpiker.sol";
import {IPair} from "Dyson-Finance-V1/interface/IPair.sol";
import {IFactory} from "Dyson-Finance-V1/interface/IFactory.sol";
import {IERC20} from "Dyson-Finance-V1/interface/IERC20.sol";
import {TestUtils} from "Dyson-Finance-V1/test/TestUtils.sol";
import {console} from "forge-std/console.sol";

contract BasisSpikerForkTest is TestUtils {
    address weth;
    address usdc;
    address weth_usdc_pair;

    uint internal constant ONE_DAY_PREMIUM_K = 20936956903608548; // precomputed factor used in Pair.getPremium for 1 day
    uint internal constant FORK_BLOCK = 28115560; // (UTC) 12/19/2025, 04:33:09

    BasisSpiker spiker;
    IPair pair;
    IFactory factory;
    address oldController;
    address token0;
    address token1;

    address user = _nameToAddr("user");
    string internal forkRpcUrl;

    function setUp() public {
        forkRpcUrl = vm.envString("POLYGON_ZKEVM_RPC_URL");
        weth = vm.envAddress("WETH");
        usdc = vm.envAddress("USDC");
        weth_usdc_pair = vm.envAddress("WETH_USDC_PAIR");
        vm.createSelectFork(forkRpcUrl, FORK_BLOCK);
        console.log("block number:", block.number);

        pair = IPair(weth_usdc_pair);
        // At this block,
        // reserve0 is 11.278683928339019682 WETH
        // reserve1 is 32873.540396 USDC
        token0 = pair.token0();
        token1 = pair.token1();

        factory = IFactory(pair.factory());
        spiker = new BasisSpiker();
        oldController = factory.controller();

        // Fund user with live tokens on fork.
        deal(weth, user, 100 ether);
        deal(usdc, user, 1_000_000e6);

        vm.startPrank(user);
        IERC20(weth).approve(address(spiker), type(uint).max);
        IERC20(usdc).approve(address(spiker), type(uint).max);
        vm.stopPrank();
        
    }

    /// @notice Spike basis to an extreme premium on the real WETH/USDC pair and withdraw all notes.
    function testUsdcDepositsAndWithdraw() public {
        // Spike and deposit
        // Take controller so BasisSpiker can set basis during the test.
        _takeController();

        uint oldBasis = pair.basis();
        uint newBasis = (1_000_0e18 * 1e18 + ONE_DAY_PREMIUM_K - 1) / ONE_DAY_PREMIUM_K; // round up
        console.log("newBasis:", newBasis);
        uint[] memory usdcDeposits = _buildUsdcDeposits();
        uint total1 = _sum(usdcDeposits);

        vm.prank(user);
        spiker.spikeAndDeposit(IPair(address(pair)), newBasis, new uint[](0), usdcDeposits, 0, total1, user);

        // Verify basis restored.
        uint finalBasis = pair.basis();
        assertEq(finalBasis, oldBasis, "basis not restored");
        
        // Verify original controller restored.
        address finalController = factory.pendingController();
        assertEq(finalController, oldController, "controller not restored");


        // Withdraw all notes
        uint balance0Before = IERC20(token0).balanceOf(user);
        uint balance1Before = IERC20(token1).balanceOf(user);

        vm.warp(block.timestamp + 1 days + 1);
        (uint totalWithdraw0, uint totalWithdraw1) = _withdrawAllNotes(pair, 30, user);

        // Verify user received all tokens back
        uint balance0After = IERC20(token0).balanceOf(user);
        uint balance1After = IERC20(token1).balanceOf(user);
        assertEq(balance0After - balance0Before, totalWithdraw0, "token0 credited to user");
        assertEq(balance1After - balance1Before, totalWithdraw1, "token1 credited to user");
    }

    function _withdrawAllNotes(IPair localPair, uint noteCount, address owner) private returns (uint totalWithdraw0, uint totalWithdraw1) {
        
        for (uint i = 0; i < noteCount; i++) {
            vm.prank(owner);
            (uint token0Amt, uint token1Amt) = localPair.withdraw(i, owner);
            totalWithdraw0 += token0Amt;
            totalWithdraw1 += token1Amt;
            console.log("withdraw index", i);
            console.log("withdraw token0, token1: ", token0Amt, token1Amt);
        }
        console.log("totalWithdraw0", totalWithdraw0);
        console.log("totalWithdraw1", totalWithdraw1);
        (uint reserve0, uint reserve1) = localPair.getReserves();
        console.log("Reserve0 after withdraw", reserve0);
        console.log("Reserve1 after withdraw", reserve1);

    }

    function _takeController() private {
        vm.prank(oldController);
        factory.setController(address(spiker));
    }

    function _buildUsdcDeposits() private pure returns (uint[] memory usdcDeposits) {
        uint[30] memory rawValues = [
            uint(1.6384e6), 1.6384e6,       // 2^14
            0.8192e6, 0.8192e6,       // 2^13
            0.4096e6, 0.4096e6,       // 2^12
            0.2048e6, 0.2048e6,       // 2^11
            0.1024e6, 0.1024e6,       // 2^10
            0.0512e6, 0.0512e6,       // 2^9
            0.0256e6, 0.0256e6,       // 2^8
            0.0128e6, 0.0128e6,       // 2^7
            0.0064e6, 0.0064e6,       // 2^6
            0.0032e6, 0.0032e6,       // 2^5
            0.0016e6, 0.0016e6,       // 2^4
            0.0008e6, 0.0008e6,       // 2^3
            0.0004e6, 0.0004e6,       // 2^2
            0.0002e6, 0.0002e6,       // 2^1
            0.0001e6, 0.0001e6       // 2^0  
        ];

        usdcDeposits = new uint[](rawValues.length);
        for (uint i = 0; i < rawValues.length; i++) {
            usdcDeposits[i] = rawValues[i];
        }
    }

    function _sum(uint[] memory amounts) private pure returns (uint total) {
        for (uint i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
    }
}
