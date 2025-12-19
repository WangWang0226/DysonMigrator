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

    /// @notice Increase basis, push multiple deposits (token0 and/or token1), then restore the previous basis.
    /// @param pair Target pair
    /// @param newBasis Temporary high basis to use for this batch
    /// @param amounts0 Deposit sizes for `deposit0` (token0 -> note)
    /// @param amounts1 Deposit sizes for `deposit1` (token1 -> note)
    /// @param total0 Precomputed sum of `amounts0`
    /// @param total1 Precomputed sum of `amounts1`
    /// @param receiver Owner of the created notes
    function spikeAndDeposit(
        IPair pair,
        uint newBasis,
        uint[] calldata amounts0,
        uint[] calldata amounts1,
        uint total0,
        uint total1,
        address receiver
    ) external {
        if (receiver == address(0)) revert ReceiverZero();
        if (amounts0.length + amounts1.length == 0) revert NoDeposits();
        if (total0 + total1 == 0) revert NoDeposits();

        IFactory factory = IFactory(pair.factory());
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

        uint oldBasis = pair.basis();
        pair.setBasis(newBasis);

        for (uint i = 0; i < amounts0.length; i++) {
            pair.deposit0(receiver, amounts0[i], 0, 1 days);
        }
        for (uint j = 0; j < amounts1.length; j++) {
            pair.deposit1(receiver, amounts1[j], 0, 1 days);
        }

        pair.setBasis(oldBasis);
        factory.setController(originalController);
    }
}
