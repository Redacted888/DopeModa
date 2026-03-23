// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * DopeModa
 * Alleywide strategy board where crews stamp territories, train muscle, and run
 * controlled raids with commit/reveal settlement.
 *
 * Design goals:
 * - No constructor parameters to fill in
 * - No external calls during game state transitions
 * - Pull-based withdrawals for all payouts
 * - Deterministic raid resolution using previous-blockhash + reveal salt
 */
contract DopeModa {
    // -----------------------------
    // Immovable chain constants
    // -----------------------------

    uint256 public constant DM_BPS_DENOM = 10_000;
    uint256 public constant DM_ZONE_COUNT = 1024;
    uint256 public constant DM_MAX_HANDLE_BYTES = 36;
    uint256 public constant DM_MAX_SLOGAN_BYTES = 44;

    // If commit is older than this, reveal becomes invalid (blockhash availability window).
    uint256 public constant DM_MAX_BLOCKHASH_LOOKBACK = 250;

    // Minimum ETH to register a gang (keeps storage spam down).
    uint256 public constant DM_REGISTER_MIN_WEI = 250_000_000_000_000; // 0.00025 ETH

    // Basic stash movement bounds.
    uint256 public constant DM_TRAIN_MIN_WEI = 100_000_000_000_000; // 0.0001 ETH

    // Raid fee size bounds (only affects pot size, not required to be large).
    uint256 public constant DM_RAID_FEE_MIN_WEI = 50_000_000_000_000; // 0.00005 ETH
    uint256 public constant DM_RAID_FEE_MAX_WEI = 5_000_000_000_000_000; // 0.005 ETH

    // Cooldowns
    uint256 public constant DM_ZONE_CLAIM_COOLDOWN = 12 hours;
    uint256 public constant DM_RAID_COOLDOWN = 10 minutes;

    // -----------------------------
    // Gang role addresses (immutable)
    // -----------------------------

    address public immutable DM_BOSS;
    address public immutable DM_QUARTERMASTER;
    address payable public immutable DM_BANK;
    address public immutable DM_SYSTEM_PROXY;

    // Launch marker (deterministic)
    uint256 public immutable DM_LAUNCH_BLOCK;

    // -----------------------------
    // Pausable + reentrancy
    // -----------------------------

    bool private _paused;
    uint256 private _reent;

    modifier whenNotPaused() {
        if (_paused) revert DM_Paused();
        _;
    }

    modifier nonReentrant() {
        if (_reent == 1) revert DM_Reentrancy();
        _reent = 1;
        _;
        _reent = 0;
    }

    modifier onlyBoss() {
        if (msg.sender != DM_BOSS) revert DM_NotBoss();
        _;
    }

    modifier onlyQuartermaster() {
        if (msg.sender != DM_QUARTERMASTER) revert DM_NotQuartermaster();
        _;
    }

    // -----------------------------
    // Storage models
    // -----------------------------

    struct Gang {
        address founder;
        bytes32 handleHash; // hash of handle string
        bytes32 sloganHash; // hash of slogan string
        uint64 createdAt;
        uint128 stashWei;
        uint64 power; // training power
        uint64 wins;
        uint64 losses;
        uint64 lastZoneActionAt;
        bool active;
    }

    struct Zone {
        uint64 gangId; // 0 means neutral
        uint32 level; // affects raid outcomes + claim cost
        uint64 defense; // grows with level, shrinks on losses
        uint64 lastClaimAt;
        bytes32 emblemHash;
    }

    struct RaidCommit {
        address raider; // msg.sender at commit time
        uint64 fromGangId;
        uint16 fromZone;
        uint16 toZone;
        uint8 tactic; // influences payout skew
        uint64 committedAt;
        bytes32 sealed; // keccak256 reveal payload hash
        uint256 potWei;
        bool revealed;
        bool settled;
    }

    // -----------------------------
    // Events & errors (unique namespace)
    // -----------------------------

    event DM_GangRegistered(uint64 indexed gangId, address indexed founder, bytes32 handleHash);
    event DM_StashFunded(uint64 indexed gangId, address indexed founder, uint256 amountWei);
    event DM_SloganSet(uint64 indexed gangId, bytes32 sloganHash);
    event DM_TrainingFired(uint64 indexed gangId, uint8 indexed trainingLine, uint256 spentWei, uint64 newPower);
    event DM_ZoneClaimed(uint64 indexed gangId, uint16 indexed zoneId, uint32 newLevel, uint64 defense);

    event DM_RaidCommitted(uint256 indexed raidId, uint64 indexed fromGangId, uint16 indexed fromZone, uint16 toZone, uint8 tactic, uint256 potWei);
    event DM_RaidRevealed(uint256 indexed raidId, address indexed raider, bytes32 revealSalt, uint256 rollBps, bool win, uint64 payoutWei);
    event DM_Withdrawal(uint256 indexed receiptId, address indexed who, uint256 amountWei);

    event DM_PauseSet(bool paused);
    event DM_Quench(uint256 indexed receiptId, address indexed who, uint256 remainingWei);

    // Treaty + Racket systems
    event DM_TreatyDeclared(uint64 indexed gangA, uint64 indexed gangB, uint64 indexed untilAt, uint16 trustBps);
    event DM_TreatyRevoked(uint64 indexed gangA, uint64 indexed gangB);
    event DM_RacketPurchased(uint64 indexed gangId, uint8 indexed rackTier, uint16 indexed routeNode, uint256 spentWei, uint64 bullets);

    error DM_NotBoss();
    error DM_NotQuartermaster();
    error DM_Paused();
    error DM_Reentrancy();

    error DM_BadValue();
    error DM_HandleTooLong();
    error DM_SloganTooLong();
    error DM_ZeroGangId();
    error DM_GangInactive();
    error DM_NotFounder();

    error DM_InvalidZone();
    error DM_ZoneOwned(uint64 gangId);
    error DM_ZoneCooldown();
    error DM_ZoneNeutralOnly();
    error DM_ZoneAlreadyActive();

    error DM_RaidCooldown();
    error DM_RaidPotInvalid();
    error DM_RaidNotFound();
    error DM_RaidAlreadyRevealed();
    error DM_RaidAlreadySettled();
    error DM_RaidRevealTooLate();
    error DM_RaidCommitMismatch();
    error DM_RaidCallerMismatch();

    error DM_InvalidTactic();
    error DM_InsufficientStash();
    error DM_EmptyWithdrawal();

    // Treaty + Racket systems
    error DM_TreatyTrustTooLow();
    error DM_TreatyDurationTooShort();
    error DM_TreatySelf();
    error DM_TreatyNotFounder();
    error DM_TreatyAlreadyActive();
    error DM_TreatyNotActive();

    error DM_RacketTierTooHigh();
    error DM_RacketStakeInvalid();
    error DM_RouteNodeOutOfRange();

    // -----------------------------
