pragma solidity ^0.8.17;

// SPDX-License-Identifier: AGPL-3.0-only

import {IPair} from "Dyson-Finance-V1/interface/IPair.sol";
import {IFactory} from "Dyson-Finance-V1/interface/IFactory.sol";
import {TransferHelper} from "./lib/TransferHelper.sol";
import {IERC20} from "Dyson-Finance-V1/interface/IERC20.sol";

/// @notice Helper that spikes `basis`, batches many one-day deposits, then restores the old basis in one tx.
/// @dev This contract must be the `controller` of the factory used by the pair, otherwise `setBasis` reverts.
contract BasisSpiker {
    using TransferHelper for address;

    error ReceiverZero();
    error NoDeposits();
    error NotController();
    error NotOwner();

    IPair public pair;
    IFactory public factory;
    address public owner;

    constructor(address _pair) {
        pair = IPair(_pair);
        factory = IFactory(pair.factory());
        owner = msg.sender;
    }

    modifier onlyOwner() {
        _onlyOwner();
       _;
   }
           
    function _onlyOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }

    /// @notice Increase basis, push multiple token1 deposits, then restore the previous basis.
    /// @param newController Address to set as pending controller after the spike
    /// @param newBasis Temporary high basis to use for this batch
    /// @param amounts1 Deposit sizes for `deposit1` (token1 -> note)
    /// @param total1 Precomputed sum of `amounts1`
    function spikeAndDeposit(
        address newController,
        uint256 newBasis,
        uint256[] calldata amounts1,
        uint256 total1
    ) external onlyOwner {
        if (amounts1.length == 0) revert NoDeposits();
        if (total1 == 0) revert NoDeposits();

        if (factory.pendingController() != address(this)) revert NotController();
        factory.becomeController();
        address token1 = pair.token1();

        token1.safeTransferFrom(msg.sender, address(this), total1);
        token1.safeApprove(address(pair), total1);

        uint256 oldBasis = pair.basis();
        pair.setBasis(newBasis);

        for (uint256 j = 0; j < amounts1.length; j++) {
            pair.deposit1(address(this), amounts1[j], 0, 1 days);
        }

        pair.setBasis(oldBasis);
        factory.setController(newController);
    }

    /// @notice Withdraw all notes owned by this contract to a receiver.
    /// @dev Attempts every note; any revert/panic on a specific index is skipped and the loop continues.
    function withdrawAll(address to) external onlyOwner {
        if (to == address(0)) revert ReceiverZero();

        uint256 noteCount = pair.noteCount(address(this));
        uint256 total0;
        uint256 total1;

        for (uint256 i = 0; i < noteCount; i++) {
            try pair.withdraw(i, to) returns (uint256 amt0, uint256 amt1) {
                total0 += amt0;
                total1 += amt1;
                _safeReserves();
            } catch {
                continue;
            }
        }

    }

    function _safeReserves() private view returns (uint256 reserve0After, uint256 reserve1After) {
        address token1 = pair.token1();
        address token0 = pair.token0();
        uint balance0 = IERC20(token0).balanceOf(address(pair));
        uint balance1 = IERC20(token1).balanceOf(address(pair));
        try pair.getReserves() returns (uint256 r0, uint256 r1) {
            reserve0After = r0;
            reserve1After = r1;
        } catch {
            reserve0After = balance0;
            reserve1After = balance1;
        }
    }
}
