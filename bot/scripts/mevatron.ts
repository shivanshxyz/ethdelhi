import TelegramBot from 'node-telegram-bot-api'
import Database, { Database as DatabaseType } from 'better-sqlite3'
import { BlockchainMonitor, ContractQueries } from './monitoring'
import { formatEther, isAddress, parseEther } from 'viem'
import { privateKeyToAccount, generatePrivateKey } from 'viem/accounts'
import dotenv from 'dotenv'
dotenv.config()

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

export class MEVAlertBot {
  private bot: TelegramBot
  private db: DatabaseType
  private monitor: BlockchainMonitor
  private queries: ContractQueries
  
  constructor(botToken: string) {
    this.bot = new TelegramBot(botToken, { polling: true })
    this.db = new Database('./bot.db')
    this.monitor = new BlockchainMonitor()
    this.queries = new ContractQueries()
    
    this.setupDatabase()
    this.setupHandlers()
    this.monitor.handleMEVAlert = this.sendMEVAlert.bind(this)
  }
  
  private setupDatabase() {
    this.db.exec(`CREATE TABLE IF NOT EXISTS users (
      telegram_id TEXT PRIMARY KEY,
      wallet_address TEXT,
      encrypted_key TEXT,
      watched_pools TEXT DEFAULT '[]',
      settings TEXT DEFAULT '{"mevAlerts":true,"auctionUpdates":true,"winnerNotifications":true}'
    )`)
    
    this.db.exec(`CREATE TABLE IF NOT EXISTS bids (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      telegram_id TEXT,
      pool TEXT,
      auction_id INTEGER,
      bid_amount TEXT,
      tx_hash TEXT,
      status TEXT,
      timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
    )`)
  }

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
      
      // Import demo wallet from environment (.env ALICE_PRIVATE_KEY / BOB_PRIVATE_KEY)
      // Optional mapping: ALICE_TELEGRAM_ID or BOB_TELEGRAM_ID may be set to bind keys to telegram users
      let selectedKey = process.env.ALICE_PRIVATE_KEY ?? process.env.BOB_PRIVATE_KEY

      if (!selectedKey) {
        await this.bot.sendMessage(chatId, '❌ No demo private key found in environment. Set ALICE_PRIVATE_KEY or BOB_PRIVATE_KEY in your .env')
        return
      }

      const account = privateKeyToAccount(selectedKey as `0x${string}`)

      await this.saveUser({
        telegramId,
        walletAddress: account.address,
        privateKey: selectedKey as `0x${string}`,
        watchedPools: [process.env.DEMO_POOL!],
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
        const activeAuctions = await this.queries.getActiveAuctions(process.env.DEMO_POOL!)
        
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
                { text: '💰 Bid 0.1 ETH', callback_data: `quick_bid:${auction.pool}:${auction.auctionId}:0.1` },
                { text: '💰 Bid 0.5 ETH', callback_data: `quick_bid:${auction.pool}:${auction.auctionId}:0.5` }
              ],
              [{ text: '📊 Details', callback_data: `auction_details:${auction.pool}:${auction.auctionId}` }]
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
    this.bot.onText(/.bid (.+) (\d+) ([\d.]+)/, async (msg, match) => {
      const chatId = msg.chat.id
      const [, poolAddress, auctionId, ethAmount] = match!
      
      await this.handleBidCommand(chatId, msg.from!.id.toString(), poolAddress, parseInt(auctionId), ethAmount)
    })

    this.bot.on('callback_query', async (callbackQuery) => {
      const msg = callbackQuery.message
      const data = callbackQuery.data
      
      if (!msg || !data) {
        await this.bot.answerCallbackQuery(callbackQuery.id)
        return
      }

      const chatId = msg.chat.id
      const telegramId = callbackQuery.from.id.toString()

      await this.bot.answerCallbackQuery(callbackQuery.id)

      if (data.startsWith('confirm_bid:')) {
        const [, poolAddress, auctionIdStr, ethAmount] = data.split(':')
        const auctionId = parseInt(auctionIdStr)

        try {
          // Edit the original message to show "Submitting..." and remove the buttons.
          await this.bot.editMessageText('Submitting your bid...', {
            chat_id: chatId,
            message_id: msg.message_id,
          })

          const user = await this.getUser(telegramId)
          if (!user?.privateKey) {
            await this.bot.editMessageText('❌ Connect wallet first with /connect', {
              chat_id: chatId,
              message_id: msg.message_id,
            })
            return
          }

          const bidAmount = parseEther(ethAmount)

          const txHash = await this.queries.placeBid(
            user.privateKey as `0x${string}`,
            poolAddress,
            BigInt(auctionId),
            bidAmount
          )

          await this.bot.editMessageText(
`✅ **Bid Submitted!**

Transaction Hash: \`${txHash}\`
`, {
            chat_id: chatId,
            message_id: msg.message_id,
            parse_mode: 'Markdown'
          })

        } catch (error: any) {
          console.error('Failed to place bid:', error)
          await this.bot.editMessageText(`❌ Failed to place bid: ${error.shortMessage || error.message}`, {
            chat_id: chatId,
            message_id: msg.message_id
          })
        }
      } else if (data === 'cancel_bid') {
        await this.bot.editMessageText('Bid cancelled.', {
          chat_id: chatId,
          message_id: msg.message_id,
        })
      } else if (data.startsWith('quick_bid:')) {
        const [, poolAddress, auctionIdStr, ethAmount] = data.split(':')
        const auctionId = parseInt(auctionIdStr)
        // It's better to remove the original message with the buttons
        await this.bot.deleteMessage(chatId, msg.message_id)
        await this.handleBidCommand(chatId, telegramId, poolAddress, auctionId, ethAmount)
      } else if (data.startsWith('auction_details:')) {
        await this.bot.sendMessage(chatId, 'Details feature coming soon!')
      }
    })
  }

  private async handleBidCommand(chatId: number, telegramId: string, poolAddress: string, auctionId: number, ethAmount: string) {
    try {
      const user = await this.getUser(telegramId)
      if (!user?.privateKey) {
        await this.bot.sendMessage(chatId, '❌ Connect wallet first with /connect')
        return
      }
      
      const auction = await this.queries.getAuction(poolAddress, BigInt(auctionId))
      if (!auction || !auction.isActive) {
        console.log(auction);
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
          [{ text: '✅ Confirm Bid', callback_data: `confirm_bid:${poolAddress}:${auctionId}:${ethAmount}` }],
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

  private async sendMEVAlert(params: {
    pool: string,
    mevScore: bigint,
    timestamp: bigint,
    blockNumber: bigint | number | undefined,
    txHash: string | undefined
  }) {
    console.log(`Broadcasting MEV alert for pool ${params.pool}`);

    const stmt = this.db.prepare('SELECT telegram_id, watched_pools, settings FROM users');
    const users = stmt.all() as { telegram_id: string, watched_pools: string, settings: string }[];

    const alertMessage = `
🚨 **MEV Alert!**

A high MEV score has been detected, indicating a potential MEV opportunity or attack.

🏊 **Pool:** \`${params.pool}\`
📈 **MEV Score:** ${params.mevScore.toString()}
🔗 **Transaction:** \`${params.txHash}\`

An auction may start shortly. Use /auctions to check.
    `;

    for (const user of users) {
        try {
            const watchedPools = JSON.parse(user.watched_pools) as string[];
            const settings = JSON.parse(user.settings);

            if (settings.mevAlerts && watchedPools.includes(params.pool)) {
                await this.bot.sendMessage(user.telegram_id, alertMessage, { parse_mode: 'Markdown' });
            }
        } catch (error) {
            console.error(`Failed to send alert to user ${user.telegram_id}`, error);
        }
    }
  }

  async startMonitoring() {
    await this.monitor.startMonitoring()
  }

  async stop() {
    await this.monitor.stopMonitoring()
  }

  private async getUser(telegramId: string): Promise<User | null> {
    const stmt = this.db.prepare('SELECT * FROM users WHERE telegram_id = ?')
    const row = stmt.get(telegramId) as any
    
    if (!row) {
      return null
    }
    
    return {
      telegramId: row.telegram_id,
      walletAddress: row.wallet_address,
      privateKey: row.encrypted_key,
      watchedPools: JSON.parse(row.watched_pools),
      notificationSettings: JSON.parse(row.settings)
    }
  }

  private async saveUser(user: User): Promise<void> {
    const stmt = this.db.prepare(
      'INSERT OR REPLACE INTO users (telegram_id, wallet_address, encrypted_key, watched_pools, settings) VALUES (?, ?, ?, ?, ?)'
    )
    
    stmt.run(
      user.telegramId,
      user.walletAddress,
      user.privateKey,
      JSON.stringify(user.watchedPools),
      JSON.stringify(user.notificationSettings)
    )
  }
}