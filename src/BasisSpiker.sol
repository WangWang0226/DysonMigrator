pragma solidity ^0.8.17;

// SPDX-License-Identifier: AGPL-3.0-only

import {IPair} from "Dyson-Finance-V1/interface/IPair.sol";
import {IFactory} from "Dyson-Finance-V1/interface/IFactory.sol";
import {TransferHelper} from "./lib/TransferHelper.sol";

/// @notice Helper that spikes `basis`, batches many one-day deposits, then restores the old basis in one tx.
/// @dev This contract must be the `controller` of the factory used by the pair, otherwise `setBasis` reverts.
contract BasisSpiker {
    using TransferHelper for address;

    error ReceiverZero();
    error NoDeposits();
    error NotController();
    error NotOwner();

    IPair public immutable pair;
    IFactory public immutable factory;
    address public immutable owner;

    constructor(address _pair) {
        pair = IPair(_pair);
        factory = IFactory(pair.factory());
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Increase basis, push multiple deposits (token0 and/or token1), then restore the previous basis.
    /// @param newBasis Temporary high basis to use for this batch
    /// @param amounts0 Deposit sizes for `deposit0` (token0 -> note)
    /// @param amounts1 Deposit sizes for `deposit1` (token1 -> note)
    /// @param total0 Precomputed sum of `amounts0`
    /// @param total1 Precomputed sum of `amounts1`
    function spikeAndDeposit(
        uint256 newBasis,
        uint256[] calldata amounts0,
        uint256[] calldata amounts1,
        uint256 total0,
        uint256 total1
    ) external onlyOwner {
        if (amounts0.length + amounts1.length == 0) revert NoDeposits();
        if (total0 + total1 == 0) revert NoDeposits();

        address originalController = factory.controller();
        if (factory.pendingController() != address(this)) revert NotController();
        factory.becomeController();
        address token0 = pair.token0();
        address token1 = pair.token1();

        if (total0 > 0) {
            token0.safeTransferFrom(msg.sender, address(this), total0);
            token0.safeApprove(address(pair), total0);
        }
        if (total1 > 0) {
            token1.safeTransferFrom(msg.sender, address(this), total1);
            token1.safeApprove(address(pair), total1);
        }

        uint256 oldBasis = pair.basis();
        pair.setBasis(newBasis);

        for (uint256 i = 0; i < amounts0.length; i++) {
            pair.deposit0(address(this), amounts0[i], 0, 1 days);
        }
        for (uint256 j = 0; j < amounts1.length; j++) {
            pair.deposit1(address(this), amounts1[j], 0, 1 days);
        }

        pair.setBasis(oldBasis);
        factory.setController(originalController);
    }

    /// @notice Withdraw all notes owned by this contract to a receiver.
    /// @dev Stops at first failed withdraw; still forwards whatever was successfully withdrawn.
    function withdrawAll(address receiver) external onlyOwner {
        if (receiver == address(0)) revert ReceiverZero();

        uint256 noteCount = pair.noteCount(address(this));
        address token0 = pair.token0();
        address token1 = pair.token1();
        uint256 total0;
        uint256 total1;

        for (uint256 i = 0; i < noteCount; i++) {
            try pair.withdraw(i, address(this)) returns (uint256 amt0, uint256 amt1) {
                total0 += amt0;
                total1 += amt1;
            } catch {
                break;
            }
        }

        if (total0 > 0) token0.safeTransfer(receiver, total0);
        if (total1 > 0) token1.safeTransfer(receiver, total1);
    }
}
