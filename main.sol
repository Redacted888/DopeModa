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
    // Global ledger
    // -----------------------------

    uint64 public _nextGangId = 1; // 0 reserved for neutral
    mapping(uint64 => Gang) private _gangs;
    mapping(address => uint64) private _gangIdOf;
    mapping(uint16 => Zone) private _zones; // zoneId => zone

    uint256 public _nextRaidId = 1;
    mapping(uint256 => RaidCommit) private _raids;
    mapping(uint64 => uint256) public pendingWithdrawWei; // gangId => withdrawable ETH

    uint256 public _nextReceiptId = 1;

    // -----------------------------
    // Treaty + Racket state
    // -----------------------------

    // Keyed as treatyKey(min(a,b), max(a,b)).
    mapping(bytes32 => uint64) private _treatyUntilAt;
    mapping(bytes32 => uint16) private _treatyTrustBps;

    // Equipment that gangs carry into raids.
    mapping(uint64 => uint64) private _racketBullets; // grows with spent stash
    mapping(uint64 => uint8) private _racketTier; // 0..15

    uint16 public constant DM_TREATY_MIN_TRUST_BPS = 120; // 1.20%
    uint64 public constant DM_TREATY_MIN_DURATION_S = 1 hours;
    uint8 public constant DM_RACKET_MAX_TIER = 15;
    uint16 public constant DM_ROUTE_NODE_MAX = 2047;

    // -----------------------------
    // Codex (purely descriptive hashes to pad uniqueness + vibe)
    // -----------------------------

    bytes32 private constant DM_CODENAME_A = bytes32(keccak256("midnight-mahem"));
    bytes32 private constant DM_CODENAME_B = bytes32(keccak256("syringe-sunrise"));
    bytes32 private constant DM_CODENAME_C = bytes32(keccak256("alleywide-chorus"));

    bytes32[384] private constant DM_RUMORS = [
        bytes32(keccak256("rumor-0x0c7a-coldhash")),
        bytes32(keccak256("rumor-0x0c7b-dustledger")),
        bytes32(keccak256("rumor-0x0c7c-ironvow")),
        bytes32(keccak256("rumor-0x0c7d-cobaltwhisper")),
        bytes32(keccak256("rumor-0x0c7e-needletrade")),
        bytes32(keccak256("rumor-0x0c7f-limefuse")),
        bytes32(keccak256("rumor-0x0d00-vaulthush")),
        bytes32(keccak256("rumor-0x0d01-rustvibe")),
        bytes32(keccak256("rumor-0x0d02-inkrun")),
        bytes32(keccak256("rumor-0x0d03-bodega-bloom")),
        bytes32(keccak256("rumor-0x0d04-blackteeth")),
        bytes32(keccak256("rumor-0x0d05-sugarwire")),
        bytes32(keccak256("rumor-0x0d06-nightmarket")),
        bytes32(keccak256("rumor-0x0d07-hushmail")),
        bytes32(keccak256("rumor-0x0d08-alleyangel")),
        bytes32(keccak256("rumor-0x0d09-streetoracle")),
        bytes32(keccak256("rumor-0x0d0a-velvetblitz")),
        bytes32(keccak256("rumor-0x0d0b-copperkingdom")),
        bytes32(keccak256("rumor-0x0d0c-latethunder")),
        bytes32(keccak256("rumor-0x0d0d-knifecompass")),
        bytes32(keccak256("rumor-0x0d0e-silkshadow")),
        bytes32(keccak256("rumor-0x0d0f-ganggraphite")),
        bytes32(keccak256("rumor-0x0d10-ghostgrind")),
        bytes32(keccak256("rumor-0x0d11-velocidown")),
        bytes32(keccak256("rumor-0x0d12-harborholler")),
        bytes32(keccak256("rumor-0x0d13-coinconfessional")),
        bytes32(keccak256("rumor-0x0d14-bruisealphabet")),
        bytes32(keccak256("rumor-0x0d15-needle-nova")),
        bytes32(keccak256("rumor-0x0d16-moonmugshot")),
        bytes32(keccak256("rumor-0x0d17-lowsignal-highheat")),
        bytes32(keccak256("rumor-0x0d18-chalkcash")),
        bytes32(keccak256("rumor-0x0d19-scarcitysong")),
        bytes32(keccak256("rumor-0x0d1a-razorroute")),
        bytes32(keccak256("rumor-0x0d1b-cindercrown")),
        bytes32(keccak256("rumor-0x0d1c-tin-sunwalk")),
        bytes32(keccak256("rumor-0x0d1d-riverrattle")),
        bytes32(keccak256("rumor-0x0d1e-diesel-diplomat")),
        bytes32(keccak256("rumor-0x0d1f-saltstitch")),
        bytes32(keccak256("rumor-0x0d20-neon-napkin")),
        bytes32(keccak256("rumor-0x0d21-archivemayhem")),
        bytes32(keccak256("rumor-0x0d22-gritgrimoire")),
        bytes32(keccak256("rumor-0x0d23-brickballet")),
        bytes32(keccak256("rumor-0x0d24-pistolparadox")),
        bytes32(keccak256("rumor-0x0d25-cementcrush")),
        bytes32(keccak256("rumor-0x0d26-splinterstar")),
        bytes32(keccak256("rumor-0x0d27-tunneltheremin")),
        bytes32(keccak256("rumor-0x0d28-gutterglow")),
        bytes32(keccak256("rumor-0x0d29-ironinbox")),
        bytes32(keccak256("rumor-0x0d2a-hushhymn")),
        bytes32(keccak256("rumor-0x0d2b-knife-kiosk")),
        bytes32(keccak256("rumor-0x0d2c-razorraindrop")),
        bytes32(keccak256("rumor-0x0d2d-crowndraft")),
        bytes32(keccak256("rumor-0x0d2e-slate-sprint")),
