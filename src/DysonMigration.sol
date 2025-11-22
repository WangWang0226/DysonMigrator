// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract DysonMigration {
    address public immutable owner;
    IERC20 public immutable oldToken;
    IERC20 public immutable newToken;
    uint256 public immutable rateNumerator;
    uint256 public immutable rateDenominator;
    uint256 public immutable startTime;
    uint256 public immutable endTime;

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
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    modifier onlyDuringMigration() {
        if (block.timestamp < startTime || block.timestamp > endTime) revert NotActive();
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
            _owner == address(0) ||
            address(_oldToken) == address(0) ||
            address(_newToken) == address(0) ||
            _rateNumerator == 0 ||
            _rateDenominator == 0 ||
            _startTime >= _endTime ||
            address(_oldToken) == address(_newToken)
        ) {
            revert InvalidParams();
        }
        owner = _owner;
        oldToken = _oldToken;
        newToken = _newToken;
        rateNumerator = _rateNumerator;
        rateDenominator = _rateDenominator;
        startTime = _startTime;
        endTime = _endTime;
    }

    function swap(uint256 oldAmount) external nonReentrant onlyDuringMigration {
        if (oldAmount == 0) revert InvalidParams();
        _safeTransferFrom(oldToken, msg.sender, address(this), oldAmount);
        uint256 newAmount = (oldAmount * rateNumerator) / rateDenominator;
        if (newAmount == 0) revert InvalidParams();
        _safeTransfer(newToken, msg.sender, newAmount);
        emit Swapped(msg.sender, oldAmount, newAmount);
    }

    function withdrawOldToken(address to) external onlyOwner {
        if (block.timestamp <= endTime) revert NotEnded();
        if (to == address(0)) revert InvalidRecipient();
        uint256 amount = oldToken.balanceOf(address(this));
        _safeTransfer(oldToken, to, amount);
        emit WithdrawOld(amount);
    }

    function withdrawNewToken(address to) external onlyOwner {
        if (block.timestamp <= endTime) revert NotEnded();
        if (to == address(0)) revert InvalidRecipient();
        uint256 amount = newToken.balanceOf(address(this));
        _safeTransfer(newToken, to, amount);
        emit WithdrawNew(amount);
    }

    function _safeTransfer(IERC20 token, address to, uint256 amount) private {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transfer.selector, to, amount)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert InvalidParams();
    }

    function _safeTransferFrom(IERC20 token, address from, address to, uint256 amount) private {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transferFrom.selector, from, to, amount)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert InvalidParams();
    }
}
