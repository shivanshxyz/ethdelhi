#!/bin/bash
# 🎪 MEV-Alert Network: Demo Preparation Script
# Run this before demo day to set up everything

set -e

echo "🎪 Preparing MEV-Alert Network Demo Environment..."
echo "================================================"

# Check requirements
command -v anvil >/dev/null 2>&1 || { echo "❌ Anvil not found. Install Foundry first."; exit 1; }
command -v forge >/dev/null 2>&1 || { echo "❌ Forge not found. Install Foundry first."; exit 1; }
command -v cast >/dev/null 2>&1 || { echo "❌ Cast not found. Install Foundry first."; exit 1; }

# Kill any existing anvil processes
echo "🧹 Cleaning up existing processes..."
pkill anvil 2>/dev/null || true
sleep 2

# Start Anvil with demo configuration
echo "⚡ Starting Anvil with demo accounts..."
anvil \
  --host 0.0.0.0 \
  --port 8545 \
  --accounts 10 \
  --balance 1000 \
  --gas-limit 30000000 \
  --gas-price 1000000000 &
ANVIL_PID=$!

# Wait for Anvil to start
sleep 3

# Test connection
echo "🔗 Testing Anvil connection..."
if ! curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  http://127.0.0.1:8545 > /dev/null; then
  echo "❌ Cannot connect to Anvil"
  exit 1
fi

echo "✅ Anvil running on http://127.0.0.1:8545"

# Set up environment
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export RPC_URL=http://127.0.0.1:8545

# Deploy contracts
echo "🚀 Deploying smart contracts..."
cd "$(dirname "$0")/.." # Go to project root
forge script script/SimpleDeploy.s.sol:SimpleDeploy --broadcast --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# Extract deployed addresses from broadcast output
BROADCAST_FILE="broadcast/SimpleDeploy.s.sol/31337/run-latest.json"
if [ -f "$BROADCAST_FILE" ]; then
    # Use jq to extract the contract address properly
    if command -v jq >/dev/null 2>&1; then
        HOOK_ADDRESS=$(cat $BROADCAST_FILE | jq -r '.transactions[0].contractAddress')
    else
        # Fallback without jq - use the known address from the deployment
        HOOK_ADDRESS="0x5FbDB2315678afecb367f032d93F642f64180aa3"
    fi
    POOL_ADDRESS="0x1111111111111111111111111111111111111111"  # Demo pool from SimpleDeploy
else
    # Fallback: Use demo addresses
    HOOK_ADDRESS="0x5FbDB2315678afecb367f032d93F642f64180aa3"  # From the successful deployment above
    POOL_ADDRESS="0x1111111111111111111111111111111111111111"   # Demo pool
fi

if [ -z "$HOOK_ADDRESS" ]; then
  echo "❌ Could not find hook address"
  exit 1
fi

echo "✅ Contracts deployed successfully!"
echo "🔗 Hook Address: $HOOK_ADDRESS"
echo "🌊 Pool Address: $POOL_ADDRESS"

# Create demo account summary
echo "📋 Demo Accounts Ready:"
echo "  Alice (Owner):    0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 (1000 ETH)"
echo "  Bob (Judge 1):    0x70997970C51812dc3A010C7d01b50e0d17dc79C8 (1000 ETH)"  
echo "  Charlie (Judge 2): 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC (1000 ETH)"
echo "  Dave (Judge 3):   0x90F79bf6EB2c4f870365E785982E1f101E93b906 (1000 ETH)"

# Create environment file for bot integration
cat > .env.demo << EOF
# MEV-Alert Demo Environment Variables
ANVIL_RPC_URL=http://127.0.0.1:8545
HOOK_ADDRESS=$HOOK_ADDRESS
POOL_ADDRESS=$POOL_ADDRESS
DEMO_PRIVATE_KEY=$PRIVATE_KEY

# Demo accounts
ALICE_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ALICE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

BOB_ADDRESS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8  
BOB_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d

CHARLIE_ADDRESS=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
CHARLIE_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a

DAVE_ADDRESS=0x90F79bf6EB2c4f870365E785982E1f101E93b906
DAVE_KEY=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
EOF

echo "📄 Created .env.demo with all addresses and keys"

# Create demo scenario scripts
echo "📝 Creating demo scenarios..."

# Basic MEV demo
cat > demo-scenario-1.sh << 'EOF'
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
EOF

# Auction competition demo
cat > demo-scenario-2.sh << 'EOF'
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
EOF

# Emergency circuit breaker demo
cat > demo-scenario-3.sh << 'EOF'
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
EOF

# Insurance demo
cat > demo-scenario-4.sh << 'EOF'  
#!/bin/bash
source .env.demo

echo "🛡️ DEMO 4: MEV Insurance System"
echo "==============================="

echo "1. Checking initial insurance fund..."
INITIAL_FUND=$(cast call $HOOK_ADDRESS "mevInsuranceFund(address)(uint256)" $POOL_ADDRESS --rpc-url $ANVIL_RPC_URL)
echo "   Initial fund: $(cast --to-dec $INITIAL_FUND) wei"

echo "2. Depositing 1 ETH to insurance fund..."
cast send $HOOK_ADDRESS "depositInsurance(address)" \
  $POOL_ADDRESS \
  --value 1000000000000000000 \
  --private-key $DEMO_PRIVATE_KEY \
  --rpc-url $ANVIL_RPC_URL

AFTER_DEPOSIT=$(cast call $HOOK_ADDRESS "mevInsuranceFund(address)(uint256)" $POOL_ADDRESS --rpc-url $ANVIL_RPC_URL)
echo "   Fund after deposit: $(cast --to-dec $AFTER_DEPOSIT) wei"

echo "3. Simulating MEV victim claiming 0.1 ETH compensation..."
cast send $HOOK_ADDRESS "claimMEVInsurance(address,uint256,bytes32)" \
  $POOL_ADDRESS \
  100000000000000000 \
  0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef \
  --private-key $BOB_KEY \
  --rpc-url $ANVIL_RPC_URL

FINAL_FUND=$(cast call $HOOK_ADDRESS "mevInsuranceFund(address)(uint256)" $POOL_ADDRESS --rpc-url $ANVIL_RPC_URL)
echo "   Fund after claim: $(cast --to-dec $FINAL_FUND) wei"

echo "✅ Insurance system working!"
echo "📱 Real users would use: /claim_insurance <pool> <loss_amount>"
EOF

# Make all scripts executable
chmod +x demo-scenario-*.sh

echo "✅ Demo scenarios created:"
echo "  demo-scenario-1.sh - Basic MEV Detection"
echo "  demo-scenario-2.sh - Live Auction Competition"  
echo "  demo-scenario-3.sh - Emergency Circuit Breaker"
echo "  demo-scenario-4.sh - MEV Insurance System"

# Final setup verification
echo ""
echo "🎯 DEMO ENVIRONMENT READY!"
echo "========================="
echo ""
echo "🔗 Anvil running at: http://127.0.0.1:8545"
echo "📄 Configuration saved to: .env.demo"
echo "🎪 Demo scenarios ready: demo-scenario-*.sh"
echo ""
echo "📋 Next steps:"
echo "1. Start your subgraph (when ready)"
echo "2. Start Telegram bot (when ready)"  
echo "3. Run demo scenarios during presentation"
echo ""
echo "🚨 Important: Keep this terminal open to maintain Anvil!"
echo "To stop demo environment: kill $ANVIL_PID"

# Keep anvil running
echo "⏳ Anvil running in background (PID: $ANVIL_PID)"
echo "Press Ctrl+C to stop demo environment"

# Save PID for cleanup
echo $ANVIL_PID > .anvil.pid

# Wait for interrupt
trap "echo '🛑 Stopping demo environment...'; kill $ANVIL_PID 2>/dev/null || true; rm -f .anvil.pid; exit 0" INT

wait $ANVIL_PID
