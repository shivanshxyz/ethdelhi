// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

/// @notice Shared configuration between scripts
contract BaseScript is Script {
    IPermit2 immutable permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IPoolManager immutable poolManager;
    IPositionManager immutable positionManager;
    IUniswapV4Router04 immutable swapRouter;
    address immutable deployerAddress;

    /////////////////////////////////////
    // --- Configure These ---
    /////////////////////////////////////
    IERC20 internal constant token0 = IERC20(0x0165878A594ca255338adfa4d48449f69242Eb8F);
    IERC20 internal constant token1 = IERC20(0xa513E6E4b8f2a923D98304ec87F64353C4D5C853);
    
    // Hook address - dynamically configured via environment variable or fallback
    IHooks immutable hookContract;
    /////////////////////////////////////

    Currency immutable currency0;
    Currency immutable currency1;

    constructor() {
        // Fallback to AddressConstants for known networks
        address pm = AddressConstants.getPoolManagerAddress(block.chainid);
        address posm = AddressConstants.getPositionManagerAddress(block.chainid);
        address router = AddressConstants.getV4SwapRouterAddress(block.chainid);

        poolManager = IPoolManager(pm);
        positionManager = IPositionManager(payable(posm));
        swapRouter = IUniswapV4Router04(payable(router));

        // Configure hook address from environment or use fallback
        address hookAddr = _getHookAddress();
        hookContract = IHooks(hookAddr);

        deployerAddress = getDeployer();

        (currency0, currency1) = getCurrencies();

        vm.label(address(token0), "Token0");
        vm.label(address(token1), "Token1");

        vm.label(address(deployerAddress), "Deployer");
        vm.label(address(poolManager), "PoolManager");
        vm.label(address(positionManager), "PositionManager");
        vm.label(address(swapRouter), "SwapRouter");
        vm.label(address(hookContract), "HookContract");
    }

    function getCurrencies() public pure returns (Currency, Currency) {
        require(address(token0) != address(token1));

        if (token0 < token1) {
            return (Currency.wrap(address(token0)), Currency.wrap(address(token1)));
        } else {
            return (Currency.wrap(address(token1)), Currency.wrap(address(token0)));
        }
    }

    function getDeployer() public returns (address) {
        address[] memory wallets = vm.getWallets();

        require(wallets.length > 0, "No wallets found");

        return wallets[0];
    }

    /// @notice Get hook address from environment variable or use fallback
    /// @dev Priority: HOOK_ADDRESS env var > network-specific fallback > test hook address
    /// @return Hook contract address to use
    function _getHookAddress() internal view returns (address) {
        // Try to read from environment variable first
        try vm.envAddress("HOOK_ADDRESS") returns (address envHookAddr) {
            if (envHookAddr != address(0)) {
                return envHookAddr;
            }
        } catch {
            // Environment variable not set, continue to fallbacks
        }

        // Network-specific fallbacks for common testnets
        uint256 chainId = block.chainid;
        
        if (chainId == 11155111) {
            // Sepolia - you can update this with your deployed address
            // return 0x...; // Your Sepolia deployment
        } else if (chainId == 84532) {
            // Base Sepolia - you can update this with your deployed address  
            // return 0x...; // Your Base Sepolia deployment
        } else if (chainId == 421614) {
            // Arbitrum Sepolia - you can update this with your deployed address
            // return 0x...; // Your Arbitrum Sepolia deployment
        }

        // Local testing fallback (Anvil) - use the test hook address from our integration tests
        // This address is from the CREATE2 deployment in our tests with beforeSwap + afterSwap flags
        if (chainId == 31337) { // Anvil/local
            return address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144));
        }

        // Final fallback - this will likely cause issues but prevents compilation errors
        return address(0);
    }
}
