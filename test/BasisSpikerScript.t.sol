// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {IPair} from "Dyson-Finance-V1/interface/IPair.sol";
import {IFactory} from "Dyson-Finance-V1/interface/IFactory.sol";
import {IERC20} from "Dyson-Finance-V1/interface/IERC20.sol";
import {BasisSpikerScript} from "script/BasisSpiker.s.sol";

contract BasisSpikerScriptHarness is BasisSpikerScript {
    function execute(address controller, address usdc, address pairAddr) external {
        vm.startPrank(controller);
        _execute(controller, usdc, pairAddr);
        vm.stopPrank();
    }

    function buildUsdcDeposits() external pure returns (uint256[] memory deposits) {
        deposits = _buildUsdcDeposits();
    }

    function sum(uint256[] memory amounts) external pure returns (uint256 total) {
        total = _sum(amounts);
    }
}

contract BasisSpikerScriptTest is Test {
    uint256 internal constant FORK_BLOCK = 28115560;

    BasisSpikerScriptHarness harness;
    IPair pair;
    IFactory factory;
    address controller;
    address usdc;
    address pairAddr;

    function setUp() public {
        string memory rpc = vm.envString("POLYGON_ZKEVM_RPC_URL");
        vm.createSelectFork(rpc, FORK_BLOCK);

        usdc = vm.envAddress("USDC");
        pairAddr = vm.envAddress("WETH_USDC_PAIR");

        pair = IPair(pairAddr);
        factory = IFactory(pair.factory());
        controller = factory.controller();

        harness = new BasisSpikerScriptHarness();
    }

    function testScriptExecuteSpikeAndDeposit() public {
        uint256 oldBasis = pair.basis();
        uint256 noteCountBefore = pair.noteCount(controller);

        uint256[] memory usdcDeposits = harness.buildUsdcDeposits();
        uint256 totalUsdc = harness.sum(usdcDeposits);

        // Ensure controller has funds for the deposit on this fork.
        deal(usdc, controller, totalUsdc);

        // Run the script logic (harness will prank as controller internally).
        harness.execute(controller, usdc, pairAddr);

        // Basis restored.
        assertEq(pair.basis(), oldBasis, "basis should be restored");

        // Controller restored.
        assertEq(factory.controller(), controller, "controller should be restored");

        // Notes minted equals deposit count (delta).
        uint256 noteCountAfter = pair.noteCount(controller);
        assertEq(noteCountAfter - noteCountBefore, usdcDeposits.length, "note count delta");
    }
}
