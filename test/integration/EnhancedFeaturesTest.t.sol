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

/// @title Enhanced Features Test
/// @notice Tests time-weighted auctions and emergency circuit breaker with MEV insurance
contract EnhancedFeaturesTest is Test, Deployers {
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

    // Test participants
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address treasury = makeAddr("treasury");
    address protocol = makeAddr("protocol");

    function setUp() public {
        console2.log("Setting up Enhanced Features Test...");
        
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
        
        console2.log("Enhanced Features Test setup complete!");
    }

    function test_timeWeightedAuctions() public {
        console2.log("=== TIME-WEIGHTED AUCTIONS TEST ===");

        // Give bidders ETH
        vm.deal(alice, 5 ether);
        vm.deal(bob, 5 ether);
        vm.deal(carol, 5 ether);

        // Start auction
        vm.prank(hook.owner());
        hook.startAuction(poolAddr, 0.1 ether, 300); // 5 minute auction

        uint256 auctionId = hook.nextAuctionId(poolAddr) - 1;
        console2.log("Started time-weighted auction");

        // Alice bids immediately (gets maximum time bonus)
        vm.prank(alice);
        hook.placeBid{value: 1 ether}(poolAddr, auctionId);
        
        uint256 aliceEffectiveBid = hook.getCurrentEffectiveHighestBid(poolAddr, auctionId);
        console2.log("Alice bid 1 ETH immediately, effective bid:");
        console2.log(aliceEffectiveBid);

        // Wait 150 seconds (50% through auction)
        vm.warp(block.timestamp + 150);

        // Bob needs to bid more to overcome Alice's time advantage
        // Alice's 1 ETH got ~1.2 ETH effective, Bob needs higher raw bid
        vm.prank(bob);
        hook.placeBid{value: 1.5 ether}(poolAddr, auctionId);

        uint256 bobEffectiveBid = hook.getCurrentEffectiveHighestBid(poolAddr, auctionId);
        console2.log("Bob bid 1.5 ETH at 50% through auction, effective bid:");
        console2.log(bobEffectiveBid);

        // Bob's higher raw bid should beat Alice's time-weighted bid
        assertTrue(bobEffectiveBid > aliceEffectiveBid, "Bob's higher bid should overcome time disadvantage");

        // Wait near end of auction
        vm.warp(block.timestamp + 140); // 290 seconds total (near end)

        // Carol needs to bid even more at the end (minimal time bonus)
        vm.prank(carol);
        hook.placeBid{value: 1.8 ether}(poolAddr, auctionId);

        uint256 carolEffectiveBid = hook.getCurrentEffectiveHighestBid(poolAddr, auctionId);
        console2.log("Carol bid 1.8 ETH near end, effective bid:");
        console2.log(carolEffectiveBid);

        // Finalize auction
        vm.warp(block.timestamp + 20); // Past auction end
        hook.finalizeAuction(poolAddr, auctionId);

        // Carol should have won despite Alice having the highest effective bid initially
        (,, , address winner, ,, ) = hook.auctions(poolAddr, auctionId);
        assertEq(winner, carol, "Carol should have won with late high bid");

        console2.log("Time-weighted auction test completed successfully!");
    }

    function test_emergencyCircuitBreaker() public {
        console2.log("=== EMERGENCY CIRCUIT BREAKER TEST ===");

        // Normal operations should work
        vm.deal(alice, 2 ether);
        
        // Allow non-owners to start auctions for testing
        vm.prank(hook.owner());
        hook.setAuctionsOwnerOnly(false);
        
        // Start auction normally
        vm.prank(alice); // Alice starts auction
        hook.startAuction(poolAddr, 0.1 ether, 300);
        uint256 auctionId = hook.nextAuctionId(poolAddr) - 1;

        // Place bid normally
        vm.prank(alice);
        hook.placeBid{value: 0.5 ether}(poolAddr, auctionId);
        console2.log("Normal operations work before emergency");

        // Emergency pause
        vm.prank(hook.owner());
        hook.emergencyPause("Critical MEV vulnerability detected");

        assertTrue(hook.emergencyPaused(), "Should be in emergency state");
        assertEq(hook.pauseReason(), "Critical MEV vulnerability detected", "Reason should be stored");

        // Operations should be blocked for non-owners
        vm.expectRevert("EMERGENCY_PAUSED");
        vm.prank(alice); // Non-owner should be blocked
        hook.startAuction(poolAddr, 0.1 ether, 300);

        vm.expectRevert("EMERGENCY_PAUSED");
        vm.prank(alice);
        hook.placeBid{value: 0.5 ether}(poolAddr, auctionId);

        // Move time past auction end and try to finalize as non-owner (should be blocked)
        vm.warp(block.timestamp + 400);
        vm.expectRevert("EMERGENCY_PAUSED");
        vm.prank(alice); // Non-owner should be blocked
        hook.finalizeAuction(poolAddr, auctionId);

        console2.log("All operations correctly blocked during emergency");

        // Owner can still operate admin functions during emergency
        vm.prank(hook.owner());
        hook.setMEVThreshold(poolAddr, 2e18); // This should work

        // Unpause
        vm.prank(hook.owner());
        hook.emergencyUnpause();

        assertFalse(hook.emergencyPaused(), "Should no longer be paused");

        // Operations should work again
        vm.prank(hook.owner());
        hook.startAuction(poolAddr, 0.1 ether, 300);

        console2.log("Emergency circuit breaker test completed successfully!");
    }

    function test_mevInsuranceSystem() public {
        console2.log("=== MEV INSURANCE SYSTEM TEST ===");

        vm.deal(alice, 5 ether);
        vm.deal(bob, 5 ether);

        // Initially no insurance fund
        assertEq(hook.mevInsuranceFund(poolAddr), 0, "No initial insurance fund");

        // Alice deposits into insurance fund
        vm.prank(alice);
        hook.depositInsurance{value: 2 ether}(poolAddr);

        assertEq(hook.mevInsuranceFund(poolAddr), 2 ether, "Insurance fund should have 2 ETH");
        console2.log("Alice deposited 2 ETH into insurance fund");

        // Run an auction to automatically fund insurance
        vm.prank(hook.owner());
        hook.startAuction(poolAddr, 0.1 ether, 300);
        uint256 auctionId = hook.nextAuctionId(poolAddr) - 1;

        vm.prank(bob);
        hook.placeBid{value: 1 ether}(poolAddr, auctionId);

        vm.warp(block.timestamp + 301);
        hook.finalizeAuction(poolAddr, auctionId);

        // Insurance fund should have increased (10% of 1 ETH = 0.1 ETH)
        uint256 fundAfterAuction = hook.mevInsuranceFund(poolAddr);
        console2.log("Insurance fund after auction:");
        console2.log(fundAfterAuction);
        assertTrue(fundAfterAuction > 2 ether, "Fund should have grown from auction proceeds");

        // Alice claims MEV insurance (simulating MEV loss)
        uint256 aliceBalanceBefore = alice.balance;
        bytes32 evidence = keccak256("MEV attack evidence hash");
        uint256 lossAmount = 0.5 ether;

        vm.prank(alice);
        hook.claimMEVInsurance(poolAddr, lossAmount, evidence);

        uint256 aliceBalanceAfter = alice.balance;
        uint256 compensation = aliceBalanceAfter - aliceBalanceBefore;

        console2.log("Alice claimed compensation:");
        console2.log(compensation);

        // Should get 50% of loss (maxCompensationPercent = 50%)
        uint256 expectedCompensation = (lossAmount * 50) / 100;
        assertEq(compensation, expectedCompensation, "Should receive 50% compensation");

        // Insurance fund should have decreased
        uint256 fundAfterClaim = hook.mevInsuranceFund(poolAddr);
        assertEq(fundAfterClaim, fundAfterAuction - compensation, "Fund should decrease by compensation amount");

        console2.log("MEV insurance system test completed successfully!");
    }

    function test_enhancedAuctionPayouts() public {
        console2.log("=== ENHANCED AUCTION PAYOUTS TEST ===");

        // Set up custom treasury and protocol addresses
        vm.prank(hook.owner());
        hook.setTreasury(treasury);
        vm.prank(hook.owner());
        hook.setProtocol(protocol);

        vm.deal(alice, 2 ether);

        uint256 treasuryBefore = treasury.balance;
        uint256 protocolBefore = protocol.balance;
        uint256 insuranceBefore = hook.mevInsuranceFund(poolAddr);

        // Start and run auction
        vm.prank(hook.owner());
        hook.startAuction(poolAddr, 0.1 ether, 300);
        uint256 auctionId = hook.nextAuctionId(poolAddr) - 1;

        uint256 bidAmount = 1 ether;
        vm.prank(alice);
        hook.placeBid{value: bidAmount}(poolAddr, auctionId);

        uint256 aliceBefore = alice.balance;

        vm.warp(block.timestamp + 301);
        hook.finalizeAuction(poolAddr, auctionId);

        uint256 aliceAfter = alice.balance;
        uint256 treasuryAfter = treasury.balance;
        uint256 protocolAfter = protocol.balance;
        uint256 insuranceAfter = hook.mevInsuranceFund(poolAddr);

        // Check enhanced distribution: 45% to winner, 35% to treasury, 10% to protocol, 10% to insurance
        uint256 aliceGot = aliceAfter - aliceBefore;
        uint256 treasuryGot = treasuryAfter - treasuryBefore;
        uint256 protocolGot = protocolAfter - protocolBefore;
        uint256 insuranceGot = insuranceAfter - insuranceBefore;

        assertEq(aliceGot, (bidAmount * 45) / 100, "Alice should get 45%");
        assertEq(treasuryGot, (bidAmount * 35) / 100, "Treasury should get 35%");
        assertEq(protocolGot, (bidAmount * 10) / 100, "Protocol should get 10%");
        assertEq(insuranceGot, (bidAmount * 10) / 100, "Insurance should get 10%");

        console2.log("Enhanced auction payouts test completed successfully!");
    }

    function test_adminConfigurationFunctions() public {
        console2.log("=== ADMIN CONFIGURATION TEST ===");

        // Test time bonus configuration
        vm.prank(hook.owner());
        hook.setMaxTimeBonusPercent(30);
        assertEq(hook.maxTimeBonusPercent(), 30, "Time bonus should be updated");

        // Test insurance configuration
        vm.prank(hook.owner());
        hook.setMaxCompensationPercent(75);
        assertEq(hook.maxCompensationPercent(), 75, "Compensation percent should be updated");

        vm.prank(hook.owner());
        hook.setMinInsurableLoss(0.01 ether);
        assertEq(hook.minInsurableLoss(), 0.01 ether, "Min insurable loss should be updated");

        // Test that non-owners can't configure
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        hook.setMaxTimeBonusPercent(50);

        console2.log("Admin configuration test completed successfully!");
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
        hook.setMEVThreshold(poolAddr, 1e18);
        
        // Set minimum large swap threshold
        hook.setMinLargeSwap(1e18);
        
        vm.stopPrank();
    }
    
    // Allow test contract to receive ETH
    receive() external payable {}
}
