import { MEVAlertBot } from './mevatron'
import dotenv from 'dotenv'
dotenv.config()

async function main() {
  const bot = new MEVAlertBot(process.env.TELEGRAM_BOT_TOKEN!)
  
  console.log('🤖 MEV Alert Bot starting...')
  
  // Start blockchain monitoring
  await bot.startMonitoring()
  
  console.log('✅ Bot is ready and monitoring for MEV activity!')
  console.log(`🔗 Connected to: ${process.env.RPC_URL}`)
  console.log(`📊 Monitoring contract: ${process.env.HOOK_ADDRESS}`)
  
  // Graceful shutdown
  process.on('SIGINT', async () => {
    console.log('🛑 Shutting down bot...')
    await bot.stop()
    process.exit(0)
  })
}

main().catch(console.error)