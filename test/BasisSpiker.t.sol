// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import {stdError} from "forge-std/StdError.sol";
import {BasisSpiker} from "src/BasisSpiker.sol";
import {IPair} from "Dyson-Finance-V1/interface/IPair.sol";
import {Factory} from "Dyson-Finance-V1/Factory.sol";
import {Pair} from "Dyson-Finance-V1/Pair.sol";
import {DYSON} from "Dyson-Finance-V1/DYSON.sol";
import {TestUtils} from "Dyson-Finance-V1/test/TestUtils.sol";

contract MockUSDC {
    string public constant NAME = "Mock USDC";
    string public constant SYMBOL = "mUSDC";
    uint8 private constant DECIMALS = 6;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract BasisSpikerTest is TestUtils {
    uint256 internal constant INITIAL_LIQUIDITY_DYSN = 1e24; // DYSN (18 decimals)
    uint256 internal constant INITIAL_LIQUIDITY_USDC = 1e12; // 1e6 tokens with 6 decimals
    uint256 internal constant INITIAL_WEALTH_DYSN = 1e30; // DYSN (18 decimals)
    uint256 internal constant INITIAL_WEALTH_USDC = 1e18; // 1e12 tokens with 6 decimals
    uint256 internal constant USDC_DECIMALS = 1e6;
    uint256 internal constant ONE_DAY_PREMIUM_K = 20936956903608548; // precomputed factor used in Pair.getPremium for 1 day

    DYSON dysn;
    MockUSDC usdc;
    Factory factory = new Factory(address(this));
    Pair pair;
    BasisSpiker spiker;

    address user = _nameToAddr("user");
    bool internal dysonIsToken0;

    function setUp() public {
        dysn = new DYSON(address(this));
        usdc = new MockUSDC();

        pair = Pair(factory.createPair(address(dysn), address(usdc)));
        dysonIsToken0 = pair.token0() == address(dysn);
        spiker = new BasisSpiker(address(pair));

        // Seed pool reserves.
        dysn.mint(address(pair), INITIAL_LIQUIDITY_DYSN);
        usdc.mint(address(pair), INITIAL_LIQUIDITY_USDC);

        // Fund owner (this contract) for deposits.
        dysn.mint(address(this), INITIAL_WEALTH_DYSN);
        usdc.mint(address(this), INITIAL_WEALTH_USDC);

        // Prime pending controller to BasisSpiker; spikeAndDeposit will take and return control.
        factory.setController(address(spiker));
    }

    function _approveOwnerToSpiker() internal {
        dysn.approve(address(spiker), type(uint256).max);
        usdc.approve(address(spiker), type(uint256).max);
    }

    function testSpikeAndDepositRestoresBasisAndController() public {
        _approveOwnerToSpiker();
        uint256 oldBasis = pair.basis();
        uint256 newBasis = oldBasis * 10;

        uint256[] memory dysonDeposits = new uint256[](2);
        dysonDeposits[0] = 1e18;
        dysonDeposits[1] = 2e18;
        uint256[] memory usdcDeposits = new uint256[](1);
        usdcDeposits[0] = 3e6;

        (uint256[] memory amounts0, uint256[] memory amounts1) =
            dysonIsToken0 ? (dysonDeposits, usdcDeposits) : (usdcDeposits, dysonDeposits);

        uint256 total0 = _sum(amounts0);
        uint256 total1 = _sum(amounts1);

        uint256 reserve0Before;
        uint256 reserve1Before;
        (reserve0Before, reserve1Before) = pair.getReserves();

        spiker.spikeAndDeposit(newBasis, amounts0, amounts1, total0, total1);

        assertEq(pair.basis(), oldBasis, "basis should restore");
        assertEq(factory.pendingController(), address(this), "controller should restore");
        assertEq(pair.noteCount(address(spiker)), amounts0.length + amounts1.length, "notes minted");

        // Ensure user deposit reached the pair.
        (uint256 reserve0After, uint256 reserve1After) = pair.getReserves();
        assertEq(reserve0After, reserve0Before + total0, "DYSN added");
        assertEq(reserve1After, reserve1Before + total1, "USDC added");
    }

    function testSpikeAndDepositRevertsIfNotController() public {
        _approveOwnerToSpiker();
        factory.setController(user);

        uint256[] memory dysonDeposits = new uint256[](1);
        dysonDeposits[0] = 1e18;
        uint256[] memory usdcDeposits = new uint256[](0);
        (uint256[] memory amounts0, uint256[] memory amounts1) =
            dysonIsToken0 ? (dysonDeposits, usdcDeposits) : (usdcDeposits, dysonDeposits);
        uint256 total0 = _sum(amounts0);
        uint256 total1 = _sum(amounts1);

        assertEq(factory.pendingController(), user, "pending controller should be user");
        uint256 basis = 1e18; // Random basis
        vm.expectRevert(BasisSpiker.NotController.selector);
        spiker.spikeAndDeposit(basis, amounts0, amounts1, total0, total1);
    }

    function testSpikeAndDepositRevertsIfNoDeposits() public {
        _approveOwnerToSpiker();
        uint256[] memory empty = new uint256[](0);
        assertEq(factory.pendingController(), address(spiker), "pending controller should be spiker");
        uint256 basis = 1e18; // Random basis
        vm.expectRevert(BasisSpiker.NoDeposits.selector);
        spiker.spikeAndDeposit(basis, empty, empty, 0, 0);
    }

    function testSpikeAndDepositRevertsOnPremiumOverflow() public {
        _approveOwnerToSpiker();

        uint256 deposit = INITIAL_WEALTH_DYSN;
        uint256[] memory dysonDeposits = new uint256[](1);
        dysonDeposits[0] = deposit;
        uint256[] memory empty = new uint256[](0);
        (uint256[] memory amounts0, uint256[] memory amounts1) =
            dysonIsToken0 ? (dysonDeposits, empty) : (empty, dysonDeposits);

        uint256 total0 = _sum(amounts0);
        uint256 total1 = _sum(amounts1);

        uint256 premiumOverflowThreshold = type(uint256).max / deposit;
        uint256 premiumTarget = premiumOverflowThreshold;
        uint256 newBasis = (premiumTarget * 1e18 + ONE_DAY_PREMIUM_K - 1) / ONE_DAY_PREMIUM_K;

        vm.expectRevert(stdError.arithmeticError);
        spiker.spikeAndDeposit(newBasis, amounts0, amounts1, total0, total1);
    }

    function testSpikeAndDepositSetsPairAllowance() public {
        _approveOwnerToSpiker();
        uint256[] memory dysonDeposits = new uint256[](1);
        dysonDeposits[0] = 5e18;
        uint256[] memory usdcDeposits = new uint256[](1);
        usdcDeposits[0] = 10 * 1e6;
        (uint256[] memory amounts0, uint256[] memory amounts1) =
            dysonIsToken0 ? (dysonDeposits, usdcDeposits) : (usdcDeposits, dysonDeposits);
        uint256 total0 = _sum(amounts0);
        uint256 total1 = _sum(amounts1);

        spiker.spikeAndDeposit(pair.basis(), amounts0, amounts1, total0, total1);

        assertEq(dysn.allowance(address(spiker), address(pair)), 0, "DYSN allowance");
        assertEq(usdc.allowance(address(spiker), address(pair)), 0, "USDC allowance");
    }

    function testSpikeAndDepositRevertsIfNotOwner() public {
        _approveOwnerToSpiker();
        uint256[] memory dysonDeposits = new uint256[](1);
        dysonDeposits[0] = 1e18;
        uint256[] memory usdcDeposits = new uint256[](0);
        (uint256[] memory amounts0, uint256[] memory amounts1) =
            dysonIsToken0 ? (dysonDeposits, usdcDeposits) : (usdcDeposits, dysonDeposits);
        uint256 total0 = _sum(amounts0);
        uint256 total1 = _sum(amounts1);
        uint256 newBasis = 1e18; // Random basis

        vm.prank(user);
        vm.expectRevert(BasisSpiker.NotOwner.selector);
        spiker.spikeAndDeposit(newBasis, amounts0, amounts1, total0, total1);
    }

    function testWithdrawAllRevertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert(BasisSpiker.NotOwner.selector);
        spiker.withdrawAll(user);
    }

    function testWithdrawAllPartialOnInsufficientLiquidity() public {
        _approveOwnerToSpiker();

        // Create two notes (token0 deposits).
        uint256[] memory dysonDeposits = new uint256[](2);
        dysonDeposits[0] = 1e18;
        dysonDeposits[1] = 2e18;
        uint256[] memory usdcDeposits = new uint256[](0);
        (uint256[] memory amounts0, uint256[] memory amounts1) =
            dysonIsToken0 ? (dysonDeposits, usdcDeposits) : (usdcDeposits, dysonDeposits);
        uint256 total0 = _sum(amounts0);

        spiker.spikeAndDeposit(pair.basis(), amounts0, amounts1, total0, 0);

        vm.warp(block.timestamp + 1 days + 1);

        // Capture first/second note contents to size the pool so only the first can succeed.
        (uint256 note0Token0, uint256 note0Token1,) = pair.notes(address(spiker), 0);
        (uint256 note1Token0, uint256 note1Token1,) = pair.notes(address(spiker), 1);

        // Set pair balances to exactly cover note0 amounts; note1 should fail and break the loop.
        if (dysonIsToken0) {
            deal(pair.token0(), address(pair), note0Token0);
            deal(pair.token1(), address(pair), note0Token1);
        } else {
            deal(pair.token0(), address(pair), note0Token1);
            deal(pair.token1(), address(pair), note0Token0);
        }

        uint256 receiver0Before = dysn.balanceOf(user);
        uint256 receiver1Before = usdc.balanceOf(user);

        spiker.withdrawAll(user);

        uint256 receiver0After = dysn.balanceOf(user);
        uint256 receiver1After = usdc.balanceOf(user);

        // At least one token paid out; second note should remain since liquidity was insufficient.
        assertTrue(receiver0After > receiver0Before || receiver1After > receiver1Before, "receiver got nothing");
        // Note1 remains untouched (non-zero)
        (uint256 note1Token0After, uint256 note1Token1After,) = pair.notes(address(spiker), 1);
        assertTrue(note1Token0After == note1Token0 || note1Token1After == note1Token1, "note1 should remain");
    }

    function _sum(uint256[] memory amounts) private pure returns (uint256 total) {
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
    }
}
