// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "./interface/IERC20.sol";
import {TransferHelper} from "./lib/TransferHelper.sol";

contract DysonMigration {
    using TransferHelper for address;

    address public immutable OWNER;
    IERC20 public immutable OLD_TOKEN;
    IERC20 public immutable NEW_TOKEN;
    uint256 public immutable RATE_NUMERATOR;
    uint256 public immutable RATE_DENOMINATOR;
    uint256 public immutable START_TIME;
    uint256 public immutable END_TIME;

    event Swapped(address indexed user, uint256 oldAmount, uint256 newAmount);
    event WithdrawOld(uint256 amount);
    event WithdrawNew(uint256 amount);

    error NotOwner();
    error NotActive();
    error NotEnded();
    error InvalidRecipient();
    error InvalidParams();
    error Reentrancy();

    bool private locked;

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    modifier nonReentrant() {
        _nonReentrantEnter();
        _;
        _nonReentrantExit();
    }

    modifier onlyDuringMigration() {
        _onlyDuringMigration();
        _;
    }

    constructor(
        address _owner,
        IERC20 _oldToken,
        IERC20 _newToken,
        uint256 _rateNumerator,
        uint256 _rateDenominator,
        uint256 _startTime,
        uint256 _endTime
    ) {
        if (
            _owner == address(0) || address(_oldToken) == address(0) || address(_newToken) == address(0)
                || _rateNumerator == 0 || _rateDenominator == 0 || _startTime >= _endTime
                || address(_oldToken) == address(_newToken)
        ) {
            revert InvalidParams();
        }
        OWNER = _owner;
        OLD_TOKEN = _oldToken;
        NEW_TOKEN = _newToken;
        RATE_NUMERATOR = _rateNumerator;
        RATE_DENOMINATOR = _rateDenominator;
        START_TIME = _startTime;
        END_TIME = _endTime;
    }

    function swap(uint256 oldAmount) external nonReentrant onlyDuringMigration {
        if (oldAmount == 0) revert InvalidParams();
        address(OLD_TOKEN).safeTransferFrom(msg.sender, address(this), oldAmount);
        uint256 newAmount = (oldAmount * RATE_NUMERATOR) / RATE_DENOMINATOR;
        if (newAmount == 0) revert InvalidParams();
        address(NEW_TOKEN).safeTransfer(msg.sender, newAmount);
        emit Swapped(msg.sender, oldAmount, newAmount);
    }

    function withdrawOldToken(address to) external onlyOwner {
        if (block.timestamp <= END_TIME) revert NotEnded();
        if (to == address(0)) revert InvalidRecipient();
        uint256 amount = OLD_TOKEN.balanceOf(address(this));
        address(OLD_TOKEN).safeTransfer(to, amount);
        emit WithdrawOld(amount);
    }

    function withdrawNewToken(address to) external onlyOwner {
        if (block.timestamp <= END_TIME) revert NotEnded();
        if (to == address(0)) revert InvalidRecipient();
        uint256 amount = NEW_TOKEN.balanceOf(address(this));
        address(NEW_TOKEN).safeTransfer(to, amount);
        emit WithdrawNew(amount);
    }

    function _onlyOwner() internal view {
        if (msg.sender != OWNER) revert NotOwner();
    }

    function _nonReentrantEnter() internal {
        if (locked) revert Reentrancy();
        locked = true;
    }

    function _nonReentrantExit() internal {
        locked = false;
    }

    function _onlyDuringMigration() internal view {
        if (block.timestamp < START_TIME || block.timestamp > END_TIME) revert NotActive();
    }
}
