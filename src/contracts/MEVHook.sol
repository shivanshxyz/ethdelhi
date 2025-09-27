// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ECDSA} from "../../lib/openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// Uniswap v4 Hook base and types
import {Ownable} from "../../lib/openzeppelin/contracts/access/Ownable.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
contract MEVHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using ECDSA for bytes32;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------
    event SwapObserved(address indexed pool, address indexed trader, uint256 amountIn, uint256 amountOut, uint256 timestamp);
    event MEVAlert(address indexed pool, uint256 mevScore, uint256 timestamp, bytes32 metadataHash);
    event AuctionStarted(address indexed pool, uint256 indexed auctionId, uint256 minBid, uint256 startTime, uint256 endTime);
    event BidPlaced(address indexed pool, uint256 indexed auctionId, address bidder, uint256 bidAmount);
    event AuctionSettled(address indexed pool, uint256 indexed auctionId, address winner, uint256 finalFeeBps);
    event RecommendationApplied(address indexed pool, uint256 recommendedFeeBps, address signer, bytes32 metadataHash);
    
    // Time-weighted auction events
    event TimeWeightedBid(address indexed pool, uint256 indexed auctionId, address bidder, uint256 actualBid, uint256 effectiveBid, uint256 timeBonus);
    
    // Emergency events
    event EmergencyPaused(uint256 timestamp, string reason);
    event EmergencyUnpaused(uint256 timestamp);
    
    // MEV Insurance events
    event InsuranceDeposit(address indexed pool, uint256 amount, uint256 newTotal);
    event InsuranceClaim(address indexed user, address indexed pool, uint256 lossAmount, uint256 compensation);
    event InsuranceTopUp(address indexed pool, uint256 amount, address contributor);

    // -------------------------------------------------------------------------
    // Data Structures (must match spec EXACTLY where specified)
    // -------------------------------------------------------------------------
    struct Auction {
        uint32 start;                    // auction start timestamp
        uint32 end;                      // auction end timestamp
        uint128 highestBid;              // highest bid in wei (fits in uint128 for demo)
        address highestBidder;           // leading bidder
        uint16 minBidPercentOrFee;       // generic small field: used as default fee bps on finalize (demo)
        bool settled;                    // settled flag
        uint128 highestEffectiveBid;     // time-weighted effective bid
    }

    struct FeeOverride {
        uint32 expiresAt;                // when this override expires
        uint16 feeBps;                   // fee in basis points
    }

    // per spec: public mapping
    mapping(address => FeeOverride) public feeOverrides; // pool => override

    // per spec: global nonces mapping (per-signer)
    mapping(address => uint256) public nonces; // signer => nonce

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------
    // pool allowlist (who can call onSwap)
    mapping(address => bool) public isPool;   // pool => allowed

    // quick demo scoring configuration
    mapping(address => uint256) public mevThreshold; // pool => threshold
    uint256 public minLargeSwap = 0;                 // global demo param

    // MEV tracking storage for sophisticated scoring
    mapping(address => uint256) public lastLargeSwapTime; // pool => timestamp
    mapping(address => uint256) public lastSwapAmount;   // pool => last amount
    mapping(address => uint256) public swapCount24h;     // pool => count in 24h
    mapping(address => uint256) public lastCountReset;   // pool => last reset time
    mapping(address => uint256) public totalVolumeToday; // pool => volume in 24h
    
    // MEV detection thresholds (configurable)
    uint256 public rapidSwapThreshold = 300;  // 5 minutes in seconds
    uint256 public highVolumeMultiplier = 10; // 10x normal volume = suspicious
    uint256 public consecutiveSwapBonus = 200; // 2x multiplier for rapid swaps

    // authorized off-chain oracles for EIP-712 recommendations
    mapping(address => bool) public isAuthorizedOracle; // signer => allowed

    // auctions storage per pool
    mapping(address => uint256) public nextAuctionId;                   // pool => next id
    mapping(address => mapping(uint256 => Auction)) public auctions;    // pool => id => auction
    mapping(address => mapping(uint256 => uint256)) public minBidWeiByAuction; // optional storage for min bid

    // payouts and destinations
    address public treasuryAddress;   // receives 40%
    address public protocolAddress;   // receives 10%

    // default fee to set when settling an auction (if no other rule)
    uint16 public defaultAuctionFeeBps = 50; // 0.50% for demo

    // durations for overrides
    uint32 public auctionOverrideDuration = 5 minutes;
    uint32 public recommendationOverrideDuration = 5 minutes;

    // If true, only owner can start auctions (optional behavior)
    bool public auctionsOwnerOnly = false;

    // -------------------------------------------------------------------------
    // Time-Weighted Auction Storage
    // -------------------------------------------------------------------------
    // Maximum time bonus percentage (20% = 2000 basis points)
    uint256 public maxTimeBonusPercent = 20;
    
    // -------------------------------------------------------------------------
    // Emergency Circuit Breaker Storage
    // -------------------------------------------------------------------------
    bool public emergencyPaused;
    string public pauseReason;
    uint256 public pausedAt;
    
    // -------------------------------------------------------------------------
    // MEV Insurance Storage
    // -------------------------------------------------------------------------
    // Insurance fund per pool (pool => fund amount)
    mapping(address => uint256) public mevInsuranceFund;
    
    // Total insurance claims per user per pool (user => pool => total claimed)
    mapping(address => mapping(address => uint256)) public insuranceClaimsHistory;
    
    // Maximum compensation percentage (50% = 5000 basis points)
    uint256 public maxCompensationPercent = 50;
    
    // Minimum loss amount to be eligible for insurance (prevents spam)
    uint256 public minInsurableLoss = 0.001 ether;

    // simple non-reentrancy guard for payable functions
    uint256 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "REENTRANCY");
        _locked = 2;
        _;
        _locked = 1;
    }
    
    // Emergency circuit breaker modifier
    modifier notInEmergency() {
        require(!emergencyPaused || msg.sender == owner(), "EMERGENCY_PAUSED");
        _;
    }

    // -------------------------------------------------------------------------
    // EIP-712 Domain
    // -------------------------------------------------------------------------
    bytes32 public constant RECOMMENDATION_TYPEHASH = keccak256(
        "Recommendation(address pool,uint16 recommendedFeeBps,uint256 deadline,uint256 nonce,bytes32 metadataHash)"
    );

    bytes32 private _CACHED_DOMAIN_SEPARATOR;
    uint256 private _CACHED_CHAIN_ID;
    bytes32 private _HASHED_NAME;
    bytes32 private _HASHED_VERSION;
    bytes32 private _TYPE_HASH;

    constructor(IPoolManager _poolManager, string memory name_, string memory version_) BaseHook(_poolManager) {
        treasuryAddress = msg.sender;
        protocolAddress = msg.sender;

        _HASHED_NAME = keccak256(bytes(name_));
        _HASHED_VERSION = keccak256(bytes(version_));
        _TYPE_HASH = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        _updateDomainSeparator();
    }

    function _updateDomainSeparator() internal {
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                _TYPE_HASH,
                _HASHED_NAME,
                _HASHED_VERSION,
                block.chainid,
                address(this)
            )
        );
    }

    function _domainSeparatorV4() internal view returns (bytes32) {
        if (block.chainid == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        } else {
            return keccak256(
                abi.encode(
                    _TYPE_HASH,
                    _HASHED_NAME,
                    _HASHED_VERSION,
                    block.chainid,
                    address(this)
                )
            );
        }
    }

    // -------------------------------------------------------------------------
    // Time-Weighted Auction Mechanics
    // -------------------------------------------------------------------------
    
    /// @notice Calculate time-weighted effective bid amount
    /// @param bidAmount The actual bid amount in wei
    /// @param timeElapsed Time elapsed since auction start
    /// @param totalDuration Total auction duration
    /// @return effectiveBid The time-weighted effective bid amount
    function calculateTimeWeightedBid(
        uint256 bidAmount, 
        uint256 timeElapsed, 
        uint256 totalDuration
    ) public view returns (uint256 effectiveBid) {
        if (totalDuration == 0) return bidAmount;
        
        // Calculate time bonus: earlier bids get higher bonus (up to maxTimeBonusPercent)
        // timeRemaining / totalDuration gives fraction of time left
        // multiply by maxTimeBonusPercent to get bonus percentage
        uint256 timeRemaining = totalDuration > timeElapsed ? totalDuration - timeElapsed : 0;
        uint256 timeBonus = (timeRemaining * maxTimeBonusPercent) / totalDuration;
        
        // Apply bonus: effectiveBid = bidAmount * (100 + timeBonus) / 100
        effectiveBid = bidAmount * (100 + timeBonus) / 100;
    }
    
    /// @notice Get current effective highest bid for an auction
    /// @param pool Pool address
    /// @param auctionId Auction ID
    /// @return Current effective highest bid
    function getCurrentEffectiveHighestBid(address pool, uint256 auctionId) 
        public view returns (uint256) {
        return auctions[pool][auctionId].highestEffectiveBid;
    }

    // -------------------------------------------------------------------------
    // Emergency Circuit Breaker Functions
    // -------------------------------------------------------------------------
    
    /// @notice Emergency pause all hook operations
    /// @param reason Reason for emergency pause
    function emergencyPause(string calldata reason) external onlyOwner {
        require(!emergencyPaused, "ALREADY_PAUSED");
        emergencyPaused = true;
        pauseReason = reason;
        pausedAt = block.timestamp;
        emit EmergencyPaused(block.timestamp, reason);
    }
    
    /// @notice Unpause emergency state
    function emergencyUnpause() external onlyOwner {
        require(emergencyPaused, "NOT_PAUSED");
        emergencyPaused = false;
        pauseReason = "";
        pausedAt = 0;
        emit EmergencyUnpaused(block.timestamp);
    }
    
    // -------------------------------------------------------------------------
    // MEV Insurance Functions
    // -------------------------------------------------------------------------
    
    /// @notice Deposit funds into MEV insurance pool
    /// @param pool Pool address to insure
    function depositInsurance(address pool) external payable {
        require(msg.value > 0, "ZERO_DEPOSIT");
        require(isPool[pool], "POOL_NOT_ALLOWED");
        
        mevInsuranceFund[pool] += msg.value;
        emit InsuranceDeposit(pool, msg.value, mevInsuranceFund[pool]);
    }
    
    /// @notice Claim MEV insurance compensation (simplified version)
    /// @param pool Pool where MEV loss occurred
    /// @param lossAmount Amount of MEV loss (in wei)
    /// @param evidence Hash of evidence proving MEV loss
    function claimMEVInsurance(
        address pool,
        uint256 lossAmount,
        bytes32 evidence
    ) external nonReentrant {
        require(lossAmount >= minInsurableLoss, "LOSS_TOO_SMALL");
        require(mevInsuranceFund[pool] > 0, "NO_INSURANCE_FUND");
        require(isPool[pool], "POOL_NOT_ALLOWED");
        require(evidence != bytes32(0), "INVALID_EVIDENCE");
        
        // Calculate compensation (percentage of loss, capped by available fund)
        uint256 maxCompensation = (lossAmount * maxCompensationPercent) / 100;
        uint256 compensation = maxCompensation;
        
        // Cap by available insurance fund
        if (compensation > mevInsuranceFund[pool]) {
            compensation = mevInsuranceFund[pool];
        }
        
        // Prevent users from claiming more than their total historical losses
        // This is a simplified check - in production you'd verify against MEV detection data
        require(compensation > 0, "NO_COMPENSATION");
        
        // Update state
        mevInsuranceFund[pool] -= compensation;
        insuranceClaimsHistory[msg.sender][pool] += compensation;
        
        // Transfer compensation
        (bool ok, ) = payable(msg.sender).call{value: compensation}("");
        require(ok, "TRANSFER_FAILED");
        
        emit InsuranceClaim(msg.sender, pool, lossAmount, compensation);
    }

    // -------------------------------------------------------------------------
    // External trigger for demos: onSwap (pool-initiated or allowlisted caller)
    // -------------------------------------------------------------------------
    /// @notice Demo entry so off-chain scripts can simulate swaps without full pool plumbing.
    /// @dev Uses msg.sender as the pool identity for allowlist checks and event schema.
    function onSwap(address trader, uint256 amountIn, uint256 amountOut) external notInEmergency {
        address pool = msg.sender;
        require(isPool[pool], "POOL_NOT_ALLOWED");

        // Update MEV tracking data
        _updateSwapTracking(pool, amountIn);

        emit SwapObserved(pool, trader, amountIn, amountOut, block.timestamp);

        uint256 score = computeMEVScoreOnchain(pool, amountIn);
        if (score >= mevThreshold[pool]) {
            emit MEVAlert(pool, score, block.timestamp, bytes32(0));
        }
    }

    // -------------------------------------------------------------------------
    // Hook Permissions
    // -------------------------------------------------------------------------
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }


    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId id = key.toId();
        address poolAddr = address(uint160(uint256(PoolId.unwrap(id))));
        
        // Check for fee override
        FeeOverride memory feeOverride = feeOverrides[poolAddr];
        uint24 dynamicFee = 0;
        
        if (feeOverride.expiresAt > block.timestamp && feeOverride.feeBps > 0) {
            // Convert basis points to Uniswap fee format (multiply by 100)
            dynamicFee = uint24(feeOverride.feeBps * 100); 
        }
        
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, dynamicFee);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Derive a reproducible synthetic address for the pool from PoolId
        PoolId id = key.toId();
        address poolAddr = address(uint160(uint256(PoolId.unwrap(id))));

        // Interpret BalanceDelta to get in/out amounts w.r.t. zeroForOne direction
        // amount0 and amount1 are signed; negative indicates sent from caller perspective.
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();

        uint256 amountIn;
        uint256 amountOut;
        if (params.zeroForOne) {
            // trader sent token0 (negative amount0), received token1 (positive amount1)
            amountIn = a0 < 0 ? uint256(int256(-a0)) : 0;
            amountOut = a1 > 0 ? uint256(int256(a1)) : 0;
        } else {
            // trader sent token1 (negative amount1), received token0 (positive amount0)
            amountIn = a1 < 0 ? uint256(int256(-a1)) : 0;
            amountOut = a0 > 0 ? uint256(int256(a0)) : 0;
        }

        // Update MEV tracking data with actual swap information
        _updateSwapTracking(poolAddr, amountIn);

        emit SwapObserved(poolAddr, sender, amountIn, amountOut, block.timestamp);

        uint256 score = computeMEVScoreOnchain(poolAddr, amountIn);
        if (score >= mevThreshold[poolAddr]) {
            emit MEVAlert(poolAddr, score, block.timestamp, bytes32(0));
        }

        // No protocol fee tweak in this demo (return 0)
        return (BaseHook.afterSwap.selector, 0);
    }

    // -------------------------------------------------------------------------
    // Auctions
    // -------------------------------------------------------------------------
    function startAuction(address pool, uint256 minBidWei, uint32 durationSecs) external notInEmergency {
        if (auctionsOwnerOnly) {
            require(msg.sender == owner(), "ONLY_OWNER_AUCTION");
        }
        require(isPool[pool], "POOL_NOT_ALLOWED");
        require(durationSecs > 0, "BAD_DURATION");

        uint256 auctionId = nextAuctionId[pool]++;
        uint32 startTime = uint32(block.timestamp);
        uint32 endTime = uint32(block.timestamp + durationSecs);

        auctions[pool][auctionId] = Auction({
            start: startTime,
            end: endTime,
            highestBid: 0,
            highestBidder: address(0),
            minBidPercentOrFee: defaultAuctionFeeBps, // reuse as a small field for demo
            settled: false,
            highestEffectiveBid: 0 // Initialize time-weighted bid
        });
        minBidWeiByAuction[pool][auctionId] = minBidWei;

        emit AuctionStarted(pool, auctionId, minBidWei, startTime, endTime);
    }

    function placeBid(address pool, uint256 auctionId) external payable nonReentrant notInEmergency {
        Auction storage a = auctions[pool][auctionId];
        require(a.start != 0, "NO_AUCTION");
        require(block.timestamp < a.end, "ENDED");
        require(isPool[pool], "POOL_NOT_ALLOWED");

        uint256 minBid = minBidWeiByAuction[pool][auctionId];
        require(msg.value >= minBid, "BID_LT_MIN");
        
        // Calculate time-weighted effective bid
        uint256 timeElapsed = block.timestamp - a.start;
        uint256 totalDuration = a.end - a.start;
        uint256 effectiveBid = calculateTimeWeightedBid(msg.value, timeElapsed, totalDuration);
        uint256 timeBonus = effectiveBid > msg.value ? ((effectiveBid - msg.value) * 100) / msg.value : 0;
        
        // Compare against effective highest bid, not raw bid
        require(effectiveBid > a.highestEffectiveBid, "EFFECTIVE_BID_NOT_HIGHER");

        // refund previous highest bidder (they get back their actual bid, not effective bid)
        if (a.highestBidder != address(0) && a.highestBid > 0) {
            (bool ok, ) = a.highestBidder.call{value: a.highestBid}("");
            require(ok, "REFUND_FAIL");
        }

        // Store both actual and effective bids
        a.highestBid = uint128(msg.value);
        a.highestBidder = msg.sender;
        a.highestEffectiveBid = uint128(effectiveBid);

        // Emit both regular bid event and time-weighted bid event
        emit BidPlaced(pool, auctionId, msg.sender, msg.value);
        emit TimeWeightedBid(pool, auctionId, msg.sender, msg.value, effectiveBid, timeBonus);
    }

    function finalizeAuction(address pool, uint256 auctionId) external nonReentrant notInEmergency {
        Auction storage a = auctions[pool][auctionId];
        require(a.start != 0, "NO_AUCTION");
        require(block.timestamp >= a.end, "NOT_ENDED");
        require(!a.settled, "SETTLED");
        require(isPool[pool], "POOL_NOT_ALLOWED");

        a.settled = true;

        uint256 total = uint256(a.highestBid);
        address winner = a.highestBidder;

        // Enhanced distribution: 45% to winner, 35% to treasury, 10% to protocol, 10% to insurance
        if (total > 0 && winner != address(0)) {
            uint256 toWinner = (total * 45) / 100;
            uint256 toTreasury = (total * 35) / 100;
            uint256 toProtocol = (total * 10) / 100;
            uint256 toInsurance = total - toWinner - toTreasury - toProtocol; // remaining goes to insurance

            (bool okW, ) = winner.call{value: toWinner}("");
            require(okW, "PAY_WINNER_FAIL");

            if (toTreasury > 0 && treasuryAddress != address(0)) {
                (bool okT, ) = payable(treasuryAddress).call{value: toTreasury}("");
                require(okT, "PAY_TREASURY_FAIL");
            }
            if (toProtocol > 0 && protocolAddress != address(0)) {
                (bool okP, ) = payable(protocolAddress).call{value: toProtocol}("");
                require(okP, "PAY_PROTOCOL_FAIL");
            }
            
            // Automatically fund MEV insurance with auction proceeds
            if (toInsurance > 0) {
                mevInsuranceFund[pool] += toInsurance;
                emit InsuranceTopUp(pool, toInsurance, address(this));
            }
        }

        // apply fee override for auctionOverrideDuration
        uint16 finalFeeBps = a.minBidPercentOrFee; // use field as demo fee bps
        feeOverrides[pool] = FeeOverride({
            expiresAt: uint32(block.timestamp + auctionOverrideDuration),
            feeBps: finalFeeBps
        });

        emit AuctionSettled(pool, auctionId, winner, finalFeeBps);
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------
    function setMEVThreshold(address pool, uint256 threshold) external onlyOwner {
        mevThreshold[pool] = threshold;
    }

    function setPoolAllowance(address pool, bool allowed) external onlyOwner {
        isPool[pool] = allowed;
    }

    function addAuthorizedOracle(address signer) external onlyOwner {
        isAuthorizedOracle[signer] = true;
    }

    function removeAuthorizedOracle(address signer) external onlyOwner {
        isAuthorizedOracle[signer] = false;
    }

    function setMinLargeSwap(uint256 value) external onlyOwner {
        minLargeSwap = value;
    }

    function setAuctionsOwnerOnly(bool on) external onlyOwner {
        auctionsOwnerOnly = on;
    }

    function setTreasury(address t) external onlyOwner { treasuryAddress = t; }
    function setProtocol(address p) external onlyOwner { protocolAddress = p; }

    function setDefaultAuctionFeeBps(uint16 bps) external onlyOwner { defaultAuctionFeeBps = bps; }
    function setAuctionOverrideDuration(uint32 s) external onlyOwner { auctionOverrideDuration = s; }
    function setRecommendationOverrideDuration(uint32 s) external onlyOwner { recommendationOverrideDuration = s; }

    // New admin functions for time-weighted auctions
    function setMaxTimeBonusPercent(uint256 percent) external onlyOwner {
        require(percent <= 100, "BONUS_TOO_HIGH");
        maxTimeBonusPercent = percent;
    }

    // New admin functions for MEV insurance
    function setMaxCompensationPercent(uint256 percent) external onlyOwner {
        require(percent <= 100, "COMPENSATION_TOO_HIGH"); // Max 100% compensation
        maxCompensationPercent = percent;
    }

    function setMinInsurableLoss(uint256 amount) external onlyOwner {
        minInsurableLoss = amount;
    }

    // Emergency withdrawal of insurance funds (extreme situations only)
    function emergencyWithdrawInsurance(address pool, uint256 amount, address payable to) 
        external onlyOwner {
        require(emergencyPaused, "NOT_IN_EMERGENCY");
        require(amount <= mevInsuranceFund[pool], "INSUFFICIENT_FUNDS");
        require(to != address(0), "BAD_TO");
        
        mevInsuranceFund[pool] -= amount;
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "WITHDRAWAL_FAILED");
    }

    function withdrawCollectedFees(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "BAD_TO");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "WITHDRAW_FAIL");
    }

    // -------------------------------------------------------------------------
    // Views (optional conveniences)
    // -------------------------------------------------------------------------
    function getActiveAuction(address pool) external view returns (bool active, uint256 auctionId, Auction memory a) {
        uint256 id = nextAuctionId[pool];
        if (id == 0) return (false, 0, a);
        uint256 last = id - 1;
        Auction memory lastA = auctions[pool][last];
        bool isActive = lastA.start != 0 && block.timestamp < lastA.end && !lastA.settled;
        return (isActive, last, lastA);
    }

    // -------------------------------------------------------------------------
    // Heuristic: computeMEVScoreOnchain
    // -------------------------------------------------------------------------
    function computeMEVScoreOnchain(address pool, uint256 amountIn) public view returns (uint256) {
        if (amountIn < minLargeSwap) return 0;
        
        uint256 baseScore = amountIn;
        uint256 totalScore = baseScore;
        
        // 1. Rapid consecutive swap detection
        uint256 timeSinceLastSwap = block.timestamp - lastLargeSwapTime[pool];
        if (timeSinceLastSwap > 0 && timeSinceLastSwap <= rapidSwapThreshold) {
            // Rapid swap detected - increase score significantly
            totalScore = (totalScore * consecutiveSwapBonus) / 100;
            
            // Extra bonus if amounts are similar (potential sandwich attack)
            uint256 lastAmount = lastSwapAmount[pool];
            if (lastAmount > 0) {
                uint256 ratio = amountIn > lastAmount ? (amountIn * 100) / lastAmount : (lastAmount * 100) / amountIn;
                if (ratio <= 150) { // Within 50% of each other
                    totalScore = (totalScore * 150) / 100; // 1.5x bonus
                }
            }
        }
        
        // 2. High volume detection (potential MEV bot activity)
        uint256 currentVolume = totalVolumeToday[pool];
        uint256 avgDailyVolume = _getAverageVolume(pool);
        if (avgDailyVolume > 0 && currentVolume > avgDailyVolume * highVolumeMultiplier) {
            totalScore = (totalScore * 120) / 100; // 1.2x bonus for high volume
        }
        
        // 3. Frequency-based scoring (many swaps in short time)
        uint256 swapsToday = swapCount24h[pool];
        if (swapsToday > 10) { // More than 10 swaps today
            uint256 frequencyMultiplier = 100 + (swapsToday - 10) * 5; // +5% per extra swap
            frequencyMultiplier = frequencyMultiplier > 200 ? 200 : frequencyMultiplier; // Cap at 2x
            totalScore = (totalScore * frequencyMultiplier) / 100;
        }
        
        // 4. Price impact estimation (larger swaps = higher potential MEV)
        if (amountIn > minLargeSwap * 5) { // 5x the minimum threshold
            uint256 sizeMultiplier = amountIn / (minLargeSwap * 5);
            sizeMultiplier = sizeMultiplier > 3 ? 3 : sizeMultiplier; // Cap at 3x
            totalScore = totalScore * (100 + sizeMultiplier * 10) / 100;
        }
        
        // 5. Time-based scoring (certain times more prone to MEV)
        uint256 hourOfDay = (block.timestamp / 3600) % 24;
        if ((hourOfDay >= 8 && hourOfDay <= 10) || (hourOfDay >= 14 && hourOfDay <= 16)) {
            // Peak trading hours - slightly higher MEV likelihood
            totalScore = (totalScore * 110) / 100; // 1.1x bonus
        }
        
        return totalScore;
    }
    
    // Helper function to estimate average volume (simplified for demo)
    function _getAverageVolume(address pool) internal view returns (uint256) {
        // In a real implementation, this would track historical data
        // For demo purposes, we'll use a simple heuristic based on recent activity
        uint256 recentVolume = totalVolumeToday[pool];
        if (recentVolume == 0) return minLargeSwap * 100; // Default baseline
        
        // Estimate based on current activity patterns
        return recentVolume / 2; // Assume current volume is 2x normal
    }
    
    // -------------------------------------------------------------------------
    // MEV Tracking Functions
    // -------------------------------------------------------------------------
    
    // Update swap tracking data (call this from beforeSwap or afterSwap hook)
    function _updateSwapTracking(address pool, uint256 amountIn) internal {
        // Reset daily counters if 24 hours have passed
        if (block.timestamp - lastCountReset[pool] >= 86400) { // 24 hours
            swapCount24h[pool] = 0;
            totalVolumeToday[pool] = 0;
            lastCountReset[pool] = block.timestamp;
        }
        
        // Update counters
        swapCount24h[pool]++;
        totalVolumeToday[pool] += amountIn;
        
        // Update large swap tracking
        if (amountIn >= minLargeSwap) {
            lastLargeSwapTime[pool] = block.timestamp;
            lastSwapAmount[pool] = amountIn;
        }
    }
    
    // Public function to manually trigger MEV score computation (for testing)
    function getMEVScore(address pool, uint256 amountIn) external view returns (uint256) {
        return computeMEVScoreOnchain(pool, amountIn);
    }
    
    // Owner functions to adjust MEV detection parameters
    function setMEVParameters(
        uint256 _rapidSwapThreshold,
        uint256 _highVolumeMultiplier,
        uint256 _consecutiveSwapBonus
    ) external onlyOwner {
        rapidSwapThreshold = _rapidSwapThreshold;
        highVolumeMultiplier = _highVolumeMultiplier;
        consecutiveSwapBonus = _consecutiveSwapBonus;
    }
    
    // Get comprehensive MEV analytics for a pool
    function getPoolMEVAnalytics(address pool) external view returns (
        uint256 lastSwapTime,
        uint256 lastAmount,
        uint256 swapsToday,
        uint256 volumeToday,
        uint256 currentScore
    ) {
        lastSwapTime = lastLargeSwapTime[pool];
        lastAmount = lastSwapAmount[pool];
        swapsToday = swapCount24h[pool];
        volumeToday = totalVolumeToday[pool];
        currentScore = lastAmount > 0 ? computeMEVScoreOnchain(pool, lastAmount) : 0;
    }

    // receive ether for bids
    receive() external payable {}
}
