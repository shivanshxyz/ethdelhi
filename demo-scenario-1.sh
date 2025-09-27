#!/bin/bash
source .env.demo

echo "🔍 DEMO 1: Basic MEV Detection & Alert"
echo "====================================="

echo "Triggering MEV alert for demo pool..."
cast send $HOOK_ADDRESS "triggerMEVAlert(address)" \
  $POOL_ADDRESS \
  --private-key $DEMO_PRIVATE_KEY \
  --rpc-url $ANVIL_RPC_URL

echo "✅ MEV Alert triggered!"
echo "📱 CHECK TELEGRAM: MEV Alert should appear within 60 seconds"
echo "📊 CHECK SUBGRAPH: New MEVAlert event should be indexed"
