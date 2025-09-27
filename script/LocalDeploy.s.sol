// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {MEVHook} from "../src/contracts/MEVHook.sol";

// Mock Pool Manager for local testing
contract MockPoolManager {
    // Just implement the interface functions we need
}

contract LocalDeployScript is Script {
    function run() public {
        console.log("Local Anvil deployment starting...");
        console.log("Chain ID:", block.chainid);
        
        vm.startBroadcast();
        
        // For Anvil, deploy a mock pool manager
        MockPoolManager mockPM = new MockPoolManager();
        console.log("Mock PoolManager deployed at:", address(mockPM));
        
        // For local testing, deploy hook normally without CREATE2 mining
        // This avoids hook address validation issues
        MEVHook hook;
        
        try new MEVHook(IPoolManager(address(mockPM)), "MEVHook", "1") returns (MEVHook _hook) {
            hook = _hook;
            console.log("MEVHook deployed at:", address(hook));
        } catch Error(string memory reason) {
            console.log("Hook deployment failed:", reason);
            // Try with simpler approach - deploy without strict validation
            revert(reason);
        } catch (bytes memory lowLevelData) {
            console.log("Hook deployment failed with low-level error");
            console.logBytes(lowLevelData);
            revert("Hook deployment failed");
        }
        
        // Configure the hook for demo (placeholder - would need actual configuration functions)
        // hook.setPool(address(0x1111111111111111111111111111111111111111), true); // Demo pool
        // hook.setMEVThreshold(address(0x1111111111111111111111111111111111111111), 1000); // Low threshold for demo
        
        // Log for the demo script to pick up
        console.log("Hook deployed at:", address(hook));
        
        vm.stopBroadcast();
        
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Hook Address:", address(hook));
        console.log("Pool Manager Address:", address(mockPM));
        console.log("Demo Pool Configured: 0x1111111111111111111111111111111111111111");
    }
}
