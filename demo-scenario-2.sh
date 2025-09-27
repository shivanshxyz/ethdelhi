#!/bin/bash
source .env.demo

echo "🏆 DEMO 2: Live Auction Competition"  
echo "=================================="

echo "Starting auction with 5-minute duration..."
cast send $HOOK_ADDRESS "startAuction(address,uint256,uint32)" \
  $POOL_ADDRESS \
  100000000000000000 \
  300 \
  --private-key $DEMO_PRIVATE_KEY \
  --rpc-url $ANVIL_RPC_URL

echo "🎪 AUCTION STARTED!"
echo ""
echo "📱 JUDGES: Use these Telegram commands:"
echo "  /auctions - See active auctions"
echo "  /bid $POOL_ADDRESS 1 0.5 - Bid 0.5 ETH"
echo "  /auction $POOL_ADDRESS 1 - See auction details"
echo ""
echo "⏱️  Demo Timeline:"
echo "  • Minute 1-2: Early bids get 20% time bonus"
echo "  • Minute 3-4: Mid bids get 10% time bonus"  
echo "  • Minute 5: Final bids, no bonus"
echo ""
echo "💡 Strategy: Bid early for time advantage!"

# Wait for auction to end
echo "⏰ Waiting for auction to complete..."
sleep 300

echo "🏁 Finalizing auction..."
cast send $HOOK_ADDRESS "finalizeAuction(address,uint256)" \
  $POOL_ADDRESS \
  1 \
  --private-key $DEMO_PRIVATE_KEY \
  --rpc-url $ANVIL_RPC_URL

echo "🎉 Auction completed!"
echo "📱 CHECK TELEGRAM: Winner should be notified"
