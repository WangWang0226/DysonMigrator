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
    uint public totalSupply;

    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;

    event Transfer(address indexed from, address indexed to, uint amount);
    event Approval(address indexed owner, address indexed spender, uint amount);

    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    function mint(address to, uint amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint amount) external returns (bool) {
        uint allowed = allowance[from][msg.sender];
        if (allowed != type(uint).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract BasisSpikerTest is TestUtils {
    uint internal constant INITIAL_LIQUIDITY_DYSN = 1e24; // DYSN (18 decimals)
    uint internal constant INITIAL_LIQUIDITY_USDC = 1e12; // 1e6 tokens with 6 decimals
    uint internal constant INITIAL_WEALTH_DYSN = 1e30; // DYSN (18 decimals)
    uint internal constant INITIAL_WEALTH_USDC = 1e18; // 1e12 tokens with 6 decimals
    uint internal constant USDC_DECIMALS = 1e6;
    uint internal constant ONE_DAY_PREMIUM_K = 20936956903608548; // precomputed factor used in Pair.getPremium for 1 day

    DYSON dysn;
    MockUSDC usdc;
    Factory factory = new Factory(address(this));
    Pair pair;
    BasisSpiker spiker = new BasisSpiker();

    address user = _nameToAddr("user");
    bool internal dysonIsToken0;

    function setUp() public {
        dysn = new DYSON(address(this));
        usdc = new MockUSDC();

        pair = Pair(factory.createPair(address(dysn), address(usdc)));
        dysonIsToken0 = pair.token0() == address(dysn);

        // Seed pool reserves.
        dysn.mint(address(pair), INITIAL_LIQUIDITY_DYSN);
        usdc.mint(address(pair), INITIAL_LIQUIDITY_USDC);

        // Fund user.
        dysn.mint(user, INITIAL_WEALTH_DYSN);
        usdc.mint(user, INITIAL_WEALTH_USDC);

        // Prime pending controller to BasisSpiker; spikeAndDeposit will take and return control.
        factory.setController(address(spiker));
    }

    function _approveUserToSpiker() internal {
        vm.startPrank(user);
        dysn.approve(address(spiker), type(uint).max);
        usdc.approve(address(spiker), type(uint).max);
        vm.stopPrank();
    }

    function testSpikeAndDepositRestoresBasisAndController() public {
        _approveUserToSpiker();
        uint oldBasis = pair.basis();
        uint newBasis = oldBasis * 10;

        uint[] memory dysonDeposits = new uint[](2);
        dysonDeposits[0] = 1e18;
        dysonDeposits[1] = 2e18;
        uint[] memory usdcDeposits = new uint[](1);
        usdcDeposits[0] = 3e6;

        (uint[] memory amounts0, uint[] memory amounts1) = dysonIsToken0
            ? (dysonDeposits, usdcDeposits)
            : (usdcDeposits, dysonDeposits);

        uint total0 = _sum(amounts0);
        uint total1 = _sum(amounts1);

        uint reserve0Before;
        uint reserve1Before;
        (reserve0Before, reserve1Before) = pair.getReserves();

        vm.prank(user);
        spiker.spikeAndDeposit(IPair(address(pair)), newBasis, amounts0, amounts1, total0, total1, user);

        assertEq(pair.basis(), oldBasis, "basis should restore");
        assertEq(factory.pendingController(), address(this), "controller should restore");
        assertEq(pair.noteCount(user), amounts0.length + amounts1.length, "notes minted");

        // Ensure user deposit reached the pair.
        (uint reserve0After, uint reserve1After) = pair.getReserves();
        assertEq(reserve0After, reserve0Before + total0, "DYSN added");
        assertEq(reserve1After, reserve1Before + total1, "USDC added");
    }

    function testSpikeAndDepositRevertsIfNotController() public {
        _approveUserToSpiker();
        // Move pending controller away from BasisSpiker so call will revert.
        factory.setController(user);

        uint[] memory dysonDeposits = new uint[](1);
        dysonDeposits[0] = 1e18;
        uint[] memory usdcDeposits = new uint[](0);
        (uint[] memory amounts0, uint[] memory amounts1) = dysonIsToken0
            ? (dysonDeposits, usdcDeposits)
            : (usdcDeposits, dysonDeposits);
        uint total0 = _sum(amounts0);
        uint total1 = _sum(amounts1);

        assertEq(factory.pendingController(), user, "pending controller should be user");
        uint basis = pair.basis();
        vm.startPrank(user);
        vm.expectRevert(BasisSpiker.NotController.selector);
        spiker.spikeAndDeposit(IPair(address(pair)), basis, amounts0, amounts1, total0, total1, user);
        vm.stopPrank();
    }

    function testSpikeAndDepositRevertsIfNoDeposits() public {
        _approveUserToSpiker();
        uint[] memory empty = new uint[](0);
        assertEq(factory.pendingController(), address(spiker), "pending controller should be spiker");
        uint basis = pair.basis();
        vm.startPrank(user);
        vm.expectRevert(BasisSpiker.NoDeposits.selector);
        spiker.spikeAndDeposit(IPair(address(pair)), basis, empty, empty, 0, 0, user);
        vm.stopPrank();
    }

    function testSpikeAndDepositRevertsIfReceiverZero() public {
        _approveUserToSpiker();
        uint[] memory dysonDeposits = new uint[](1);
        dysonDeposits[0] = 1e18;
        uint[] memory usdcDeposits = new uint[](0);
        (uint[] memory amounts0, uint[] memory amounts1) = dysonIsToken0
            ? (dysonDeposits, usdcDeposits)
            : (usdcDeposits, dysonDeposits);
        uint total0 = _sum(amounts0);
        uint total1 = _sum(amounts1);

        assertEq(factory.pendingController(), address(spiker), "pending controller should be spiker");
        uint basis = pair.basis();
        vm.startPrank(user);
        vm.expectRevert(BasisSpiker.ReceiverZero.selector);
        spiker.spikeAndDeposit(IPair(address(pair)), basis, amounts0, amounts1, total0, total1, address(0));
        vm.stopPrank();
    }

    function testSpikeAndDepositRevertsOnPremiumOverflow() public {
        _approveUserToSpiker();

        uint deposit = INITIAL_WEALTH_DYSN;
        uint[] memory dysonDeposits = new uint[](1);
        dysonDeposits[0] = deposit;
        uint[] memory empty = new uint[](0);
        (uint[] memory amounts0, uint[] memory amounts1) = dysonIsToken0
            ? (dysonDeposits, empty)
            : (empty, dysonDeposits);

        uint total0 = _sum(amounts0);
        uint total1 = _sum(amounts1);

        uint premiumOverflowThreshold = type(uint).max / deposit;
        uint premiumTarget = premiumOverflowThreshold;
        uint newBasis = (premiumTarget * 1e18 + ONE_DAY_PREMIUM_K - 1) / ONE_DAY_PREMIUM_K;

        vm.startPrank(user);
        vm.expectRevert(stdError.arithmeticError);
        spiker.spikeAndDeposit(IPair(address(pair)), newBasis, amounts0, amounts1, total0, total1, user);
        vm.stopPrank();
    }

    function testSpikeAndDepositSetsPairAllowance() public {
        _approveUserToSpiker();
        uint[] memory dysonDeposits = new uint[](1);
        dysonDeposits[0] = 5e18;
        uint[] memory usdcDeposits = new uint[](1);
        usdcDeposits[0] = 10 * 1e6;
        (uint[] memory amounts0, uint[] memory amounts1) = dysonIsToken0
            ? (dysonDeposits, usdcDeposits)
            : (usdcDeposits, dysonDeposits);
        uint total0 = _sum(amounts0);
        uint total1 = _sum(amounts1);

        vm.startPrank(user);
        spiker.spikeAndDeposit(IPair(address(pair)), pair.basis(), amounts0, amounts1, total0, total1, user);
        vm.stopPrank();

        // Deposits should consume the exact allowance we grant for this spike.
        assertEq(dysn.allowance(address(spiker), address(pair)), 0, "DYSN allowance");
        assertEq(usdc.allowance(address(spiker), address(pair)), 0, "USDC allowance");
    }

    function _sum(uint[] memory amounts) private pure returns (uint total) {
        for (uint i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
    }
}
