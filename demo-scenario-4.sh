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
