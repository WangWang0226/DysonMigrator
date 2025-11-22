// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {DysonMigration, IERC20} from "../src/DysonMigration.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals = 18;

    mapping(address => uint256) internal balances;
    mapping(address => mapping(address => uint256)) internal allowances;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function balanceOf(address account) public view returns (uint256) {
        return balances[account];
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        return allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowances[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        uint256 currentAllowance = allowances[from][msg.sender];
        require(currentAllowance >= amount, "allowance");
        allowances[from][msg.sender] = currentAllowance - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balances[from] >= amount, "balance");
        balances[from] -= amount;
        balances[to] += amount;
    }
}

contract ReenteringToken is MockERC20 {
    DysonMigration public target;
    uint256 public reenterAmount;
    bool internal entered;

    constructor() MockERC20("ReenterOld", "rOLD") {}

    function setReenterTarget(DysonMigration _target, uint256 _reenterAmount) external {
        target = _target;
        reenterAmount = _reenterAmount;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        if (!entered && address(target) != address(0) && reenterAmount > 0) {
            entered = true;
            target.swap(reenterAmount);
            entered = false;
        }
        return true;
    }
}

contract DysonMigrationTest is Test {
    DysonMigration internal migration;
    MockERC20 internal oldToken;
    MockERC20 internal newToken;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");

    uint256 internal startTime;
    uint256 internal endTime;
    uint256 internal rateNumerator = 1;
    uint256 internal rateDenominator = 1;

    function setUp() public {
        startTime = block.timestamp + 100;
        endTime = startTime + 1_000;
        oldToken = new MockERC20("Old", "OLD");
        newToken = new MockERC20("New", "NEW");

        migration = new DysonMigration(
            owner,
            IERC20(address(oldToken)),
            IERC20(address(newToken)),
            rateNumerator,
            rateDenominator,
            startTime,
            endTime
        );

        oldToken.mint(user, 1_000 ether);
        newToken.mint(owner, 2_000 ether);
        vm.prank(owner);
        newToken.transfer(address(migration), 2_000 ether);
    }

    function _approveUser(uint256 amount) internal {
        vm.prank(user);
        oldToken.approve(address(migration), amount);
    }

    function testConstructorRevertsOnInvalidParams() public {
        MockERC20 dummy = new MockERC20("Dummy", "DUM");

        vm.expectRevert(DysonMigration.InvalidParams.selector);
        new DysonMigration(address(0), IERC20(address(oldToken)), IERC20(address(newToken)), 1, 1, startTime, endTime);

        vm.expectRevert(DysonMigration.InvalidParams.selector);
        new DysonMigration(owner, IERC20(address(0)), IERC20(address(newToken)), 1, 1, startTime, endTime);

        vm.expectRevert(DysonMigration.InvalidParams.selector);
        new DysonMigration(owner, IERC20(address(oldToken)), IERC20(address(dummy)), 0, 1, startTime, endTime);

        vm.expectRevert(DysonMigration.InvalidParams.selector);
        new DysonMigration(owner, IERC20(address(dummy)), IERC20(address(newToken)), 1, 0, startTime, endTime);

        vm.expectRevert(DysonMigration.InvalidParams.selector);
        new DysonMigration(owner, IERC20(address(dummy)), IERC20(address(newToken)), 1, 1, endTime, startTime);

        vm.expectRevert(DysonMigration.InvalidParams.selector);
        new DysonMigration(owner, IERC20(address(dummy)), IERC20(address(dummy)), 1, 1, startTime, endTime);
    }

    function testParamsAreImmutable() public view {
        assertEq(migration.owner(), owner);
        assertEq(address(migration.oldToken()), address(oldToken));
        assertEq(address(migration.newToken()), address(newToken));
        assertEq(migration.rateNumerator(), rateNumerator);
        assertEq(migration.rateDenominator(), rateDenominator);
        assertEq(migration.startTime(), startTime);
        assertEq(migration.endTime(), endTime);
    }

    function testSwapSucceedsWithinWindow() public {
        uint256 oldAmount = 100 ether;
        _approveUser(oldAmount);

        vm.warp(startTime + 1);

        vm.expectEmit(true, false, false, true);
        emit DysonMigration.Swapped(user, oldAmount, oldAmount);

        vm.prank(user);
        migration.swap(oldAmount);

        assertEq(oldToken.balanceOf(user), 900 ether);
        assertEq(oldToken.balanceOf(address(migration)), oldAmount);
        assertEq(newToken.balanceOf(user), oldAmount);
        assertEq(newToken.balanceOf(address(migration)), 1_900 ether);
    }

    function testSwapRespectsRate() public {
        uint256 start = block.timestamp + 10;
        uint256 end = start + 500;
        MockERC20 old2 = new MockERC20("Old2", "OLD2");
        MockERC20 new2 = new MockERC20("New2", "NEW2");
        DysonMigration migration2 =
            new DysonMigration(owner, IERC20(address(old2)), IERC20(address(new2)), 2, 1, start, end);

        old2.mint(user, 50 ether);
        new2.mint(owner, 200 ether);
        vm.prank(owner);
        new2.transfer(address(migration2), 200 ether);

        vm.warp(start + 1);
        vm.prank(user);
        old2.approve(address(migration2), 50 ether);

        vm.prank(user);
        migration2.swap(50 ether);

        assertEq(new2.balanceOf(user), 100 ether);
        assertEq(old2.balanceOf(address(migration2)), 50 ether);
    }

    function testSwapRevertsWithZeroAmount() public {
        vm.warp(startTime + 1);
        _approveUser(1);
        vm.expectRevert(DysonMigration.InvalidParams.selector);
        vm.prank(user);
        migration.swap(0);
    }

    function testSwapRevertsBeforeStart() public {
        _approveUser(1 ether);
        vm.warp(startTime - 1);
        vm.expectRevert(DysonMigration.NotActive.selector);
        vm.prank(user);
        migration.swap(1 ether);
    }

    function testSwapRevertsAfterEnd() public {
        _approveUser(1 ether);
        vm.warp(endTime + 1);
        vm.expectRevert(DysonMigration.NotActive.selector);
        vm.prank(user);
        migration.swap(1 ether);
    }

    function testSwapRevertsWithoutNewLiquidity() public {
        uint256 start = block.timestamp + 10;
        uint256 end = start + 100;
        MockERC20 old2 = new MockERC20("Old2", "OLD2");
        MockERC20 new2 = new MockERC20("New2", "NEW2");
        DysonMigration migration2 =
            new DysonMigration(owner, IERC20(address(old2)), IERC20(address(new2)), 1, 1, start, end);

        old2.mint(user, 10 ether);
        vm.prank(user);
        old2.approve(address(migration2), 10 ether);

        vm.warp(start + 1);
        vm.expectRevert(DysonMigration.InvalidParams.selector);
        vm.prank(user);
        migration2.swap(1 ether);
    }

    function testWithdrawOldOnlyAfterEnd() public {
        uint256 swapAmount = 20 ether;
        _approveUser(swapAmount);
        vm.warp(startTime + 1);
        vm.prank(user);
        migration.swap(swapAmount);

        vm.expectRevert(DysonMigration.NotEnded.selector);
        vm.prank(owner);
        migration.withdrawOldToken(owner);

        vm.warp(endTime + 1);
        vm.expectEmit(false, false, false, true);
        emit DysonMigration.WithdrawOld(swapAmount);

        vm.prank(owner);
        migration.withdrawOldToken(owner);

        assertEq(oldToken.balanceOf(owner), swapAmount);
        assertEq(oldToken.balanceOf(address(migration)), 0);
    }

    function testWithdrawOldOnlyOwner() public {
        vm.warp(endTime + 1);
        vm.expectRevert(DysonMigration.NotOwner.selector);
        vm.prank(user);
        migration.withdrawOldToken(user);
    }

    function testWithdrawNewOnlyAfterEnd() public {
        vm.expectRevert(DysonMigration.NotEnded.selector);
        vm.prank(owner);
        migration.withdrawNewToken(owner);

        vm.warp(endTime + 1);
        vm.expectEmit(false, false, false, true);
        emit DysonMigration.WithdrawNew(2_000 ether);

        vm.prank(owner);
        migration.withdrawNewToken(owner);

        assertEq(newToken.balanceOf(owner), 2_000 ether);
        assertEq(newToken.balanceOf(address(migration)), 0);
    }

    function testWithdrawNewOnlyOwner() public {
        vm.warp(endTime + 1);
        vm.expectRevert(DysonMigration.NotOwner.selector);
        vm.prank(user);
        migration.withdrawNewToken(user);
    }

    function testWithdrawRevertsOnZeroRecipient() public {
        vm.warp(endTime + 1);
        vm.expectRevert(DysonMigration.InvalidRecipient.selector);
        vm.prank(owner);
        migration.withdrawOldToken(address(0));

        vm.expectRevert(DysonMigration.InvalidRecipient.selector);
        vm.prank(owner);
        migration.withdrawNewToken(address(0));
    }

    function testReentrancyIsBlockedOnSwap() public {
        ReenteringToken reenterOld = new ReenteringToken();
        MockERC20 freshNew = new MockERC20("Newer", "NEWER");
        uint256 start = block.timestamp + 5;
        uint256 end = start + 200;

        DysonMigration migration2 =
            new DysonMigration(owner, IERC20(address(reenterOld)), IERC20(address(freshNew)), 1, 1, start, end);

        reenterOld.mint(user, 5 ether);
        freshNew.mint(owner, 10 ether);
        vm.prank(owner);
        freshNew.transfer(address(migration2), 10 ether);

        reenterOld.setReenterTarget(migration2, 1 ether);

        vm.warp(start + 1);
        vm.prank(user);
        reenterOld.approve(address(migration2), 5 ether);

        vm.expectRevert();
        vm.prank(user);
        migration2.swap(1 ether);

        // make sure state is consistent after reentrancy attempt
        assertEq(freshNew.balanceOf(user), 0);
        assertEq(reenterOld.balanceOf(user), 5 ether);
        assertEq(freshNew.balanceOf(address(migration2)), 10 ether);
    }
}
