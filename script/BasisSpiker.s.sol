// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {BasisSpiker} from "src/BasisSpiker.sol";
import {IPair} from "Dyson-Finance-V1/interface/IPair.sol";
import {IFactory} from "Dyson-Finance-V1/interface/IFactory.sol";
import {IERC20} from "Dyson-Finance-V1/interface/IERC20.sol";

/// @notice Drives the real WETH/USDC pair on zkEVM through the same flow as BasisSpikerFork.t.sol.
/// Steps (all under CONTROLLER_PK which must be the current factory controller and hold enough USDC):
/// 1) Deploy BasisSpiker
/// 2) factory.setController(spiker) to set pending controller
/// 3) Approve USDC to the spiker and call spikeAndDeposit with the same USDC ladder as the fork test
/// 4) factory.becomeController() to restore controller to the original owner after spiker sets pending back
contract BasisSpikerScript is Script {
    uint internal constant ONE_DAY_PREMIUM_K = 20936956903608548; // Pair.getPremium(1 day) multiplier
    
    // Target premium and basis
    uint premiumTarget = 1_000_0e18; // same as fork test
    uint newBasis = 477624329363570007708415; // (premiumTarget * 1e18 + ONE_DAY_PREMIUM_K - 1) / ONE_DAY_PREMIUM_K;

    function run() external {
        uint256 controllerKey = vm.envUint("CONTROLLER_PK");
        address controller = vm.addr(controllerKey);
        address weth = vm.envAddress("WETH");
        address usdc = vm.envAddress("USDC");
        address pairAddr = vm.envAddress("WETH_USDC_PAIR");
        vm.startBroadcast(controllerKey);
        _execute(controller, weth, usdc, pairAddr);
        vm.stopBroadcast();
    }

    /// @dev Core flow extracted for reuse in tests.
    function _execute(address controller, address weth, address usdc, address pairAddr) internal {
        IPair pair = IPair(pairAddr);
        IFactory factory = IFactory(pair.factory());
        address spikerAddr = address(new BasisSpiker());

        // Set pending controller to spiker so spikeAndDeposit can take control.
        factory.setController(spikerAddr);

        _spikeAndDeposit(pair, spikerAddr, usdc, controller);

        // After spikeAndDeposit, pending controller is set back to the original controller.
        factory.becomeController();

        console.log("BasisSpiker deployed at", spikerAddr);
        console.log("Controller restored to", factory.controller());
    }

    function _spikeAndDeposit(IPair pair, address spikerAddr, address usdc, address controller) internal {
        uint[] memory usdcDeposits = _buildUsdcDeposits();
        uint totalUsdc = _sum(usdcDeposits);
        IERC20(usdc).approve(spikerAddr, totalUsdc);
        BasisSpiker(spikerAddr).spikeAndDeposit(pair, newBasis, new uint[](0), usdcDeposits, 0, totalUsdc, controller);
    }

    function _buildUsdcDeposits() internal pure returns (uint[] memory usdcDeposits) {
        uint[30] memory rawValues = [
            uint(1.6384e6), 1.6384e6,       // 2^14
            0.8192e6, 0.8192e6,             // 2^13
            0.4096e6, 0.4096e6,             // 2^12
            0.2048e6, 0.2048e6,             // 2^11
            0.1024e6, 0.1024e6,             // 2^10
            0.0512e6, 0.0512e6,             // 2^9
            0.0256e6, 0.0256e6,             // 2^8
            0.0128e6, 0.0128e6,             // 2^7
            0.0064e6, 0.0064e6,             // 2^6
            0.0032e6, 0.0032e6,             // 2^5
            0.0016e6, 0.0016e6,             // 2^4
            0.0008e6, 0.0008e6,             // 2^3
            0.0004e6, 0.0004e6,             // 2^2
            0.0002e6, 0.0002e6,             // 2^1
            0.0001e6, 0.0001e6              // 2^0
        ];

        usdcDeposits = new uint[](rawValues.length);
        for (uint i = 0; i < rawValues.length; i++) {
            usdcDeposits[i] = rawValues[i];
        }
    }

    function _sum(uint[] memory amounts) internal pure returns (uint total) {
        for (uint i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
    }
}
