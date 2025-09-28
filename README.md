# Short description
## A max 100-character or less description of your project (it should fit in a tweet!)

🚀 MEVengers: World's first social mechanism to hedge against MEVs 💰⚡

# Description
## Go in as much detail as you can about what this project is. Please be as clear as possible!

**MEVengers** is the world's first MEV (Maximal Extractable Value) protection system accessible through Telegram, democratizing MEV protection for retail users.

## The Problem

### Problem 1: MEV Extraction Hurts Regular Users
- Users get worse prices due to sandwich attacks, front-running
- No protection mechanism for retail traders
- MEV extraction is "invisible" to most users

### Problem 2: Static Fee Models Don't Adapt
- Uniswap pools have fixed fees (0.05%, 0.3%, 1%)
- Can't respond to market conditions dynamically
- High MEV periods get same fees as low MEV periods

### Problem 3: No Real-Time MEV Visibility
- No alerts when users are being targeted
- Post-hoc analysis only (Flashbots, etc.)
- Users can't take protective action


## Our Solution
MEVengers creates a complete ecosystem where:

### 🔍 **1. Smart MEV detection**
Our smart MEV detection system computes and onchain MEV score by analysing the following params:
- Swap amounts from BalanceDelta
- Time since last large swap
- Calculate price impact estimate 
- Check for rapid consecutive swaps


### 🏆 **2. Time Weighted Auctions to hedge against MEVs**

Our hook automatically detects MEV scenarios and starts fee auctions. Users compete to set protective fees - winner pays premium but gets 50% back, everyone else gets protection. It's like surge pricing for MEV protection, but decided by the community

We implement Time Weighted Auction mechanics to incentivize early bidders:
Early bidders get 20% time bonus
Mid bids get 10% time bonus

### 🛡️ **3. MEV Insurance**
- Community-Funded: Automatic funding from auction proceeds

- Evidence-Based: Requires cryptographic proof of MEV loss

- Partial Coverage: 50% compensation to prevent moral hazard

- Pool-Specific: Separate insurance funds per trading pool


MEVengers transforms MEV from a zero-sum extractive force into a positive-sum community mechanism where users actively participate in protecting each other.

# How it's made
## Tell us about how you built this project; the nitty-gritty details. What technologies did you use? How are they pieced together? If you used any partner technologies, how did it benefit your project? Did you do anything particuarly hacky that's notable and worth mentioning?

MEVengers is built as a complete end-to-end ecosystem integrating cutting-edge Web3 infrastructure with accessible Web2 UX.

## Core Architecture

### 🔗 **Uniswap v4 Hook Smart Contracts (Solidity)**
- **Custom Hook Implementation**: Built on Uniswap v4's revolutionary hook architecture
- **MEV Detection Engine**: Real-time on-chain analysis using transaction patterns and volume thresholds  
- **Auction Mechanism**: Time-weighted competitive bidding with automatic settlement
- **Advanced Features**: Emergency circuit breaker, insurance fund
- **Gas Optimization**: Efficient storage patterns and event emission for minimal transaction costs

### 🤖 **Telegram Bot Integration (Node.js)**
- **Rich Interactive UI**: Inline keyboards for one-click bidding
- **Real-Time Updates**: Live message editing during auctions
- **Wallet Management**: Secure encrypted private key storage per user
- **Notification System**: Instant alerts with customizable preferences

### 🛠️ **Development & Testing Infrastructure**
- **Foundry Framework**: Comprehensive test suite with 100% core functionality coverage
- **Local Development**: Anvil integration for instant testing and demo environments
- **Integration Testing**: End-to-end automation testing all user workflows
- **Demo Automation**: One-click demo environment setup with pre-configured scenarios

## Technical Innovations

### 🎯 **Time-Weighted Auction Mechanics**
We implemented a novel auction system where earlier bidders receive time-based bonuses, creating incentives for rapid community response to MEV threats while maintaining fair price discovery.

### 🚨 **Emergency Circuit Breaker Pattern**
Built a comprehensive pause mechanism that can halt all operations except admin functions during security incidents, with granular permission controls that allow owners to operate even during emergency states.

### 💰 **MEV Insurance Integration**
Created a community-funded insurance system where auction proceeds automatically contribute to a victim compensation fund, turning MEV protection into a positive-sum community endeavor.

### 📱 **Telegram-First DeFi UX**
Pioneered accessible DeFi interactions through messaging interfaces, with real-time blockchain state updates delivered as interactive chat messages with proper error handling and user feedback.


# Steps to run

1. `forge build`
2. ./scripts/prepare-demo.sh
3. demo-scenario-*.sh to recreate MEV attacks
4. pnpm i && pnpm run start for telegram bot