// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import {BasisSpiker} from "src/BasisSpiker.sol";
import {IPair} from "Dyson-Finance-V1/interface/IPair.sol";
import {IFactory} from "Dyson-Finance-V1/interface/IFactory.sol";
import {IERC20} from "Dyson-Finance-V1/interface/IERC20.sol";
import {TestUtils} from "Dyson-Finance-V1/test/TestUtils.sol";
import {console} from "forge-std/console.sol";

contract BasisSpikerForkTest is TestUtils {
    address usdc;
    address weth_usdc_pair;

    uint256 internal constant ONE_DAY_PREMIUM_K = 20936956903608548; // precomputed factor used in Pair.getPremium for 1 day
    uint256 internal constant FORK_BLOCK = 28115560; // (UTC) 12/19/2025, 04:33:09

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
        spiker = new BasisSpiker(address(pair));
        oldController = factory.controller();

        // Fund owner (this contract) with live tokens on fork.
        deal(usdc, address(this), 1_000_000e6);
        IERC20(usdc).approve(address(spiker), type(uint256).max);
    }

    /// @notice Spike basis then withdraw all notes; expected to stop mid-way due to insufficient reserves.
    function testWithdrawAllStopsOnInsufficientLiquidity() public {
        _takeController();

        uint256 oldBasis = pair.basis();
        uint256 newBasis = (1_000_0e18 * 1e18 + ONE_DAY_PREMIUM_K - 1) / ONE_DAY_PREMIUM_K; // round up
        uint256[] memory usdcDeposits = _buildUsdcDeposits();
        uint256 total1 = _sum(usdcDeposits);

        spiker.spikeAndDeposit(newBasis, new uint256[](0), usdcDeposits, 0, total1);

        // Basis restored.
        assertEq(pair.basis(), oldBasis, "basis not restored");

        // Controller restored.
        assertEq(factory.pendingController(), oldController, "controller not restored");

        vm.warp(block.timestamp + 1 days + 1);

        uint256 receiver0Before = IERC20(token0).balanceOf(user);
        uint256 receiver1Before = IERC20(token1).balanceOf(user);
        (uint256 reserve0Before, uint256 reserve1Before) = pair.getReserves();

        spiker.withdrawAll(user);

        uint256 receiver0After = IERC20(token0).balanceOf(user);
        uint256 receiver1After = IERC20(token1).balanceOf(user);
        (uint256 reserve0After, uint256 reserve1After) = pair.getReserves();

        uint256 receiver0Delta = receiver0After - receiver0Before;
        uint256 receiver1Delta = receiver1After - receiver1Before;

        assertTrue(receiver0After > receiver0Before || receiver1After > receiver1Before, "receiver got nothing");
        // Should withdraw on note 13 but fail on note 14 due to insufficient reserves.
        IPair.Note memory note13 = pair.notes(address(spiker), 13);
        IPair.Note memory note14 = pair.notes(address(spiker), 14);
        assertTrue(note13.token0Amt == 0 && note13.token1Amt == 0, "expected fully withdrawn note13");
        assertTrue(note14.token0Amt != 0 || note14.token1Amt != 0, "expected remaining note after stop");

        // In the beginning,
        // reserve0: 11.278683928339019682 WETH
        // reserve1: 32873.540396 USDC
        // After deposits and 1 day warp, reserves are:
        // reserve0: 11.278683928339019682 WETH
        // reserve1: 32880.159330 USDC
        // After withdrawAll, reserves are:
        // reserve0: 0.012875303359153263 WETH
        // reserve1: 39.755618 USDC
        // Therefore, total withdrawn amounts are:
        // receiver0Delta: 11.265808624979866419 WETH
        // receiver1Delta: 32840.403712 USDC
        assertEq(receiver0Delta, 11265808624979866419); // 11.265808624979866419 WETH
        assertEq(receiver1Delta, 32840403712); // 32840.403712 USDC
        assertEq(reserve0After, 12875303359153263); // 0.012875303359153263 WETH
        assertEq(reserve1After, 39755618); // 39.755618 USDC
    }

    function _takeController() private {
        vm.prank(oldController);
        factory.setController(address(spiker));
    }

    function _buildUsdcDeposits() private pure returns (uint256[] memory usdcDeposits) {
        uint256[30] memory rawValues = [
            uint256(1.654784e6),
            1.654784e6, // 2^14*1.01
            0.827392e6,
            0.827392e6, // 2^13*1.01
            0.413696e6,
            0.413696e6, // 2^12*1.01
            0.206848e6,
            0.206848e6, // 2^11*1.01
            0.103424e6,
            0.103424e6, // 2^10*1.01
            0.051712e6,
            0.051712e6, // 2^9*1.01
            0.025856e6,
            0.025856e6, // 2^8*1.01
            0.012928e6,
            0.012928e6, // 2^7*1.01
            0.006464e6,
            0.006464e6, // 2^6*1.01
            0.003232e6,
            0.003232e6, // 2^5*1.01
            0.001616e6,
            0.001616e6, // 2^4*1.01
            0.000808e6,
            0.000808e6, // 2^3*1.01
            0.000404e6,
            0.000404e6, // 2^2*1.01
            0.000202e6,
            0.000202e6, // 2^1*1.01
            0.000101e6,
            0.000101e6 // 2^0*1.01
        ];

        usdcDeposits = new uint256[](rawValues.length);
        for (uint256 i = 0; i < rawValues.length; i++) {
            usdcDeposits[i] = rawValues[i];
        }
    }

    function _sum(uint256[] memory amounts) private pure returns (uint256 total) {
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
    }
}
