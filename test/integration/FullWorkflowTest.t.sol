// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {Deployers} from "../utils/Deployers.sol";

import {MEVHook} from "../../src/contracts/MEVHook.sol";

/// @title Complete End-to-End MEVHook Workflow Test
/// @notice Tests the complete MEV alert -> auction -> fee override -> new swap cycle
contract FullWorkflowTest is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    MEVHook hook;
    PoolKey poolKey;
    PoolId poolId;
    address poolAddr;

    Currency currency0;
    Currency currency1;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    // Demo participants
    address alice = makeAddr("alice");
    address bob = makeAddr("bob"); 
    address carol = makeAddr("carol");
    address trader = makeAddr("trader");

    function setUp() public {
        console2.log("Setting up Full Workflow Test...");
        
        // Deploy suite
        deployArtifacts();
        (currency0, currency1) = deployCurrencyPair();

        // Deploy hook with correct flags
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144)
        );
        bytes memory constructorArgs = abi.encode(poolManager, "MEVHook", "1");
        deployCodeTo("contracts/MEVHook.sol:MEVHook", constructorArgs, flags);
        hook = MEVHook(payable(flags));

        // Setup pool
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolAddr = address(uint160(uint256(PoolId.unwrap(poolId))));
        
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Add liquidity
        _addLiquidity();
        
        // Configure hook
        _configureHook();
        
        console2.log("Setup complete!");
        console2.log("Hook address:");
        console2.log(address(hook));
        console2.log("Pool Address:");  
        console2.log(poolAddr);
    }

    function test_fullMEVWorkflow() public {
        console2.log("=== FULL MEV WORKFLOW DEMO ===");
        
        // === PHASE 1: Normal Trading ===
        console2.log("Phase 1: Normal small swap (should NOT trigger MEV alert)");
        
        uint256 smallAmount = 0.1e18; // Small swap
        _performSwap(smallAmount, true);
        
        // === PHASE 2: Large Swap Triggers MEV Alert ===
        console2.log("Phase 2: Large swap triggers MEV alert");
        
        uint256 largeAmount = 10e18; // Large swap that triggers MEV alert
        vm.expectEmit(true, true, false, false);
        emit MEVHook.MEVAlert(poolAddr, largeAmount, block.timestamp, bytes32(0));
        
        _performSwap(largeAmount, true);
        console2.log("MEV Alert emitted for large swap");
        
        // === PHASE 3: Start Fee Auction ===
        console2.log("Phase 3: Starting fee auction");
        
        uint256 minBidWei = 0.1 ether;
        uint32 auctionDuration = 300; // 5 minutes
        
        vm.prank(hook.owner());
        hook.startAuction(poolAddr, minBidWei, auctionDuration);
        
        uint256 auctionId = hook.nextAuctionId(poolAddr) - 1;
        console2.log("Auction started with ID");
        console2.log(auctionId);
        
        // === PHASE 4: Competitive Bidding ===
        console2.log("Phase 4: Competitive bidding");
        
        vm.deal(alice, 2 ether);
        vm.deal(bob, 3 ether);
        vm.deal(carol, 5 ether);
        
        // Alice bids first
        vm.prank(alice);
        hook.placeBid{value: 0.5 ether}(poolAddr, auctionId);
        console2.log("Alice bid 0.5 ETH");
        
        // Bob outbids Alice
        vm.prank(bob);
        hook.placeBid{value: 1.0 ether}(poolAddr, auctionId);
        console2.log("Bob bid 1.0 ETH (Alice refunded)");
        
        // Carol wins with highest bid
        vm.prank(carol);
        hook.placeBid{value: 2.0 ether}(poolAddr, auctionId);
        console2.log("Carol bid 2.0 ETH (Bob refunded)");
        
        // === PHASE 5: Finalize Auction ===
        console2.log("Phase 5: Finalizing auction");
        
        // Fast forward past auction end
        vm.warp(block.timestamp + auctionDuration + 1);
        
        uint256 carolBalanceBefore = carol.balance;
        
        hook.finalizeAuction(poolAddr, auctionId);
        
        uint256 carolBalanceAfter = carol.balance;
        console2.log("Auction finalized");
        console2.log("Carol won back ETH:");
        console2.log((carolBalanceAfter - carolBalanceBefore) / 1e18);
        
        // Check fee override was set
        (uint32 expiresAt, uint16 feeBps) = hook.feeOverrides(poolAddr);
        assertTrue(expiresAt > block.timestamp, "Fee override should be active");
        assertTrue(feeBps > 0, "Fee override should have positive fee");
        console2.log("Fee override active (bps):");
        console2.log(feeBps);
        console2.log("Expires at:");
        console2.log(expiresAt);
        
        // === PHASE 6: Swap with New Fee ===
        console2.log("Phase 6: Testing swap with new fee override");
        
        uint256 beforeSwapAmount = 1e18;
        _performSwap(beforeSwapAmount, false);
        console2.log("Swap executed with dynamic fee!");
        
        // === PHASE 7: Fee Override Expires ===
        console2.log("Phase 7: Wait for fee override to expire");
        
        vm.warp(expiresAt + 1);
        
        // This swap should use default fees
        _performSwap(beforeSwapAmount, true);
        console2.log("Swap executed with default fee (override expired)");
        
        console2.log("=== FULL WORKFLOW COMPLETED SUCCESSFULLY! ===");
    }
    
    function test_EIP712RecommendationWorkflow() public {
        console2.log("Testing EIP-712 Recommendation Workflow");
        
        // Set up oracle
        uint256 oraclePk = 0x12345;
        address oracle = vm.addr(oraclePk);
        vm.prank(hook.owner());
        hook.addAuthorizedOracle(oracle);
        
        // Create recommendation
        uint16 recommendedFee = 200; // 2% fee
        uint256 deadline = block.timestamp + 3600;
        uint256 nonce = hook.nonces(oracle);
        bytes32 metadataHash = keccak256("High MEV risk detected");
        
        // Sign recommendation
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Recommendation(address pool,uint16 recommendedFeeBps,uint256 deadline,uint256 nonce,bytes32 metadataHash)"),
            poolAddr,
            recommendedFee,
            deadline,
            nonce,
            metadataHash
        ));
        
        bytes32 domainSeparator = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("MEVHook")),
            keccak256(bytes("1")),
            block.chainid,
            address(hook)
        ));
        
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oraclePk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        // Apply recommendation
        hook.applyRecommendation(poolAddr, recommendedFee, deadline, signature, metadataHash, nonce);
        
        console2.log("EIP-712 recommendation applied successfully!");
        
        // Verify fee override
        (uint32 expiresAt, uint16 feeBps) = hook.feeOverrides(poolAddr);
        assertEq(feeBps, recommendedFee, "Fee should match recommendation");
        console2.log("Fee override (bps):");
        console2.log(feeBps);
        console2.log("Expires at:");
        console2.log(expiresAt);
    }

    // === HELPER FUNCTIONS ===
    
    function _addLiquidity() internal {
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        uint128 liquidityAmount = 100e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }
    
    function _configureHook() internal {
        vm.startPrank(hook.owner());
        
        // Allow the pool
        hook.setPoolAllowance(poolAddr, true);
        
        // Set MEV threshold low for testing
        hook.setMEVThreshold(poolAddr, 1e18); // 1 token triggers MEV alert
        
        // Set minimum large swap threshold
        hook.setMinLargeSwap(1e18); // 1 token is considered "large"
        
        vm.stopPrank();
    }
    
    function _performSwap(uint256 amountIn, bool zeroForOne) internal {
        BalanceDelta delta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        
        console2.log("Swap executed successfully");
    }
    
    // Allow test contract to receive ETH
    receive() external payable {}
}
