#!/bin/bash
source .env.demo

echo "🚨 DEMO 3: Emergency Circuit Breaker"
echo "===================================="

echo "Triggering emergency pause..."
cast send $HOOK_ADDRESS "emergencyPause(string)" \
  "Demo: Simulating critical security issue" \
  --private-key $DEMO_PRIVATE_KEY \
  --rpc-url $ANVIL_RPC_URL

echo "🚨 SYSTEM PAUSED! All operations blocked except admin functions."
echo ""
echo "Testing restrictions..."

echo "❌ Attempting to start auction (should fail):"
cast send $HOOK_ADDRESS "startAuction(address,uint256,uint32)" \
  $POOL_ADDRESS \
  100000000000000000 \
  300 \
  --private-key $BOB_KEY \
  --rpc-url $ANVIL_RPC_URL || echo "✅ Correctly blocked!"

echo "❌ Attempting swap (should fail):"
forge script script/03_Swap.s.sol \
  --broadcast \
  --rpc-url $ANVIL_RPC_URL \
  --private-key $BOB_KEY || echo "✅ Correctly blocked!"

sleep 3

echo "🔧 Admin resuming operations..."
cast send $HOOK_ADDRESS "emergencyUnpause()" \
  --private-key $DEMO_PRIVATE_KEY \
  --rpc-url $ANVIL_RPC_URL

echo "🟢 System resumed! Normal operations restored."

# Test that operations work again
echo "✅ Testing normal operations restored:"
cast send $HOOK_ADDRESS "startAuction(address,uint256,uint32)" \
  $POOL_ADDRESS \
  100000000000000000 \
  60 \
  --private-key $DEMO_PRIVATE_KEY \
  --rpc-url $ANVIL_RPC_URL

echo "✅ Auction started successfully - system fully operational!"
