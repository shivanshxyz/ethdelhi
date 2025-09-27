# 🤖 MEV-Alert Telegram Bot: Viem Integration Specification

**Project**: MEV-Alert Hook with Telegram Bot  
**Data Source**: Direct blockchain queries via Viem (no subgraph needed)  
**Purpose**: Real-time MEV alerts and auction participation via Telegram  

---

## 📋 **Overview**

Instead of using The Graph subgraph, we'll use **Viem** to directly query the blockchain for events and contract state. This is perfect for local demo and much simpler to set up.

### **Architecture:**
```
Smart Contract → Viem Event Listeners → Telegram Bot → Users
     ↓                    ↓                 ↓
  Emit Events    Real-time Monitoring   Send Alerts/Handle Bids
```

### **User Flow:**
1. 🔍 Hook detects MEV → Emits `MEVAlert` event
2. 🤖 Bot's Viem listener catches event instantly  
3. 📱 Bot sends Telegram alert to subscribers
4. 💰 Users bid via Telegram → Bot submits transactions
5. 🏆 Auction ends → Bot notifies winner

---

## 🔧 **Technical Setup**

### **Contract Details (Local Demo)**
```typescript
const HOOK_ADDRESS = "0x5fbdb2315678afecb367f032d93f642f64180aa3" // From demo deployment
const DEMO_POOL = "0x1111111111111111111111111111111111111111"
const RPC_URL = "http://127.0.0.1:8545" // Local Anvil
const CHAIN_ID = 31337
```

### **Required Dependencies**
```json
{
  "dependencies": {
    "viem": "^1.19.0",
    "node-telegram-bot-api": "^0.61.0",
    "dotenv": "^16.0.3",
    "sqlite3": "^5.1.6"
  }
}
```

---

## 📊 **Viem Event Monitoring**

### **1. Contract ABI (Essential Functions)**
```typescript
const HOOK_ABI = [
  // Events to monitor
  {
    type: 'event',
    name: 'MEVAlert',
    inputs: [
      { name: 'pool', type: 'address', indexed: true },
      { name: 'mevScore', type: 'uint256' },
      { name: 'timestamp', type: 'uint256' },
      { name: 'metadataHash', type: 'bytes32' }
    ]
  },
  {
    type: 'event', 
    name: 'AuctionStarted',
    inputs: [
      { name: 'pool', type: 'address', indexed: true },
      { name: 'auctionId', type: 'uint256', indexed: true },
      { name: 'minBid', type: 'uint256' },
      { name: 'startTime', type: 'uint256' },
      { name: 'endTime', type: 'uint256' }
    ]
  },
  {
    type: 'event',
    name: 'BidPlaced', 
    inputs: [
      { name: 'pool', type: 'address', indexed: true },
      { name: 'auctionId', type: 'uint256', indexed: true },
      { name: 'bidder', type: 'address' },
      { name: 'bidAmount', type: 'uint256' }
    ]
  },
  {
    type: 'event',
    name: 'AuctionSettled',
    inputs: [
      { name: 'pool', type: 'address', indexed: true },
      { name: 'auctionId', type: 'uint256', indexed: true },
      { name: 'winner', type: 'address' },
      { name: 'finalFeeBps', type: 'uint256' }
    ]
  },
  {
    type: 'event',
    name: 'EmergencyPaused',
    inputs: [
      { name: 'timestamp', type: 'uint256' },
      { name: 'reason', type: 'string' }
    ]
  },
  {
    type: 'event',
    name: 'InsuranceDeposit',
    inputs: [
      { name: 'pool', type: 'address', indexed: true },
      { name: 'amount', type: 'uint256' },
      { name: 'newTotal', type: 'uint256' }
    ]
  },
  // Read functions
  {
    type: 'function',
    name: 'auctions',
    inputs: [
      { name: 'pool', type: 'address' },
      { name: 'auctionId', type: 'uint256' }
    ],
    outputs: [
      { name: 'start', type: 'uint32' },
      { name: 'end', type: 'uint32' },
      { name: 'highestBid', type: 'uint128' },
      { name: 'highestBidder', type: 'address' },
      { name: 'settled', type: 'bool' }
    ],
    stateMutability: 'view'
  },
  {
    type: 'function',
    name: 'nextAuctionId',
    inputs: [{ name: 'pool', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view'
  },
  {
    type: 'function',
    name: 'mevInsuranceFund',
    inputs: [{ name: 'pool', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view'
  },
  // Write functions (for bidding)
  {
    type: 'function',
    name: 'placeBid',
    inputs: [
      { name: 'pool', type: 'address' },
      { name: 'auctionId', type: 'uint256' }
    ],
    stateMutability: 'payable'
  },
  {
    type: 'function',
    name: 'startAuction',
    inputs: [
      { name: 'pool', type: 'address' },
      { name: 'minBidWei', type: 'uint256' },
      { name: 'durationSecs', type: 'uint32' }
    ],
    stateMutability: 'nonpayable'
  }
] as const
```

### **2. Real-time Event Monitoring Setup**
```typescript
import { createPublicClient, createWalletClient, http, parseAbiItem, formatEther } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { foundry } from 'viem/chains'

// Setup clients
const publicClient = createPublicClient({
  chain: foundry,
  transport: http('http://127.0.0.1:8545')
})

// For sending transactions (bidding)
const walletClient = createWalletClient({
  chain: foundry,
  transport: http('http://127.0.0.1:8545')
})

// Event listeners
class BlockchainMonitor {
  private unsubscribeFunctions: (() => void)[] = []
  
  async startMonitoring() {
    console.log('🔍 Starting blockchain event monitoring...')
    
    // Monitor MEV Alerts
    const unsubscribeMEVAlerts = publicClient.watchContractEvent({
      address: HOOK_ADDRESS,
      abi: HOOK_ABI,
      eventName: 'MEVAlert',
      onLogs: (logs) => {
        logs.forEach(async (log) => {
          const { pool, mevScore, timestamp } = log.args
          console.log(`🚨 MEV Alert: Pool ${pool}, Score ${mevScore}`)
          
          await this.handleMEVAlert({
            pool: pool!,
            mevScore: mevScore!,
            timestamp: timestamp!,
            blockNumber: log.blockNumber,
            txHash: log.transactionHash
          })
        })
      }
    })
    
    // Monitor Auction Events  
    const unsubscribeAuctions = publicClient.watchContractEvent({
      address: HOOK_ADDRESS,
      abi: HOOK_ABI,
      eventName: 'AuctionStarted',
      onLogs: (logs) => {
        logs.forEach(async (log) => {
          const { pool, auctionId, minBid, startTime, endTime } = log.args
          console.log(`🏆 Auction Started: Pool ${pool}, ID ${auctionId}`)
          
          await this.handleAuctionStarted({
            pool: pool!,
            auctionId: auctionId!,
            minBid: minBid!,
            startTime: startTime!,
            endTime: endTime!,
            blockNumber: log.blockNumber,
            txHash: log.transactionHash
          })
        })
      }
    })
    
    // Monitor Bids
    const unsubscribeBids = publicClient.watchContractEvent({
      address: HOOK_ADDRESS,
      abi: HOOK_ABI, 
      eventName: 'BidPlaced',
      onLogs: (logs) => {
        logs.forEach(async (log) => {
          const { pool, auctionId, bidder, bidAmount } = log.args
          console.log(`💰 Bid Placed: ${formatEther(bidAmount!)} ETH by ${bidder}`)
          
          await this.handleBidPlaced({
            pool: pool!,
            auctionId: auctionId!,
            bidder: bidder!,
            bidAmount: bidAmount!,
            blockNumber: log.blockNumber,
            txHash: log.transactionHash
          })
        })
      }
    })
    
    this.unsubscribeFunctions = [unsubscribeMEVAlerts, unsubscribeAuctions, unsubscribeBids]
  }
  
  async stopMonitoring() {
    this.unsubscribeFunctions.forEach(unsub => unsub())
    console.log('⏹️ Stopped blockchain monitoring')
  }
}
```

### **3. Contract State Queries**
```typescript
class ContractQueries {
  
  // Get auction details
  async getAuction(pool: string, auctionId: bigint) {
    try {
      const result = await publicClient.readContract({
        address: HOOK_ADDRESS,
        abi: HOOK_ABI,
        functionName: 'auctions',
        args: [pool as `0x${string}`, auctionId]
      })
      
      return {
        start: result[0],
        end: result[1], 
        highestBid: result[2],
        highestBidder: result[3],
        settled: result[4],
        isActive: Date.now() / 1000 < Number(result[1]),
        timeRemaining: Math.max(0, Number(result[1]) - Date.now() / 1000)
      }
    } catch (error) {
      console.error('Error fetching auction:', error)
      return null
    }
  }
  
  // Get next auction ID for a pool
  async getNextAuctionId(pool: string): Promise<bigint> {
    return await publicClient.readContract({
      address: HOOK_ADDRESS,
      abi: HOOK_ABI,
      functionName: 'nextAuctionId',
      args: [pool as `0x${string}`]
    })
  }
  
  // Get insurance fund balance
  async getInsuranceFund(pool: string): Promise<bigint> {
    return await publicClient.readContract({
      address: HOOK_ADDRESS,
      abi: HOOK_ABI,
      functionName: 'mevInsuranceFund', 
      args: [pool as `0x${string}`]
    })
  }
  
  // Get active auctions for a pool
  async getActiveAuctions(pool: string) {
    const nextId = await this.getNextAuctionId(pool)
    const activeAuctions = []
    
    // Check last 5 auctions for active ones
    for (let i = Math.max(0, Number(nextId) - 5); i < Number(nextId); i++) {
      const auction = await this.getAuction(pool, BigInt(i))
      if (auction && auction.isActive) {
        activeAuctions.push({
          ...auction,
          auctionId: i,
          pool
        })
      }
    }
    
    return activeAuctions
  }
}
```

---

## 🤖 **Telegram Bot Implementation**

### **1. Bot Setup & Database**
```typescript
import TelegramBot from 'node-telegram-bot-api'
import Database from 'sqlite3'

interface User {
  telegramId: string
  walletAddress?: string
  privateKey?: string // encrypted
  watchedPools: string[]
  notificationSettings: {
    mevAlerts: boolean
    auctionUpdates: boolean
    winnerNotifications: boolean
  }
}

class MEVAlertBot {
  private bot: TelegramBot
  private db: Database.Database
  private monitor: BlockchainMonitor
  private queries: ContractQueries
  
  constructor(botToken: string) {
    this.bot = new TelegramBot(botToken, { polling: true })
    this.db = new Database.Database('./bot.db')
    this.monitor = new BlockchainMonitor()
    this.queries = new ContractQueries()
    
    this.setupDatabase()
    this.setupHandlers()
  }
  
  private setupDatabase() {
    this.db.serialize(() => {
      this.db.run(`CREATE TABLE IF NOT EXISTS users (
        telegram_id TEXT PRIMARY KEY,
        wallet_address TEXT,
        encrypted_key TEXT,
        watched_pools TEXT DEFAULT '[]',
        settings TEXT DEFAULT '{"mevAlerts":true,"auctionUpdates":true,"winnerNotifications":true}'
      )`)
      
      this.db.run(`CREATE TABLE IF NOT EXISTS bids (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        telegram_id TEXT,
        pool TEXT,
        auction_id INTEGER,
        bid_amount TEXT,
        tx_hash TEXT,
        status TEXT,
        timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
      )`)
    })
  }
}
```

### **2. Core Bot Commands**
```typescript
private setupHandlers() {
  // Start command
  this.bot.onText(/\/start/, async (msg) => {
    const chatId = msg.chat.id
    const welcomeMsg = `
🤖 **MEV-Alert Bot** - Protect Yourself from MEV!

🔍 **What I do:**
• Monitor pools for MEV activity
• Send real-time alerts when MEV detected
• Let you bid in auctions to reduce fees
• Notify you of auction results

📱 **Commands:**
/connect - Connect your wallet
/watch <pool> - Monitor pool for MEV
/auctions - View active auctions
/bid <pool> <auction> <amount> - Place bid
/balance - Check wallet balance
/help - Show all commands

🚀 **Get started:** /connect
    `
    
    await this.bot.sendMessage(chatId, welcomeMsg, { parse_mode: 'Markdown' })
  })
  
  // Connect wallet
  this.bot.onText(/\/connect/, async (msg) => {
    const chatId = msg.chat.id
    const telegramId = msg.from!.id.toString()
    
    // For demo: Generate a new wallet or use existing
    const user = await this.getUser(telegramId)
    if (user?.walletAddress) {
      await this.bot.sendMessage(chatId, `✅ Wallet already connected: ${user.walletAddress}`)
      return
    }
    
    // Generate new wallet for demo
    const account = privateKeyToAccount(generatePrivateKey())
    
    await this.saveUser({
      telegramId,
      walletAddress: account.address,
      privateKey: account.source, // In production: encrypt this!
      watchedPools: [DEMO_POOL],
      notificationSettings: {
        mevAlerts: true,
        auctionUpdates: true, 
        winnerNotifications: true
      }
    })
    
    await this.bot.sendMessage(chatId, `
🔐 **Wallet Connected!**

💰 Address: \`${account.address}\`
🎯 Monitoring: Demo Pool
⚡ Balance: 0 ETH (demo account)

💡 **Next steps:**
• /watch - Add more pools to monitor
• /auctions - See active auctions
• Wait for MEV alerts!
    `, { parse_mode: 'Markdown' })
  })
  
  // Watch pool
  this.bot.onText(/\/watch (.+)/, async (msg, match) => {
    const chatId = msg.chat.id
    const poolAddress = match![1].trim()
    
    if (!isAddress(poolAddress)) {
      await this.bot.sendMessage(chatId, '❌ Invalid pool address')
      return
    }
    
    // Add pool to user's watch list
    // Implementation here...
    
    await this.bot.sendMessage(chatId, `✅ Now monitoring ${poolAddress} for MEV activity`)
  })
  
  // View auctions
  this.bot.onText(/\/auctions/, async (msg) => {
    const chatId = msg.chat.id
    
    try {
      const activeAuctions = await this.queries.getActiveAuctions(DEMO_POOL)
      
      if (activeAuctions.length === 0) {
        await this.bot.sendMessage(chatId, '📭 No active auctions right now')
        return
      }
      
      for (const auction of activeAuctions) {
        const timeRemaining = Math.floor(auction.timeRemaining / 60)
        const auctionMsg = `
🏆 **Auction #${auction.auctionId}**

🏊 Pool: \`${auction.pool}\`
💰 Highest Bid: ${formatEther(auction.highestBid)} ETH
👤 Leader: \`${auction.highestBidder}\`
⏰ Time Left: ${timeRemaining} minutes

💡 Bid now: /bid ${auction.pool} ${auction.auctionId} <amount>
        `
        
        const keyboard = {
          inline_keyboard: [
            [
              { text: '💰 Bid 0.1 ETH', callback_data: `quick_bid_${auction.pool}_${auction.auctionId}_0.1` },
              { text: '💰 Bid 0.5 ETH', callback_data: `quick_bid_${auction.pool}_${auction.auctionId}_0.5` }
            ],
            [{ text: '📊 Details', callback_data: `auction_details_${auction.pool}_${auction.auctionId}` }]
          ]
        }
        
        await this.bot.sendMessage(chatId, auctionMsg, {
          parse_mode: 'Markdown',
          reply_markup: keyboard
        })
      }
    } catch (error) {
      console.error('Error fetching auctions:', error)
      await this.bot.sendMessage(chatId, '❌ Error fetching auctions')
    }
  })
  
  // Place bid
  this.bot.onText(/\/bid (.+) (\d+) ([\d.]+)/, async (msg, match) => {
    const chatId = msg.chat.id
    const [, poolAddress, auctionId, ethAmount] = match!
    
    await this.handleBidCommand(chatId, msg.from!.id.toString(), poolAddress, parseInt(auctionId), ethAmount)
  })
}
```

### **3. Bid Processing & Transaction Handling**
```typescript
private async handleBidCommand(chatId: number, telegramId: string, poolAddress: string, auctionId: number, ethAmount: string) {
  try {
    const user = await this.getUser(telegramId)
    if (!user?.privateKey) {
      await this.bot.sendMessage(chatId, '❌ Connect wallet first with /connect')
      return
    }
    
    const auction = await this.queries.getAuction(poolAddress, BigInt(auctionId))
    if (!auction || !auction.isActive) {
      await this.bot.sendMessage(chatId, '❌ Auction not active')
      return
    }
    
    const bidAmount = parseEther(ethAmount)
    if (bidAmount <= auction.highestBid) {
      await this.bot.sendMessage(chatId, `❌ Bid must be higher than ${formatEther(auction.highestBid)} ETH`)
      return
    }
    
    // Show confirmation
    const confirmMsg = `
🎯 **Bid Confirmation**

🏊 Pool: \`${poolAddress}\`
🏆 Auction: #${auctionId}
💰 Your Bid: ${ethAmount} ETH
⚡ Current High: ${formatEther(auction.highestBid)} ETH
⏰ Time Left: ${Math.floor(auction.timeRemaining / 60)} minutes

⛽ Estimated Gas: ~150,000 wei
💵 Gas Cost: ~0.0003 ETH

Confirm this bid?
    `
    
    const keyboard = {
      inline_keyboard: [
        [{ text: '✅ Confirm Bid', callback_data: `confirm_bid_${poolAddress}_${auctionId}_${ethAmount}` }],
        [{ text: '❌ Cancel', callback_data: 'cancel_bid' }]
      ]
    }
    
    await this.bot.sendMessage(chatId, confirmMsg, {
      parse_mode: 'Markdown',
      reply_markup: keyboard
    })
    
  } catch (error) {
    console.error('Bid error:', error)
    await this.bot.sendMessage(chatId, '❌ Error processing bid')
  }
}

// Handle callback queries (button presses)
this.bot.on('callback_query', async (query) => {
  const chatId = query.message!.chat.id
  const data = query.data!
  
  if (data.startsWith('confirm_bid_')) {
    const [, , poolAddress, auctionId, ethAmount] = data.split('_')
    
    try {
      // Submit transaction
      const account = privateKeyToAccount(user.privateKey as `0x${string}`)
      const hash = await walletClient.writeContract({
        address: HOOK_ADDRESS,
        abi: HOOK_ABI,
        functionName: 'placeBid',
        args: [poolAddress as `0x${string}`, BigInt(auctionId)],
        value: parseEther(ethAmount),
        account
      })
      
      await this.bot.editMessageText(`
✅ **Bid Submitted Successfully!**

💰 Bid: ${ethAmount} ETH
🔗 TX Hash: \`${hash}\`
⏳ Status: Confirming...

I'll notify you when it's confirmed!
      `, {
        chat_id: chatId,
        message_id: query.message!.message_id,
        parse_mode: 'Markdown'
      })
      
      // Track transaction
      this.trackTransaction(hash, query.from.id.toString(), chatId, query.message!.message_id)
      
    } catch (error) {
      await this.bot.editMessageText(`❌ Transaction failed: ${error.message}`, {
        chat_id: chatId,
        message_id: query.message!.message_id
      })
    }
  }
})
```

### **4. Event Handlers (Connected to Blockchain Monitor)**
```typescript
// Handle MEV Alerts
async handleMEVAlert(alertData: MEVAlertData) {
  const subscribers = await this.getPoolSubscribers(alertData.pool)
  
  for (const subscriber of subscribers) {
    const alertMsg = `
🚨 **MEV ALERT DETECTED!**

🏊 Pool: \`${alertData.pool}\`
📊 MEV Score: ${alertData.mevScore} (${this.getSeverityText(alertData.mevScore)})
⏰ Time: ${new Date(Number(alertData.timestamp) * 1000).toLocaleString()}

💡 This indicates potential MEV activity. An auction may start soon to reduce fees.

[View Details] [Set Alert] [Share Alert]
    `
    
    try {
      await this.bot.sendMessage(subscriber.telegramId, alertMsg, {
        parse_mode: 'Markdown'
      })
    } catch (error) {
      console.error(`Failed to send MEV alert to ${subscriber.telegramId}:`, error)
    }
  }
}

// Handle Auction Started
async handleAuctionStarted(auctionData: AuctionStartedData) {
  const subscribers = await this.getPoolSubscribers(auctionData.pool)
  
  for (const subscriber of subscribers) {
    const duration = Number(auctionData.endTime - auctionData.startTime) / 60
    const auctionMsg = `
🏆 **NEW AUCTION STARTED!**

🏊 Pool: \`${auctionData.pool}\`
🎯 Auction ID: #${auctionData.auctionId}
💰 Minimum Bid: ${formatEther(auctionData.minBid)} ETH
⏱️ Duration: ${duration} minutes

🚀 **Early Bird Advantage:** Bid now for potential time bonuses!

[Quick Bid 0.1] [Quick Bid 0.5] [Custom Amount]
    `
    
    const keyboard = {
      inline_keyboard: [
        [
          { text: '💰 Bid 0.1 ETH', callback_data: `quick_bid_${auctionData.pool}_${auctionData.auctionId}_0.1` },
          { text: '💰 Bid 0.5 ETH', callback_data: `quick_bid_${auctionData.pool}_${auctionData.auctionId}_0.5` }
        ],
        [{ text: '📊 Auction Details', callback_data: `auction_details_${auctionData.pool}_${auctionData.auctionId}` }]
      ]
    }
    
    try {
      const sentMsg = await this.bot.sendMessage(subscriber.telegramId, auctionMsg, {
        parse_mode: 'Markdown',
        reply_markup: keyboard
      })
      
      // Store message for live updates
      await this.storeAuctionMessage(auctionData.pool, auctionData.auctionId, subscriber.telegramId, sentMsg.message_id)
      
    } catch (error) {
      console.error(`Failed to send auction alert to ${subscriber.telegramId}:`, error)
    }
  }
}

// Handle Bid Updates
async handleBidPlaced(bidData: BidPlacedData) {
  const auctionMessages = await this.getAuctionMessages(bidData.pool, bidData.auctionId)
  
  for (const msgData of auctionMessages) {
    const auction = await this.queries.getAuction(bidData.pool, bidData.auctionId)
    if (!auction) continue
    
    const updateMsg = `
🏆 **AUCTION UPDATE** #${bidData.auctionId}

🏊 Pool: \`${bidData.pool}\`
💰 New Bid: ${formatEther(bidData.bidAmount)} ETH
👤 Bidder: \`${bidData.bidder.slice(0, 10)}...${bidData.bidder.slice(-8)}\`
⏰ Time Left: ${Math.floor(auction.timeRemaining / 60)} minutes

Current leader updated!
    `
    
    try {
      await this.bot.editMessageText(updateMsg, {
        chat_id: msgData.telegramId,
        message_id: msgData.messageId,
        parse_mode: 'Markdown'
      })
    } catch (error) {
      // Message might be too old to edit, send new one
      console.log(`Could not update message for user ${msgData.telegramId}`)
    }
  }
}
```

---

## 🚀 **Complete Bot Startup**

```typescript
// main.ts
import dotenv from 'dotenv'
dotenv.config()

async function main() {
  const bot = new MEVAlertBot(process.env.TELEGRAM_BOT_TOKEN!)
  
  console.log('🤖 MEV Alert Bot starting...')
  
  // Start blockchain monitoring
  await bot.startMonitoring()
  
  console.log('✅ Bot is ready and monitoring for MEV activity!')
  console.log(`🔗 Connected to: ${RPC_URL}`)
  console.log(`📊 Monitoring contract: ${HOOK_ADDRESS}`)
  
  // Graceful shutdown
  process.on('SIGINT', async () => {
    console.log('🛑 Shutting down bot...')
    await bot.stop()
    process.exit(0)
  })
}

main().catch(console.error)
```

---

## 📋 **Environment Variables**
```bash
# .env file
TELEGRAM_BOT_TOKEN=your_bot_token_from_botfather
HOOK_ADDRESS=0x5fbdb2315678afecb367f032d93f642f64180aa3
RPC_URL=http://127.0.0.1:8545
DEMO_POOL=0x1111111111111111111111111111111111111111

# Demo accounts (from prepare-demo.sh)
ALICE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
BOB_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
```

---

## 🎯 **Testing & Demo**

### **Testing Workflow:**
1. **Start Anvil Demo**: `./scripts/prepare-demo.sh`
2. **Start Bot**: `npm start` 
3. **Test Commands**: 
   - `/start` - Bot introduction
   - `/connect` - Generate demo wallet
   - `/auctions` - Should show no active auctions initially
4. **Trigger MEV Alert**: `./demo-scenario-1.sh` 
5. **Start Auction**: `./demo-scenario-2.sh`
6. **Interactive Bidding**: Use bot commands to bid
7. **Emergency Test**: `./demo-scenario-3.sh`

### **Demo Day Flow:**
```
1. 🎪 Start demo environment
2. 🤖 Start Telegram bot
3. 📱 Give judges bot handle (@YourBotName)
4. 🔍 Trigger MEV alert → Bot notifies judges
5. 🏆 Start auction → Judges bid competitively  
6. 🎉 Show winner notifications
7. 🚨 Demo emergency features
```

---

## 💡 **Key Advantages of Viem over Subgraph**

✅ **Instant Setup** - No subgraph deployment needed  
✅ **Real-time Events** - Direct blockchain connection  
✅ **Simpler Architecture** - One less moving part  
✅ **Local Development** - Perfect for hackathon demo  
✅ **Full Control** - Direct contract interaction  
✅ **Type Safety** - Viem's excellent TypeScript support  

---

**🚀 This Viem-based approach will give you a production-quality Telegram bot that's much simpler to set up and perfect for your hackathon demo!**
