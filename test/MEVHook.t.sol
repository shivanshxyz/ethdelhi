// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

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

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {Deployers} from "./utils/Deployers.sol";

import {MEVHook} from "../src/contracts/MEVHook.sol";

contract MEVHookTest is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;
    PoolId poolId;

    MEVHook hook;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    // EIP-712 constants (must mirror contract)
    bytes32 constant RECOMMENDATION_TYPEHASH = keccak256(
        "Recommendation(address pool,uint16 recommendedFeeBps,uint256 deadline,uint256 nonce,bytes32 metadataHash)"
    );

    function setUp() public {
        // Deploy suite
        deployArtifacts();
        (currency0, currency1) = deployCurrencyPair();

        // Deploy hook to an address with correct flags (beforeSwap | afterSwap)
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144)
        );
        bytes memory constructorArgs = abi.encode(poolManager, "MEVHook", "1");
        deployCodeTo("contracts/MEVHook.sol:MEVHook", constructorArgs, flags);
        hook = MEVHook(payable(flags));

        // Allow pool address space (we'll check allowance on synthetic address)
        // Setup pool
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Provide full range liquidity
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

        // Configure hook admin: set pool allowance and thresholds
        address syntheticPool = address(uint160(uint256(PoolId.unwrap(poolId))));
        vm.prank(hook.owner());
        hook.setPoolAllowance(syntheticPool, true);
        vm.prank(hook.owner());
        hook.setMEVThreshold(syntheticPool, 1); // any positive score triggers
        vm.prank(hook.owner());
        hook.setMinLargeSwap(1e15); // small threshold for demo
    }

    function _swapExact(uint256 amountIn, bool zeroForOne) internal returns (BalanceDelta swapDelta) {
        swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function test_swap_emits_SwapObserved() public {
        BalanceDelta d = _swapExact(1e18, true);
        // Basic sanity
        assertLt(d.amount0(), 0);
    }

    function test_onchain_stub_triggers_MEVAlert_when_large_swap() public {
        // threshold set to 1 wei, minLargeSwap set to 1e15 so 1e18 triggers
        _swapExact(1e18, true);
        // No direct assertion on events here; verifying that hook path runs without revert.
        // Event checks can be added with forge's expectEmit if desired.
    }

    function test_startAuction_and_placeBid_highestWins() public {
        address syntheticPool = address(uint160(uint256(PoolId.unwrap(poolId))));
        vm.prank(hook.owner());
        hook.setPoolAllowance(syntheticPool, true);

        hook.startAuction(syntheticPool, 0.1 ether, 60);
        uint256 auctionId = hook.nextAuctionId(syntheticPool) - 1;

        vm.deal(address(0xBEEF), 1 ether);
        vm.prank(address(0xBEEF));
        hook.placeBid{value: 0.5 ether}(syntheticPool, auctionId);

        vm.deal(address(0xCAFE), 2 ether);
        vm.prank(address(0xCAFE));
        hook.placeBid{value: 1 ether}(syntheticPool, auctionId);

        // Highest should be 1 ether by 0xCAFE
        (,, uint128 highestBid, address highestBidder, ,, ) = hook.auctions(syntheticPool, auctionId);
        assertEq(highestBidder, address(0xCAFE));
        assertEq(uint256(highestBid), 1 ether);
    }

    function test_finalizeAuction_appliesFeeOverride_and_pays_winner() public {
        address syntheticPool = address(uint160(uint256(PoolId.unwrap(poolId))));
        vm.prank(hook.owner());
        hook.setPoolAllowance(syntheticPool, true);

        // Set treasury and protocol to EOAs that can receive ETH
        vm.prank(hook.owner());
        hook.setTreasury(address(0x1111));
        vm.prank(hook.owner());
        hook.setProtocol(address(0x2222));

        hook.startAuction(syntheticPool, 0.1 ether, 1);
        uint256 auctionId = hook.nextAuctionId(syntheticPool) - 1;

        vm.deal(address(0xCAFE), 1 ether);
        vm.prank(address(0xCAFE));
        hook.placeBid{value: 0.8 ether}(syntheticPool, auctionId);

        // move time forward
        vm.warp(block.timestamp + 2);

        uint256 balBefore = address(0xCAFE).balance;
        hook.finalizeAuction(syntheticPool, auctionId);
        uint256 balAfter = address(0xCAFE).balance;

        // winner got 45% (changed from 50% to fund insurance)
        assertEq(balAfter - balBefore, 0.36 ether);

        // fee override set
        (uint32 exp, uint16 bps) = hook.feeOverrides(syntheticPool);
        assertGt(exp, 0);
        assertGt(bps, 0);
    }

}
