// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import {BasisSpiker} from "src/BasisSpiker.sol";
import {stdError} from "forge-std/StdError.sol";
import {IPair} from "Dyson-Finance-V1/interface/IPair.sol";
import {IFactory} from "Dyson-Finance-V1/interface/IFactory.sol";
import {IERC20} from "Dyson-Finance-V1/interface/IERC20.sol";
import {TestUtils} from "Dyson-Finance-V1/test/TestUtils.sol";
import {console} from "forge-std/console.sol";

contract BasisSpikerForkTest is TestUtils {
    // we test all cases on the WETH/USDC pair via `pair` from setUp().
    // Only testSpikeAndWithdrawAllOnDysnPool() switches to the DYSN/USDC pool for that specific flow.
    address usdc;
    address wethUsdcPair;

    uint256 internal constant ONE_DAY_PREMIUM_K = 20936956903608548; // precomputed factor used in Pair.getPremium for 1 day

    BasisSpiker spiker;
    IPair pair;
    IFactory factory;
    address newController;
    address token0;
    address token1;

    address user = _nameToAddr("user");
    string internal forkRpcUrl;

    function setUp() public {
        newController = vm.envAddress("NEW_FACTORY_CONTROLLER");
        forkRpcUrl = vm.envString("POLYGON_ZKEVM_RPC_URL");
        usdc = vm.envAddress("USDC");
        wethUsdcPair = vm.envAddress("WETH_USDC_PAIR");
        vm.createSelectFork(forkRpcUrl);
        console.log("block number:", block.number);

        pair = IPair(wethUsdcPair);
        token0 = pair.token0();
        token1 = pair.token1();

        factory = IFactory(pair.factory());
        spiker = new BasisSpiker(address(pair));
        address oldController = factory.controller();
        vm.prank(oldController);
        factory.setController(address(spiker));

        // Fund owner (this contract) with live tokens on fork.
        deal(usdc, address(this), 1_000_000e6);
        IERC20(usdc).approve(address(spiker), type(uint256).max);
    }

    function _approveOwnerToSpiker() internal {
        IERC20(token1).approve(address(spiker), type(uint256).max);
    }

    function testSpikeAndDepositRestoresBasisAndController() public {
        _approveOwnerToSpiker();
        uint256 oldBasis = pair.basis();
        uint256 newBasis = oldBasis * 2;

        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 3e6;
        uint256 total1 = _sum(amounts1);

        (, uint256 reserve1Before) = _safeReserves();

        spiker.spikeAndDeposit(newController, newBasis, amounts1, total1);

        assertEq(pair.basis(), oldBasis, "basis should restore");
        assertEq(factory.pendingController(), newController, "controller should restore");
        assertEq(pair.noteCount(address(spiker)), amounts1.length, "notes minted");

        (, uint256 reserve1After) = _safeReserves();
        assertEq(reserve1After, reserve1Before + total1, "token1 added");
    }

    function testSpikeAndDepositRevertsIfNotController() public {
        _approveOwnerToSpiker();
        vm.prank(factory.controller());
        factory.setController(user); // set pending to user, not spiker

        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 3e6;
        uint256 total1 = _sum(amounts1);
        uint256 basis = 1e18;

        vm.expectRevert(BasisSpiker.NotController.selector);
        spiker.spikeAndDeposit(newController, basis, amounts1, total1);
    }

    function testSpikeAndDepositRevertsIfNoDeposits() public {
        _approveOwnerToSpiker();
        uint256[] memory empty = new uint256[](0);
        uint256 basis = 1e18;
        vm.expectRevert(BasisSpiker.NoDeposits.selector);
        spiker.spikeAndDeposit(newController, basis, empty, 0);
    }

    function testSpikeAndDepositRevertsOnPremiumOverflow() public {
        _approveOwnerToSpiker();

        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 1e6;
        uint256 total1 = _sum(amounts1);
        uint256 newBasis = type(uint256).max / ONE_DAY_PREMIUM_K + 1;

        vm.expectRevert(stdError.arithmeticError);
        spiker.spikeAndDeposit(newController, newBasis, amounts1, total1);
    }

    function testSpikeAndDepositSetsPairAllowance() public {
        _approveOwnerToSpiker();
        uint256[] memory amounts1 = new uint256[](2);
        amounts1[0] = 5e6;
        amounts1[1] = 10e6;
        uint256 total1 = _sum(amounts1);

        spiker.spikeAndDeposit(newController, pair.basis(), amounts1, total1);

        assertEq(IERC20(token1).allowance(address(spiker), address(pair)), 0, "token1 allowance should be spent");
    }

    function testSpikeAndDepositRevertsIfNotOwner() public {
        _approveOwnerToSpiker();
        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 1e6;
        uint256 total1 = _sum(amounts1);
        uint256 newBasis = 1e18;

        vm.prank(user);
        vm.expectRevert(BasisSpiker.NotOwner.selector);
        spiker.spikeAndDeposit(newController, newBasis, amounts1, total1);
    }

    function testWithdrawAllRevertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(BasisSpiker.NotOwner.selector);
        spiker.withdrawAll(user);
    }

    /// @notice Full flow: spike basis, deposit multiple notes, wait, withdraw all notes on Weth Pool.
    function testSpikeAndWithdrawAllOnWethPool() public {
        uint256 newBasis = (1_000_0e18 * 1e18 + ONE_DAY_PREMIUM_K - 1) / ONE_DAY_PREMIUM_K; // round up
        uint256[] memory usdcDeposits = _buildUsdcDepositsForWethPool();
        uint256 total1 = _sum(usdcDeposits);

        spiker.spikeAndDeposit(newController, newBasis, usdcDeposits, total1);

        vm.warp(block.timestamp + 1 days + 1);

        (uint256 receiver0Before, uint256 receiver1Before) = _balances(user, token0, token1);

        uint256 noteCount = pair.noteCount(address(spiker));
        IPair.Note[] memory notesBefore = new IPair.Note[](noteCount);
        for (uint256 i = 0; i < noteCount; i++) {
            notesBefore[i] = pair.notes(address(spiker), i);
        }

        spiker.withdrawAll(user);

        (uint256 receiver0After, uint256 receiver1After) = _balances(user, token0, token1);
        (uint256 reserve0After, uint256 reserve1After) = _safeReserves();

        uint256 cleared = _countClearedNotes(pair, spiker, notesBefore);

        // At least one note withdrawn and user received funds.
        assertTrue(cleared > 0, "no notes withdrawn");
        assertTrue(receiver0After > receiver0Before || receiver1After > receiver1Before, "receiver got nothing");

        console.log("reserve0After", reserve0After);
        console.log("reserve1After", reserve1After);
    }

    /// @notice Same flow as testSpikeAndWithdrawAll but on the DYSN/USDC pool.
    function testSpikeAndWithdrawAllOnDysnPool() public {
        address dysonPairAddr = vm.envAddress("DYSN_USDC_PAIR");
        IPair dysonPair = IPair(dysonPairAddr);
        address t0 = dysonPair.token0(); // DYSN
        address t1 = dysonPair.token1(); // USDC

        BasisSpiker s = new BasisSpiker(address(dysonPair));
        IFactory f = IFactory(dysonPair.factory());
        vm.prank(f.controller());
        f.setController(address(s));

        {
            uint256[] memory usdcDeposits = _buildUsdcDepositsForDysnPool();
            uint256 total1 = _sum(usdcDeposits);
            deal(t1, address(this), total1);
            IERC20(t1).approve(address(s), type(uint256).max);
            uint256 newBasis = (1_000_0e18 * 1e18 + ONE_DAY_PREMIUM_K - 1) / ONE_DAY_PREMIUM_K;
            s.spikeAndDeposit(newController, newBasis, usdcDeposits, total1);
        }

        vm.warp(block.timestamp + 1 days + 1);

        (uint256 receiver0Before, uint256 receiver1Before) = _balances(user, t0, t1);

        uint256 noteCount = dysonPair.noteCount(address(s));
        IPair.Note[] memory notesBefore = new IPair.Note[](noteCount);
        for (uint256 i = 0; i < noteCount; i++) {
            notesBefore[i] = dysonPair.notes(address(s), i);
        }


        s.withdrawAll(user);

        (uint256 reserve0After, uint256 reserve1After) = _safeReservesFor(dysonPair, t0, t1);

        (uint256 receiver0After, uint256 receiver1After) = _balances(user, t0, t1);
        uint256 cleared = _countClearedNotes(dysonPair, s, notesBefore);

        assertTrue(cleared > 0, "no notes withdrawn");
        assertTrue(receiver0After > receiver0Before || receiver1After > receiver1Before, "receiver got nothing");

        console.log("reserve0After", reserve0After);
        console.log("reserve1After", reserve1After);
    }

    function _buildUsdcDepositsForWethPool() private pure returns (uint256[] memory usdcDeposits) {
        uint256[34] memory rawValues = [
            uint256(6.5536e6),
            6.5536e6,      // 2^16
            3.2768e6,
            3.2768e6,      // 2^15
            1.6384e6,
            1.6384e6,      // 2^14
            0.8192e6,
            0.8192e6,      // 2^13
            0.4096e6,
            0.4096e6,      // 2^12
            0.2048e6,
            0.2048e6,      // 2^11
            0.1024e6,
            0.1024e6,      // 2^10
            0.0512e6,
            0.0512e6,      // 2^9
            0.0256e6,
            0.0256e6,      // 2^8
            0.0128e6,
            0.0128e6,      // 2^7
            0.0064e6,
            0.0064e6,      // 2^6
            0.0032e6,
            0.0032e6,      // 2^5
            0.0016e6,
            0.0016e6,      // 2^4
            0.0008e6,
            0.0008e6,      // 2^
            0.0004e6,
            0.0004e6,      // 2^2
            0.0002e6,
            0.0002e6,      // 2^1
            0.0001e6,
            0.0001e6       // 2^0
        ];

        usdcDeposits = new uint256[](rawValues.length);
        for (uint256 i = 0; i < rawValues.length; i++) {
            usdcDeposits[i] = rawValues[i];
        }
    }

    function _buildUsdcDepositsForDysnPool() private pure returns (uint256[] memory usdcDeposits) {
        uint256[30] memory rawValues = [
            uint256(1.6384e6),
            1.6384e6,      // 2^14
            0.8192e6,
            0.8192e6,      // 2^13
            0.4096e6,
            0.4096e6,      // 2^12
            0.2048e6,
            0.2048e6,      // 2^11
            0.1024e6,
            0.1024e6,      // 2^10
            0.0512e6,
            0.0512e6,      // 2^9
            0.0256e6,
            0.0256e6,      // 2^8
            0.0128e6,
            0.0128e6,      // 2^7
            0.0064e6,
            0.0064e6,      // 2^6
            0.0032e6,
            0.0032e6,      // 2^5
            0.0016e6,
            0.0016e6,      // 2^4
            0.0008e6,
            0.0008e6,      // 2^
            0.0004e6,
            0.0004e6,      // 2^2
            0.0002e6,
            0.0002e6,      // 2^1
            0.0001e6,
            0.0001e6       // 2^0
        ];

        usdcDeposits = new uint256[](rawValues.length);
        for (uint256 i = 0; i < rawValues.length; i++) {
            usdcDeposits[i] = rawValues[i];
        }
    }

    function _safeReserves() private view returns (uint256 reserve0After, uint256 reserve1After) {
        return _safeReservesFor(pair, token0, token1);
    }

    function _safeReservesFor(IPair _pair, address _token0, address _token1)
        private
        view
        returns (uint256 reserve0After, uint256 reserve1After)
    {
        uint balance0 = IERC20(_token0).balanceOf(address(_pair));
        uint balance1 = IERC20(_token1).balanceOf(address(_pair));
        console.log("Test: pair balances:", balance0, balance1);
        try _pair.getReserves() returns (uint256 r0, uint256 r1) {
            reserve0After = r0;
            reserve1After = r1;
            console.log("Test: getReserves returned", r0, r1);
            console.log("Test: accumulated fees:", balance0 - r0, balance1 - r1);
        } catch {
            reserve0After = balance0;
            reserve1After = balance1;
        }
    }

    function _sum(uint256[] memory amounts) private pure returns (uint256 total) {
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
    }

    function _balances(address account, address _token0, address _token1)
        private
        view
        returns (uint256 balance0, uint256 balance1)
    {
        balance0 = IERC20(_token0).balanceOf(account);
        balance1 = IERC20(_token1).balanceOf(account);
    }

    function _countClearedNotes(IPair _pair, BasisSpiker _spiker, IPair.Note[] memory notesBefore)
        private
        view
        returns (uint256 cleared)
    {
        uint256 noteCount = notesBefore.length;
        for (uint256 i = 0; i < noteCount; i++) {
            IPair.Note memory noteAfter = _pair.notes(address(_spiker), i);
            bool clearedNote = noteAfter.token0Amt == 0 && noteAfter.token1Amt == 0;
            bool untouched = noteAfter.token0Amt == notesBefore[i].token0Amt
                && noteAfter.token1Amt == notesBefore[i].token1Amt
                && noteAfter.due == notesBefore[i].due;
            assertTrue(clearedNote || untouched, "note mutated incorrectly");
            if (clearedNote) cleared++;
        }
    }
}
