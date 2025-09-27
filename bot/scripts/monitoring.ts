import { createPublicClient, createWalletClient, http, parseAbiItem, parseEventLogs } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { foundry } from 'viem/chains'
import dotenv from 'dotenv'
dotenv.config()

// Helper typed address and contract address constant
type Address = `0x${string}`
const HOOK_ADDRESS = process.env.HOOK_ADDRESS as Address

// Auction info shape returned by the contract queries
interface AuctionInfo {
  start: bigint
  end: bigint
  highestBid: bigint
  highestBidder: Address
  settled: boolean
  isActive: boolean
  timeRemaining: number
}

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

// Setup clients
const publicClient = createPublicClient({
  chain: foundry,
  transport: http('http://127.0.0.1:8545')
})

// For sending transactions (bidding)
const walletClient = createWalletClient({
    account: privateKeyToAccount(process.env.ALICE_PRIVATE_KEY as `0x${string}`),
  chain: foundry,
  transport: http('http://127.0.0.1:8545')
})

// Event listeners
class BlockchainMonitor {
  private unsubscribeFunctions: (() => void)[] = []
  
  async handleMEVAlert(params: {
    pool: string,
    mevScore: bigint,
    timestamp: bigint,
    blockNumber: bigint | number | undefined,
    txHash: string | undefined
  }) {
    console.log('Handling MEV Alert:', params)
  }

  async startMonitoring() {
    console.log('🔍 Starting blockchain event monitoring...')
    
    // Monitor MEV Alerts
    const unsubscribeMEVAlerts = publicClient.watchContractEvent({
      address: process.env.HOOK_ADDRESS as `0x${string}`,
      abi: HOOK_ABI,
      eventName: 'MEVAlert',
      onLogs: (logs) => {
        logs.forEach(async (log) => {
          // Parse event args from log using viem's parseAbiItem
          const event = parseEventLogs({
            abi: [parseAbiItem('event MEVAlert(address indexed pool, uint256 mevScore, uint256 timestamp, bytes32 metadataHash)')],
            logs: [log]
          })
          
          const { pool, mevScore, timestamp } = event[0].args as { pool: string, mevScore: bigint, timestamp: bigint }
          console.log(`🚨 MEV Alert: Pool ${pool}, Score ${mevScore}`)
          
          await this.handleMEVAlert({
            pool: pool!,
            mevScore: mevScore!,
            timestamp: timestamp!,
            blockNumber: log.blockNumber!,
            txHash: log.transactionHash!
          })
        })
      }
    })
    
    // Monitor Auction Events  
    const unsubscribeAuctions = publicClient.watchContractEvent({
      address: process.env.HOOK_ADDRESS as `0x${string}`,
      abi: HOOK_ABI,
      eventName: 'AuctionStarted',
      onLogs: (logs) => {
        logs.forEach(async (log) => {
            const event = parseEventLogs({
            abi: [parseAbiItem('event AuctionStarted(address indexed pool, uint256 auctionId, uint256 minBid, uint256 startTime, uint256 endTime)')],
            logs: [log]
          })
          
          const { pool, auctionId, minBid, startTime, endTime } = event[0].args as { pool: string , auctionId: bigint, minBid: bigint, startTime: bigint, endTime: bigint}
          console.log(`🏆 Auction Started: Pool ${pool}, ID ${auctionId}`)
          
          await this.handleAuctionStarted({
            pool: pool!,
            auctionId: auctionId!,
            minBid: minBid!,
            startTime: startTime!,
            endTime: endTime!,
            blockNumber: log.blockNumber!,
            txHash: log.transactionHash!
          })
        })
      }
    })
    
    // Monitor Bids
    const unsubscribeBids = publicClient.watchContractEvent({
      address: process.env.HOOK_ADDRESS as `0x${string}`,
      abi: HOOK_ABI, 
      eventName: 'BidPlaced',
      onLogs: (logs) => {
        logs.forEach(async (log) => {
            const event = parseEventLogs({
            abi: [parseAbiItem('event BidPlaced(address indexed pool, uint256 auctionId, address bidder, uint256 bidAmount)')],
            logs: [log]
          })

          const { pool, auctionId, bidder, bidAmount} = event[0].args as {pool: string, auctionId: bigint, bidder: string, bidAmount: bigint}
          
          await this.handleBidPlaced({
            pool: pool!,
            auctionId: auctionId!,
            bidder: bidder!,
            bidAmount: bidAmount!,
            blockNumber: log.blockNumber!,
            txHash: log.transactionHash!
          })
        })
      }
    })
    
    this.unsubscribeFunctions = [unsubscribeMEVAlerts, unsubscribeAuctions, unsubscribeBids]
  }
  
  async handleAuctionStarted(params: {
    pool: string,
    auctionId: bigint,
    minBid: bigint,
    startTime: bigint,
    endTime: bigint,
    blockNumber: bigint | number | undefined,
    txHash: string | undefined
  }) {
    console.log('Handling Auction Started:', params)
  }

  async handleBidPlaced(params: {
    pool: string,
    auctionId: bigint,
    bidder: string,
    bidAmount: bigint,
    blockNumber: bigint | number | undefined,
    txHash: string | undefined
  }) {
    console.log('Handling Bid Placed:', params)
  }

  async stopMonitoring() {
    this.unsubscribeFunctions.forEach(unsub => unsub())
    console.log('⏹️ Stopped blockchain monitoring')
  }
}

class ContractQueries {
  
  // Get auction details
  async getAuction(pool: string, auctionId: bigint): Promise<AuctionInfo | null> {
    try {
  const result = await publicClient.readContract({
        address: process.env.HOOK_ADDRESS as `0x${string}`,
        abi: HOOK_ABI,
        functionName: 'auctions',
        args: [pool as `0x${string}`, auctionId]
  }) as unknown as [bigint, bigint, bigint, Address, boolean]
      const [start, end, highestBid, highestBidder, settled] = result

      const endNumber = Number(end)

      const auction: AuctionInfo = {
        start,
        end,
        highestBid,
        highestBidder,
        settled,
        isActive: Date.now() / 1000 < endNumber,
        timeRemaining: Math.max(0, endNumber - Date.now() / 1000)
      }

      return auction
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
  }) as unknown as bigint
  }
  
  // Get insurance fund balance
  async getInsuranceFund(pool: string): Promise<bigint> {
  return await publicClient.readContract({
      address: HOOK_ADDRESS,
      abi: HOOK_ABI,
      functionName: 'mevInsuranceFund', 
      args: [pool as `0x${string}`]
  }) as unknown as bigint
  }
  
  // Get active auctions for a pool
  async getActiveAuctions(pool: string): Promise<Array<AuctionInfo & { auctionId: number, pool: string }>> {
    const nextId = await this.getNextAuctionId(pool)
    const activeAuctions: Array<AuctionInfo & { auctionId: number, pool: string }> = []

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

export { BlockchainMonitor };
export { ContractQueries };