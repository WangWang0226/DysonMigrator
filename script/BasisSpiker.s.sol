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
    uint256 internal constant ONE_DAY_PREMIUM_K = 20936956903608548; // Pair.getPremium(1 day) multiplier

    // Target premium and basis
    uint256 premiumTarget = 1_000_0e18; // same as fork test
    uint256 newBasis = 477624329363570007708415; // (premiumTarget * 1e18 + ONE_DAY_PREMIUM_K - 1) / ONE_DAY_PREMIUM_K;
    address public lastSpiker;

    function run() external {
        uint256 controllerKey = vm.envUint("CONTROLLER_PK");
        address usdc = vm.envAddress("USDC");
        address pairAddr = vm.envAddress("WETH_USDC_PAIR");
        vm.startBroadcast(controllerKey);
        _execute(usdc, pairAddr);
        vm.stopBroadcast();
    }

    /// @dev Core flow extracted for reuse in tests.
    function _execute(address usdc, address pairAddr) internal {
        IPair pair = IPair(pairAddr);
        IFactory factory = IFactory(pair.factory());
        address spikerAddr = address(new BasisSpiker(address(pair)));
        lastSpiker = spikerAddr;

        // Set pending controller to spiker so spikeAndDeposit can take control.
        factory.setController(spikerAddr);

        _spikeAndDeposit(pair, spikerAddr, usdc);

        // After spikeAndDeposit, pending controller is set back to the original controller.
        factory.becomeController();

        console.log("BasisSpiker deployed at", spikerAddr);
        console.log("Controller restored to", factory.controller());
    }

    function _spikeAndDeposit(IPair pair, address spikerAddr, address usdc) internal {
        uint256[] memory usdcDeposits = _buildUsdcDeposits();
        uint256 totalUsdc = _sum(usdcDeposits);
        IERC20(usdc).approve(spikerAddr, totalUsdc);
        BasisSpiker(spikerAddr).spikeAndDeposit(newBasis, new uint256[](0), usdcDeposits, 0, totalUsdc);
    }

    function _buildUsdcDeposits() internal pure returns (uint256[] memory usdcDeposits) {
        uint256[30] memory rawValues = [
            uint256(1.654784e6),
            1.654784e6, // 2^14*1.01
            0.827392e6,
            0.827392e6, // 2^13*1.01
            0.413696e6,
            0.413696e6, // 2^12*1.01
            0.206848e6,
            0.206848e6, // 2^11*1.01
            0.103424e6,
            0.103424e6, // 2^10*1.01
            0.051712e6,
            0.051712e6, // 2^9*1.01
            0.025856e6,
            0.025856e6, // 2^8*1.01
            0.012928e6,
            0.012928e6, // 2^7*1.01
            0.006464e6,
            0.006464e6, // 2^6*1.01
            0.003232e6,
            0.003232e6, // 2^5*1.01
            0.001616e6,
            0.001616e6, // 2^4*1.01
            0.000808e6,
            0.000808e6, // 2^3*1.01
            0.000404e6,
            0.000404e6, // 2^2*1.01
            0.000202e6,
            0.000202e6, // 2^1*1.01
            0.000101e6,
            0.000101e6 // 2^0*1.01
        ];

        usdcDeposits = new uint256[](rawValues.length);
        for (uint256 i = 0; i < rawValues.length; i++) {
            usdcDeposits[i] = rawValues[i];
        }
    }

    function _sum(uint256[] memory amounts) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
    }
}
