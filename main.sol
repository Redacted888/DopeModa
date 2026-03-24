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
        bytes32(keccak256("rumor-0x0d2f-bodega-bulldog")),
        bytes32(keccak256("rumor-0x0d30-shivship")),
        bytes32(keccak256("rumor-0x0d31-inkinfusion")),
        bytes32(keccak256("rumor-0x0d32-streetsteward")),
        bytes32(keccak256("rumor-0x0d33-coldcoincarver")),
        bytes32(keccak256("rumor-0x0d34-lanternlogic")),
        bytes32(keccak256("rumor-0x0d35-mintmurder")),
        bytes32(keccak256("rumor-0x0d36-rubberrevival")),
        bytes32(keccak256("rumor-0x0d37-casino-crows")),
        bytes32(keccak256("rumor-0x0d38-blackbloom")),
        bytes32(keccak256("rumor-0x0d39-slicksentinel")),
        bytes32(keccak256("rumor-0x0d3a-velocityvow")),
        bytes32(keccak256("rumor-0x0d3b-chiselchime")),
        bytes32(keccak256("rumor-0x0d3c-sparkwarrant")),
        bytes32(keccak256("rumor-0x0d3d-ghostgossip")),
        bytes32(keccak256("rumor-0x0d3e-emberedit")),
        bytes32(keccak256("rumor-0x0d3f-fingerprintfig")),
        bytes32(keccak256("rumor-0x0d40-emberindex")),
        bytes32(keccak256("rumor-0x0d41-chromeconfetti")),
        bytes32(keccak256("rumor-0x0d42-saffronswivel")),
        bytes32(keccak256("rumor-0x0d43-velourvanguard")),
        bytes32(keccak256("rumor-0x0d44-cinderclerk")),
        bytes32(keccak256("rumor-0x0d45-ironivy")),
        bytes32(keccak256("rumor-0x0d46-slowshock")),
        bytes32(keccak256("rumor-0x0d47-slate-soldier")),
        bytes32(keccak256("rumor-0x0d48-guttergospel")),
        bytes32(keccak256("rumor-0x0d49-coppercarnival")),
        bytes32(keccak256("rumor-0x0d4a-tin-talon")),
        bytes32(keccak256("rumor-0x0d4b-moonmortar")),
        bytes32(keccak256("rumor-0x0d4c-crackcabinet")),
        bytes32(keccak256("rumor-0x0d4d-scarletstair")),
        bytes32(keccak256("rumor-0x0d4e-knife-ink")),
        bytes32(keccak256("rumor-0x0d4f-chalkchaos")),
        bytes32(keccak256("rumor-0x0d50-heatheir")),
        bytes32(keccak256("rumor-0x0d51-silksabotage")),
        bytes32(keccak256("rumor-0x0d52-velvetvigil")),
        bytes32(keccak256("rumor-0x0d53-lanewaylegend")),
        bytes32(keccak256("rumor-0x0d54-ironlullaby")),
        bytes32(keccak256("rumor-0x0d55-streetstapler")),
        bytes32(keccak256("rumor-0x0d56-razorrhythm")),
        bytes32(keccak256("rumor-0x0d57-alleyanvil")),
        bytes32(keccak256("rumor-0x0d58-duskdebug")),
        bytes32(keccak256("rumor-0x0d59-cindercircuit")),
        bytes32(keccak256("rumor-0x0d5a-bootlegbloom")),
        bytes32(keccak256("rumor-0x0d5b-gunmetalgraffiti")),
        bytes32(keccak256("rumor-0x0d5c-motelmirage")),
        bytes32(keccak256("rumor-0x0d5d-hushharvest")),
        bytes32(keccak256("rumor-0x0d5e-vaultverse")),
        bytes32(keccak256("rumor-0x0d5f-knifecompass-ii")),
        bytes32(keccak256("rumor-0x0d60-frostfable")),
        bytes32(keccak256("rumor-0x0d61-mortarmoon")),
        bytes32(keccak256("rumor-0x0d62-dieseldevotion")),
        bytes32(keccak256("rumor-0x0d63-coppercrush")),
        bytes32(keccak256("rumor-0x0d64-velourvault")),
        bytes32(keccak256("rumor-0x0d65-crumbcrew")),
        bytes32(keccak256("rumor-0x0d66-rustrelic")),
        bytes32(keccak256("rumor-0x0d67-mirrormenace")),
        bytes32(keccak256("rumor-0x0d68-emberenvelope")),
        bytes32(keccak256("rumor-0x0d69-needleneon")),
        bytes32(keccak256("rumor-0x0d6a-scarcityspells")),
        bytes32(keccak256("rumor-0x0d6b-chalkchaser")),
        bytes32(keccak256("rumor-0x0d6c-tintrouble")),
        bytes32(keccak256("rumor-0x0d6d-inkinterrogation")),
        bytes32(keccak256("rumor-0x0d6e-blackbadge")),
        bytes32(keccak256("rumor-0x0d6f-sugarstack")),
        bytes32(keccak256("rumor-0x0d70-ghostgrinder")),
        bytes32(keccak256("rumor-0x0d71-velocigrail")),
        bytes32(keccak256("rumor-0x0d72-alleyarbiter")),
        bytes32(keccak256("rumor-0x0d73-ironidol")),
        bytes32(keccak256("rumor-0x0d74-coldcarnival")),
        bytes32(keccak256("rumor-0x0d75-inkisland")),
        bytes32(keccak256("rumor-0x0d76-dustduke")),
        bytes32(keccak256("rumor-0x0d77-razorresonance")),
        bytes32(keccak256("rumor-0x0d78-slatehustle")),
        bytes32(keccak256("rumor-0x0d79-neonnectar")),
        bytes32(keccak256("rumor-0x0d7a-coppercodex")),
        bytes32(keccak256("rumor-0x0d7b-velvetvoltage")),
        bytes32(keccak256("rumor-0x0d7c-guttergem")),
        bytes32(keccak256("rumor-0x0d7d-tintriumph")),
        bytes32(keccak256("rumor-0x0d7e-nightnotary")),
        bytes32(keccak256("rumor-0x0d7f-emberenclave")),
        bytes32(keccak256("rumor-0x0d80")),
        bytes32(keccak256("rumor-0x0d81")),
        bytes32(keccak256("rumor-0x0d82")),
        bytes32(keccak256("rumor-0x0d83")),
        bytes32(keccak256("rumor-0x0d84")),
        bytes32(keccak256("rumor-0x0d85")),
        bytes32(keccak256("rumor-0x0d86")),
        bytes32(keccak256("rumor-0x0d87")),
        bytes32(keccak256("rumor-0x0d88")),
        bytes32(keccak256("rumor-0x0d89")),
        bytes32(keccak256("rumor-0x0d8a")),
        bytes32(keccak256("rumor-0x0d8b")),
        bytes32(keccak256("rumor-0x0d8c")),
        bytes32(keccak256("rumor-0x0d8d")),
        bytes32(keccak256("rumor-0x0d8e")),
        bytes32(keccak256("rumor-0x0d8f")),
        bytes32(keccak256("rumor-0x0d90")),
        bytes32(keccak256("rumor-0x0d91")),
        bytes32(keccak256("rumor-0x0d92")),
        bytes32(keccak256("rumor-0x0d93")),
        bytes32(keccak256("rumor-0x0d94")),
        bytes32(keccak256("rumor-0x0d95")),
        bytes32(keccak256("rumor-0x0d96")),
        bytes32(keccak256("rumor-0x0d97")),
        bytes32(keccak256("rumor-0x0d98")),
        bytes32(keccak256("rumor-0x0d99")),
        bytes32(keccak256("rumor-0x0d9a")),
        bytes32(keccak256("rumor-0x0d9b")),
        bytes32(keccak256("rumor-0x0d9c")),
        bytes32(keccak256("rumor-0x0d9d")),
        bytes32(keccak256("rumor-0x0d9e")),
        bytes32(keccak256("rumor-0x0d9f")),
        bytes32(keccak256("rumor-0x0da0")),
        bytes32(keccak256("rumor-0x0da1")),
        bytes32(keccak256("rumor-0x0da2")),
        bytes32(keccak256("rumor-0x0da3")),
        bytes32(keccak256("rumor-0x0da4")),
        bytes32(keccak256("rumor-0x0da5")),
        bytes32(keccak256("rumor-0x0da6")),
        bytes32(keccak256("rumor-0x0da7")),
        bytes32(keccak256("rumor-0x0da8")),
        bytes32(keccak256("rumor-0x0da9")),
        bytes32(keccak256("rumor-0x0daa")),
        bytes32(keccak256("rumor-0x0dab")),
        bytes32(keccak256("rumor-0x0dac")),
        bytes32(keccak256("rumor-0x0dad")),
        bytes32(keccak256("rumor-0x0dae")),
        bytes32(keccak256("rumor-0x0daf")),
        bytes32(keccak256("rumor-0x0db0")),
        bytes32(keccak256("rumor-0x0db1")),
        bytes32(keccak256("rumor-0x0db2")),
        bytes32(keccak256("rumor-0x0db3")),
        bytes32(keccak256("rumor-0x0db4")),
        bytes32(keccak256("rumor-0x0db5")),
        bytes32(keccak256("rumor-0x0db6")),
        bytes32(keccak256("rumor-0x0db7")),
        bytes32(keccak256("rumor-0x0db8")),
        bytes32(keccak256("rumor-0x0db9")),
        bytes32(keccak256("rumor-0x0dba")),
        bytes32(keccak256("rumor-0x0dbb")),
        bytes32(keccak256("rumor-0x0dbc")),
        bytes32(keccak256("rumor-0x0dbd")),
        bytes32(keccak256("rumor-0x0dbe")),
        bytes32(keccak256("rumor-0x0dbf")),
        bytes32(keccak256("rumor-0x0dc0")),
        bytes32(keccak256("rumor-0x0dc1")),
        bytes32(keccak256("rumor-0x0dc2")),
        bytes32(keccak256("rumor-0x0dc3")),
        bytes32(keccak256("rumor-0x0dc4")),
        bytes32(keccak256("rumor-0x0dc5")),
        bytes32(keccak256("rumor-0x0dc6")),
        bytes32(keccak256("rumor-0x0dc7")),
        bytes32(keccak256("rumor-0x0dc8")),
        bytes32(keccak256("rumor-0x0dc9")),
        bytes32(keccak256("rumor-0x0dca")),
        bytes32(keccak256("rumor-0x0dcb")),
        bytes32(keccak256("rumor-0x0dcc")),
        bytes32(keccak256("rumor-0x0dcd")),
        bytes32(keccak256("rumor-0x0dce")),
        bytes32(keccak256("rumor-0x0dcf")),
        bytes32(keccak256("rumor-0x0dd0")),
        bytes32(keccak256("rumor-0x0dd1")),
        bytes32(keccak256("rumor-0x0dd2")),
        bytes32(keccak256("rumor-0x0dd3")),
        bytes32(keccak256("rumor-0x0dd4")),
        bytes32(keccak256("rumor-0x0dd5")),
        bytes32(keccak256("rumor-0x0dd6")),
        bytes32(keccak256("rumor-0x0dd7")),
        bytes32(keccak256("rumor-0x0dd8")),
        bytes32(keccak256("rumor-0x0dd9")),
        bytes32(keccak256("rumor-0x0dda")),
        bytes32(keccak256("rumor-0x0ddb")),
        bytes32(keccak256("rumor-0x0ddc")),
        bytes32(keccak256("rumor-0x0ddd")),
        bytes32(keccak256("rumor-0x0dde")),
        bytes32(keccak256("rumor-0x0ddf")),
        bytes32(keccak256("rumor-0x0de0")),
        bytes32(keccak256("rumor-0x0de1")),
        bytes32(keccak256("rumor-0x0de2")),
        bytes32(keccak256("rumor-0x0de3")),
        bytes32(keccak256("rumor-0x0de4")),
        bytes32(keccak256("rumor-0x0de5")),
        bytes32(keccak256("rumor-0x0de6")),
        bytes32(keccak256("rumor-0x0de7")),
        bytes32(keccak256("rumor-0x0de8")),
        bytes32(keccak256("rumor-0x0de9")),
        bytes32(keccak256("rumor-0x0dea")),
        bytes32(keccak256("rumor-0x0deb")),
        bytes32(keccak256("rumor-0x0dec")),
        bytes32(keccak256("rumor-0x0ded")),
        bytes32(keccak256("rumor-0x0dee")),
        bytes32(keccak256("rumor-0x0def")),
        bytes32(keccak256("rumor-0x0df0")),
        bytes32(keccak256("rumor-0x0df1")),
        bytes32(keccak256("rumor-0x0df2")),
        bytes32(keccak256("rumor-0x0df3")),
        bytes32(keccak256("rumor-0x0df4")),
        bytes32(keccak256("rumor-0x0df5")),
        bytes32(keccak256("rumor-0x0df6")),
        bytes32(keccak256("rumor-0x0df7")),
        bytes32(keccak256("rumor-0x0df8")),
        bytes32(keccak256("rumor-0x0df9")),
        bytes32(keccak256("rumor-0x0dfa")),
        bytes32(keccak256("rumor-0x0dfb")),
        bytes32(keccak256("rumor-0x0dfc")),
        bytes32(keccak256("rumor-0x0dfd")),
        bytes32(keccak256("rumor-0x0dfe")),
        bytes32(keccak256("rumor-0x0dff")),
        bytes32(keccak256("rumor-0x0e00")),
        bytes32(keccak256("rumor-0x0e01")),
        bytes32(keccak256("rumor-0x0e02")),
        bytes32(keccak256("rumor-0x0e03")),
        bytes32(keccak256("rumor-0x0e04")),
        bytes32(keccak256("rumor-0x0e05")),
        bytes32(keccak256("rumor-0x0e06")),
        bytes32(keccak256("rumor-0x0e07")),
        bytes32(keccak256("rumor-0x0e08")),
        bytes32(keccak256("rumor-0x0e09")),
        bytes32(keccak256("rumor-0x0e0a")),
        bytes32(keccak256("rumor-0x0e0b")),
        bytes32(keccak256("rumor-0x0e0c")),
        bytes32(keccak256("rumor-0x0e0d")),
        bytes32(keccak256("rumor-0x0e0e")),
        bytes32(keccak256("rumor-0x0e0f")),
        bytes32(keccak256("rumor-0x0e10")),
        bytes32(keccak256("rumor-0x0e11")),
        bytes32(keccak256("rumor-0x0e12")),
        bytes32(keccak256("rumor-0x0e13")),
        bytes32(keccak256("rumor-0x0e14")),
        bytes32(keccak256("rumor-0x0e15")),
        bytes32(keccak256("rumor-0x0e16")),
        bytes32(keccak256("rumor-0x0e17")),
        bytes32(keccak256("rumor-0x0e18")),
        bytes32(keccak256("rumor-0x0e19")),
        bytes32(keccak256("rumor-0x0e1a")),
        bytes32(keccak256("rumor-0x0e1b")),
        bytes32(keccak256("rumor-0x0e1c")),
        bytes32(keccak256("rumor-0x0e1d")),
        bytes32(keccak256("rumor-0x0e1e")),
        bytes32(keccak256("rumor-0x0e1f")),
        bytes32(keccak256("rumor-0x0e20")),
        bytes32(keccak256("rumor-0x0e21")),
        bytes32(keccak256("rumor-0x0e22")),
        bytes32(keccak256("rumor-0x0e23")),
        bytes32(keccak256("rumor-0x0e24")),
        bytes32(keccak256("rumor-0x0e25")),
        bytes32(keccak256("rumor-0x0e26")),
        bytes32(keccak256("rumor-0x0e27")),
        bytes32(keccak256("rumor-0x0e28")),
        bytes32(keccak256("rumor-0x0e29")),
        bytes32(keccak256("rumor-0x0e2a")),
        bytes32(keccak256("rumor-0x0e2b")),
        bytes32(keccak256("rumor-0x0e2c")),
        bytes32(keccak256("rumor-0x0e2d")),
        bytes32(keccak256("rumor-0x0e2e")),
        bytes32(keccak256("rumor-0x0e2f")),
        bytes32(keccak256("rumor-0x0e30")),
        bytes32(keccak256("rumor-0x0e31")),
        bytes32(keccak256("rumor-0x0e32")),
        bytes32(keccak256("rumor-0x0e33")),
        bytes32(keccak256("rumor-0x0e34")),
        bytes32(keccak256("rumor-0x0e35")),
        bytes32(keccak256("rumor-0x0e36")),
        bytes32(keccak256("rumor-0x0e37")),
        bytes32(keccak256("rumor-0x0e38")),
        bytes32(keccak256("rumor-0x0e39")),
        bytes32(keccak256("rumor-0x0e3a")),
        bytes32(keccak256("rumor-0x0e3b")),
        bytes32(keccak256("rumor-0x0e3c")),
        bytes32(keccak256("rumor-0x0e3d")),
        bytes32(keccak256("rumor-0x0e3e")),
        bytes32(keccak256("rumor-0x0e3f")),
        bytes32(keccak256("rumor-0x0e40")),
        bytes32(keccak256("rumor-0x0e41")),
        bytes32(keccak256("rumor-0x0e42")),
        bytes32(keccak256("rumor-0x0e43")),
        bytes32(keccak256("rumor-0x0e44")),
        bytes32(keccak256("rumor-0x0e45")),
        bytes32(keccak256("rumor-0x0e46")),
        bytes32(keccak256("rumor-0x0e47")),
        bytes32(keccak256("rumor-0x0e48")),
        bytes32(keccak256("rumor-0x0e49")),
        bytes32(keccak256("rumor-0x0e4a")),
        bytes32(keccak256("rumor-0x0e4b")),
        bytes32(keccak256("rumor-0x0e4c")),
        bytes32(keccak256("rumor-0x0e4d")),
        bytes32(keccak256("rumor-0x0e4e")),
        bytes32(keccak256("rumor-0x0e4f")),
        bytes32(keccak256("rumor-0x0e50")),
        bytes32(keccak256("rumor-0x0e51")),
        bytes32(keccak256("rumor-0x0e52")),
        bytes32(keccak256("rumor-0x0e53")),
        bytes32(keccak256("rumor-0x0e54")),
        bytes32(keccak256("rumor-0x0e55")),
        bytes32(keccak256("rumor-0x0e56")),
        bytes32(keccak256("rumor-0x0e57")),
        bytes32(keccak256("rumor-0x0e58")),
        bytes32(keccak256("rumor-0x0e59")),
        bytes32(keccak256("rumor-0x0e5a")),
        bytes32(keccak256("rumor-0x0e5b")),
        bytes32(keccak256("rumor-0x0e5c")),
        bytes32(keccak256("rumor-0x0e5d")),
        bytes32(keccak256("rumor-0x0e5e")),
        bytes32(keccak256("rumor-0x0e5f")),
        bytes32(keccak256("rumor-0x0e60")),
        bytes32(keccak256("rumor-0x0e61")),
        bytes32(keccak256("rumor-0x0e62")),
        bytes32(keccak256("rumor-0x0e63")),
        bytes32(keccak256("rumor-0x0e64")),
        bytes32(keccak256("rumor-0x0e65")),
        bytes32(keccak256("rumor-0x0e66")),
        bytes32(keccak256("rumor-0x0e67")),
        bytes32(keccak256("rumor-0x0e68")),
        bytes32(keccak256("rumor-0x0e69")),
        bytes32(keccak256("rumor-0x0e6a")),
        bytes32(keccak256("rumor-0x0e6b")),
        bytes32(keccak256("rumor-0x0e6c")),
        bytes32(keccak256("rumor-0x0e6d")),
        bytes32(keccak256("rumor-0x0e6e")),
        bytes32(keccak256("rumor-0x0e6f")),
        bytes32(keccak256("rumor-0x0e70")),
        bytes32(keccak256("rumor-0x0e71")),
        bytes32(keccak256("rumor-0x0e72")),
        bytes32(keccak256("rumor-0x0e73")),
        bytes32(keccak256("rumor-0x0e74")),
        bytes32(keccak256("rumor-0x0e75")),
        bytes32(keccak256("rumor-0x0e76")),
        bytes32(keccak256("rumor-0x0e77")),
        bytes32(keccak256("rumor-0x0e78")),
        bytes32(keccak256("rumor-0x0e79")),
        bytes32(keccak256("rumor-0x0e7a")),
        bytes32(keccak256("rumor-0x0e7b")),
        bytes32(keccak256("rumor-0x0e7c")),
        bytes32(keccak256("rumor-0x0e7d")),
        bytes32(keccak256("rumor-0x0e7e")),
        bytes32(keccak256("rumor-0x0e7f"))
    ];

    // Warflag codex: used to skew raid outcomes (all deterministic).
    bytes32[256] private constant DM_WARFLAGS = [
        bytes32(keccak256("warflag-0x00")),
        bytes32(keccak256("warflag-0x01")),
        bytes32(keccak256("warflag-0x02")),
        bytes32(keccak256("warflag-0x03")),
        bytes32(keccak256("warflag-0x04")),
        bytes32(keccak256("warflag-0x05")),
        bytes32(keccak256("warflag-0x06")),
        bytes32(keccak256("warflag-0x07")),
        bytes32(keccak256("warflag-0x08")),
        bytes32(keccak256("warflag-0x09")),
        bytes32(keccak256("warflag-0x0a")),
        bytes32(keccak256("warflag-0x0b")),
        bytes32(keccak256("warflag-0x0c")),
        bytes32(keccak256("warflag-0x0d")),
        bytes32(keccak256("warflag-0x0e")),
        bytes32(keccak256("warflag-0x0f")),
        bytes32(keccak256("warflag-0x10")),
        bytes32(keccak256("warflag-0x11")),
        bytes32(keccak256("warflag-0x12")),
        bytes32(keccak256("warflag-0x13")),
        bytes32(keccak256("warflag-0x14")),
        bytes32(keccak256("warflag-0x15")),
        bytes32(keccak256("warflag-0x16")),
        bytes32(keccak256("warflag-0x17")),
        bytes32(keccak256("warflag-0x18")),
        bytes32(keccak256("warflag-0x19")),
        bytes32(keccak256("warflag-0x1a")),
        bytes32(keccak256("warflag-0x1b")),
        bytes32(keccak256("warflag-0x1c")),
        bytes32(keccak256("warflag-0x1d")),
        bytes32(keccak256("warflag-0x1e")),
        bytes32(keccak256("warflag-0x1f")),
        bytes32(keccak256("warflag-0x20")),
        bytes32(keccak256("warflag-0x21")),
        bytes32(keccak256("warflag-0x22")),
        bytes32(keccak256("warflag-0x23")),
        bytes32(keccak256("warflag-0x24")),
        bytes32(keccak256("warflag-0x25")),
        bytes32(keccak256("warflag-0x26")),
        bytes32(keccak256("warflag-0x27")),
        bytes32(keccak256("warflag-0x28")),
        bytes32(keccak256("warflag-0x29")),
        bytes32(keccak256("warflag-0x2a")),
        bytes32(keccak256("warflag-0x2b")),
        bytes32(keccak256("warflag-0x2c")),
        bytes32(keccak256("warflag-0x2d")),
        bytes32(keccak256("warflag-0x2e")),
        bytes32(keccak256("warflag-0x2f")),
        bytes32(keccak256("warflag-0x30")),
        bytes32(keccak256("warflag-0x31")),
        bytes32(keccak256("warflag-0x32")),
        bytes32(keccak256("warflag-0x33")),
        bytes32(keccak256("warflag-0x34")),
        bytes32(keccak256("warflag-0x35")),
        bytes32(keccak256("warflag-0x36")),
        bytes32(keccak256("warflag-0x37")),
        bytes32(keccak256("warflag-0x38")),
        bytes32(keccak256("warflag-0x39")),
        bytes32(keccak256("warflag-0x3a")),
        bytes32(keccak256("warflag-0x3b")),
        bytes32(keccak256("warflag-0x3c")),
        bytes32(keccak256("warflag-0x3d")),
        bytes32(keccak256("warflag-0x3e")),
        bytes32(keccak256("warflag-0x3f")),
        bytes32(keccak256("warflag-0x40")),
        bytes32(keccak256("warflag-0x41")),
        bytes32(keccak256("warflag-0x42")),
        bytes32(keccak256("warflag-0x43")),
        bytes32(keccak256("warflag-0x44")),
        bytes32(keccak256("warflag-0x45")),
        bytes32(keccak256("warflag-0x46")),
        bytes32(keccak256("warflag-0x47")),
        bytes32(keccak256("warflag-0x48")),
        bytes32(keccak256("warflag-0x49")),
        bytes32(keccak256("warflag-0x4a")),
        bytes32(keccak256("warflag-0x4b")),
        bytes32(keccak256("warflag-0x4c")),
        bytes32(keccak256("warflag-0x4d")),
        bytes32(keccak256("warflag-0x4e")),
        bytes32(keccak256("warflag-0x4f")),
        bytes32(keccak256("warflag-0x50")),
        bytes32(keccak256("warflag-0x51")),
        bytes32(keccak256("warflag-0x52")),
        bytes32(keccak256("warflag-0x53")),
        bytes32(keccak256("warflag-0x54")),
        bytes32(keccak256("warflag-0x55")),
        bytes32(keccak256("warflag-0x56")),
        bytes32(keccak256("warflag-0x57")),
        bytes32(keccak256("warflag-0x58")),
        bytes32(keccak256("warflag-0x59")),
        bytes32(keccak256("warflag-0x5a")),
        bytes32(keccak256("warflag-0x5b")),
        bytes32(keccak256("warflag-0x5c")),
        bytes32(keccak256("warflag-0x5d")),
        bytes32(keccak256("warflag-0x5e")),
        bytes32(keccak256("warflag-0x5f")),
        bytes32(keccak256("warflag-0x60")),
        bytes32(keccak256("warflag-0x61")),
        bytes32(keccak256("warflag-0x62")),
        bytes32(keccak256("warflag-0x63")),
        bytes32(keccak256("warflag-0x64")),
        bytes32(keccak256("warflag-0x65")),
        bytes32(keccak256("warflag-0x66")),
        bytes32(keccak256("warflag-0x67")),
        bytes32(keccak256("warflag-0x68")),
        bytes32(keccak256("warflag-0x69")),
        bytes32(keccak256("warflag-0x6a")),
        bytes32(keccak256("warflag-0x6b")),
        bytes32(keccak256("warflag-0x6c")),
        bytes32(keccak256("warflag-0x6d")),
        bytes32(keccak256("warflag-0x6e")),
        bytes32(keccak256("warflag-0x6f")),
        bytes32(keccak256("warflag-0x70")),
        bytes32(keccak256("warflag-0x71")),
        bytes32(keccak256("warflag-0x72")),
        bytes32(keccak256("warflag-0x73")),
        bytes32(keccak256("warflag-0x74")),
        bytes32(keccak256("warflag-0x75")),
        bytes32(keccak256("warflag-0x76")),
        bytes32(keccak256("warflag-0x77")),
        bytes32(keccak256("warflag-0x78")),
        bytes32(keccak256("warflag-0x79")),
        bytes32(keccak256("warflag-0x7a")),
        bytes32(keccak256("warflag-0x7b")),
        bytes32(keccak256("warflag-0x7c")),
        bytes32(keccak256("warflag-0x7d")),
        bytes32(keccak256("warflag-0x7e")),
        bytes32(keccak256("warflag-0x7f")),
        bytes32(keccak256("warflag-0x80")),
        bytes32(keccak256("warflag-0x81")),
        bytes32(keccak256("warflag-0x82")),
        bytes32(keccak256("warflag-0x83")),
        bytes32(keccak256("warflag-0x84")),
        bytes32(keccak256("warflag-0x85")),
        bytes32(keccak256("warflag-0x86")),
        bytes32(keccak256("warflag-0x87")),
        bytes32(keccak256("warflag-0x88")),
        bytes32(keccak256("warflag-0x89")),
        bytes32(keccak256("warflag-0x8a")),
        bytes32(keccak256("warflag-0x8b")),
        bytes32(keccak256("warflag-0x8c")),
        bytes32(keccak256("warflag-0x8d")),
        bytes32(keccak256("warflag-0x8e")),
        bytes32(keccak256("warflag-0x8f")),
        bytes32(keccak256("warflag-0x90")),
        bytes32(keccak256("warflag-0x91")),
        bytes32(keccak256("warflag-0x92")),
        bytes32(keccak256("warflag-0x93")),
        bytes32(keccak256("warflag-0x94")),
        bytes32(keccak256("warflag-0x95")),
        bytes32(keccak256("warflag-0x96")),
        bytes32(keccak256("warflag-0x97")),
        bytes32(keccak256("warflag-0x98")),
        bytes32(keccak256("warflag-0x99")),
        bytes32(keccak256("warflag-0x9a")),
        bytes32(keccak256("warflag-0x9b")),
        bytes32(keccak256("warflag-0x9c")),
        bytes32(keccak256("warflag-0x9d")),
        bytes32(keccak256("warflag-0x9e")),
        bytes32(keccak256("warflag-0x9f")),
        bytes32(keccak256("warflag-0xa0")),
        bytes32(keccak256("warflag-0xa1")),
        bytes32(keccak256("warflag-0xa2")),
        bytes32(keccak256("warflag-0xa3")),
        bytes32(keccak256("warflag-0xa4")),
        bytes32(keccak256("warflag-0xa5")),
        bytes32(keccak256("warflag-0xa6")),
        bytes32(keccak256("warflag-0xa7")),
        bytes32(keccak256("warflag-0xa8")),
        bytes32(keccak256("warflag-0xa9")),
        bytes32(keccak256("warflag-0xaa")),
        bytes32(keccak256("warflag-0xab")),
        bytes32(keccak256("warflag-0xac")),
        bytes32(keccak256("warflag-0xad")),
        bytes32(keccak256("warflag-0xae")),
        bytes32(keccak256("warflag-0xaf")),
        bytes32(keccak256("warflag-0xb0")),
        bytes32(keccak256("warflag-0xb1")),
        bytes32(keccak256("warflag-0xb2")),
        bytes32(keccak256("warflag-0xb3")),
        bytes32(keccak256("warflag-0xb4")),
        bytes32(keccak256("warflag-0xb5")),
        bytes32(keccak256("warflag-0xb6")),
        bytes32(keccak256("warflag-0xb7")),
        bytes32(keccak256("warflag-0xb8")),
        bytes32(keccak256("warflag-0xb9")),
        bytes32(keccak256("warflag-0xba")),
        bytes32(keccak256("warflag-0xbb")),
        bytes32(keccak256("warflag-0xbc")),
        bytes32(keccak256("warflag-0xbd")),
        bytes32(keccak256("warflag-0xbe")),
        bytes32(keccak256("warflag-0xbf")),
        bytes32(keccak256("warflag-0xc0")),
        bytes32(keccak256("warflag-0xc1")),
        bytes32(keccak256("warflag-0xc2")),
        bytes32(keccak256("warflag-0xc3")),
        bytes32(keccak256("warflag-0xc4")),
        bytes32(keccak256("warflag-0xc5")),
        bytes32(keccak256("warflag-0xc6")),
        bytes32(keccak256("warflag-0xc7")),
        bytes32(keccak256("warflag-0xc8")),
        bytes32(keccak256("warflag-0xc9")),
        bytes32(keccak256("warflag-0xca")),
        bytes32(keccak256("warflag-0xcb")),
        bytes32(keccak256("warflag-0xcc")),
        bytes32(keccak256("warflag-0xcd")),
        bytes32(keccak256("warflag-0xce")),
        bytes32(keccak256("warflag-0xcf")),
        bytes32(keccak256("warflag-0xd0")),
        bytes32(keccak256("warflag-0xd1")),
        bytes32(keccak256("warflag-0xd2")),
        bytes32(keccak256("warflag-0xd3")),
        bytes32(keccak256("warflag-0xd4")),
        bytes32(keccak256("warflag-0xd5")),
        bytes32(keccak256("warflag-0xd6")),
        bytes32(keccak256("warflag-0xd7")),
        bytes32(keccak256("warflag-0xd8")),
        bytes32(keccak256("warflag-0xd9")),
        bytes32(keccak256("warflag-0xda")),
        bytes32(keccak256("warflag-0xdb")),
        bytes32(keccak256("warflag-0xdc")),
        bytes32(keccak256("warflag-0xdd")),
        bytes32(keccak256("warflag-0xde")),
        bytes32(keccak256("warflag-0xdf")),
        bytes32(keccak256("warflag-0xe0")),
        bytes32(keccak256("warflag-0xe1")),
        bytes32(keccak256("warflag-0xe2")),
        bytes32(keccak256("warflag-0xe3")),
        bytes32(keccak256("warflag-0xe4")),
        bytes32(keccak256("warflag-0xe5")),
        bytes32(keccak256("warflag-0xe6")),
        bytes32(keccak256("warflag-0xe7")),
        bytes32(keccak256("warflag-0xe8")),
        bytes32(keccak256("warflag-0xe9")),
        bytes32(keccak256("warflag-0xea")),
        bytes32(keccak256("warflag-0xeb")),
        bytes32(keccak256("warflag-0xec")),
        bytes32(keccak256("warflag-0xed")),
        bytes32(keccak256("warflag-0xee")),
        bytes32(keccak256("warflag-0xef")),
        bytes32(keccak256("warflag-0xf0")),
        bytes32(keccak256("warflag-0xf1")),
        bytes32(keccak256("warflag-0xf2")),
        bytes32(keccak256("warflag-0xf3")),
        bytes32(keccak256("warflag-0xf4")),
        bytes32(keccak256("warflag-0xf5")),
        bytes32(keccak256("warflag-0xf6")),
        bytes32(keccak256("warflag-0xf7")),
        bytes32(keccak256("warflag-0xf8")),
        bytes32(keccak256("warflag-0xf9")),
        bytes32(keccak256("warflag-0xfa")),
        bytes32(keccak256("warflag-0xfb")),
        bytes32(keccak256("warflag-0xfc")),
        bytes32(keccak256("warflag-0xfd")),
        bytes32(keccak256("warflag-0xfe")),
        bytes32(keccak256("warflag-0xff"))
    ];

    // Graffiti signatures: influences codex digests for UIs.
    bytes32[256] private constant DM_GRAFFITI_SIGS = [
        bytes32(keccak256("graffiti-0x00")),
        bytes32(keccak256("graffiti-0x01")),
        bytes32(keccak256("graffiti-0x02")),
        bytes32(keccak256("graffiti-0x03")),
        bytes32(keccak256("graffiti-0x04")),
        bytes32(keccak256("graffiti-0x05")),
        bytes32(keccak256("graffiti-0x06")),
        bytes32(keccak256("graffiti-0x07")),
        bytes32(keccak256("graffiti-0x08")),
        bytes32(keccak256("graffiti-0x09")),
        bytes32(keccak256("graffiti-0x0a")),
        bytes32(keccak256("graffiti-0x0b")),
        bytes32(keccak256("graffiti-0x0c")),
        bytes32(keccak256("graffiti-0x0d")),
        bytes32(keccak256("graffiti-0x0e")),
        bytes32(keccak256("graffiti-0x0f")),
        bytes32(keccak256("graffiti-0x10")),
        bytes32(keccak256("graffiti-0x11")),
        bytes32(keccak256("graffiti-0x12")),
        bytes32(keccak256("graffiti-0x13")),
        bytes32(keccak256("graffiti-0x14")),
        bytes32(keccak256("graffiti-0x15")),
        bytes32(keccak256("graffiti-0x16")),
        bytes32(keccak256("graffiti-0x17")),
        bytes32(keccak256("graffiti-0x18")),
        bytes32(keccak256("graffiti-0x19")),
        bytes32(keccak256("graffiti-0x1a")),
        bytes32(keccak256("graffiti-0x1b")),
        bytes32(keccak256("graffiti-0x1c")),
        bytes32(keccak256("graffiti-0x1d")),
        bytes32(keccak256("graffiti-0x1e")),
        bytes32(keccak256("graffiti-0x1f")),
        bytes32(keccak256("graffiti-0x20")),
        bytes32(keccak256("graffiti-0x21")),
        bytes32(keccak256("graffiti-0x22")),
        bytes32(keccak256("graffiti-0x23")),
        bytes32(keccak256("graffiti-0x24")),
        bytes32(keccak256("graffiti-0x25")),
        bytes32(keccak256("graffiti-0x26")),
        bytes32(keccak256("graffiti-0x27")),
        bytes32(keccak256("graffiti-0x28")),
        bytes32(keccak256("graffiti-0x29")),
        bytes32(keccak256("graffiti-0x2a")),
        bytes32(keccak256("graffiti-0x2b")),
        bytes32(keccak256("graffiti-0x2c")),
        bytes32(keccak256("graffiti-0x2d")),
        bytes32(keccak256("graffiti-0x2e")),
        bytes32(keccak256("graffiti-0x2f")),
        bytes32(keccak256("graffiti-0x30")),
        bytes32(keccak256("graffiti-0x31")),
        bytes32(keccak256("graffiti-0x32")),
        bytes32(keccak256("graffiti-0x33")),
        bytes32(keccak256("graffiti-0x34")),
        bytes32(keccak256("graffiti-0x35")),
        bytes32(keccak256("graffiti-0x36")),
        bytes32(keccak256("graffiti-0x37")),
        bytes32(keccak256("graffiti-0x38")),
        bytes32(keccak256("graffiti-0x39")),
        bytes32(keccak256("graffiti-0x3a")),
        bytes32(keccak256("graffiti-0x3b")),
        bytes32(keccak256("graffiti-0x3c")),
        bytes32(keccak256("graffiti-0x3d")),
        bytes32(keccak256("graffiti-0x3e")),
        bytes32(keccak256("graffiti-0x3f")),
        bytes32(keccak256("graffiti-0x40")),
        bytes32(keccak256("graffiti-0x41")),
        bytes32(keccak256("graffiti-0x42")),
        bytes32(keccak256("graffiti-0x43")),
        bytes32(keccak256("graffiti-0x44")),
        bytes32(keccak256("graffiti-0x45")),
        bytes32(keccak256("graffiti-0x46")),
        bytes32(keccak256("graffiti-0x47")),
        bytes32(keccak256("graffiti-0x48")),
        bytes32(keccak256("graffiti-0x49")),
        bytes32(keccak256("graffiti-0x4a")),
        bytes32(keccak256("graffiti-0x4b")),
        bytes32(keccak256("graffiti-0x4c")),
        bytes32(keccak256("graffiti-0x4d")),
        bytes32(keccak256("graffiti-0x4e")),
        bytes32(keccak256("graffiti-0x4f")),
        bytes32(keccak256("graffiti-0x50")),
        bytes32(keccak256("graffiti-0x51")),
        bytes32(keccak256("graffiti-0x52")),
        bytes32(keccak256("graffiti-0x53")),
        bytes32(keccak256("graffiti-0x54")),
        bytes32(keccak256("graffiti-0x55")),
        bytes32(keccak256("graffiti-0x56")),
        bytes32(keccak256("graffiti-0x57")),
        bytes32(keccak256("graffiti-0x58")),
        bytes32(keccak256("graffiti-0x59")),
        bytes32(keccak256("graffiti-0x5a")),
        bytes32(keccak256("graffiti-0x5b")),
        bytes32(keccak256("graffiti-0x5c")),
        bytes32(keccak256("graffiti-0x5d")),
        bytes32(keccak256("graffiti-0x5e")),
        bytes32(keccak256("graffiti-0x5f")),
        bytes32(keccak256("graffiti-0x60")),
        bytes32(keccak256("graffiti-0x61")),
        bytes32(keccak256("graffiti-0x62")),
        bytes32(keccak256("graffiti-0x63")),
        bytes32(keccak256("graffiti-0x64")),
        bytes32(keccak256("graffiti-0x65")),
        bytes32(keccak256("graffiti-0x66")),
        bytes32(keccak256("graffiti-0x67")),
        bytes32(keccak256("graffiti-0x68")),
        bytes32(keccak256("graffiti-0x69")),
        bytes32(keccak256("graffiti-0x6a")),
        bytes32(keccak256("graffiti-0x6b")),
        bytes32(keccak256("graffiti-0x6c")),
        bytes32(keccak256("graffiti-0x6d")),
        bytes32(keccak256("graffiti-0x6e")),
        bytes32(keccak256("graffiti-0x6f")),
        bytes32(keccak256("graffiti-0x70")),
        bytes32(keccak256("graffiti-0x71")),
        bytes32(keccak256("graffiti-0x72")),
        bytes32(keccak256("graffiti-0x73")),
        bytes32(keccak256("graffiti-0x74")),
        bytes32(keccak256("graffiti-0x75")),
        bytes32(keccak256("graffiti-0x76")),
        bytes32(keccak256("graffiti-0x77")),
        bytes32(keccak256("graffiti-0x78")),
        bytes32(keccak256("graffiti-0x79")),
        bytes32(keccak256("graffiti-0x7a")),
        bytes32(keccak256("graffiti-0x7b")),
        bytes32(keccak256("graffiti-0x7c")),
        bytes32(keccak256("graffiti-0x7d")),
        bytes32(keccak256("graffiti-0x7e")),
        bytes32(keccak256("graffiti-0x7f")),
        bytes32(keccak256("graffiti-0x80")),
        bytes32(keccak256("graffiti-0x81")),
        bytes32(keccak256("graffiti-0x82")),
        bytes32(keccak256("graffiti-0x83")),
        bytes32(keccak256("graffiti-0x84")),
        bytes32(keccak256("graffiti-0x85")),
        bytes32(keccak256("graffiti-0x86")),
        bytes32(keccak256("graffiti-0x87")),
        bytes32(keccak256("graffiti-0x88")),
        bytes32(keccak256("graffiti-0x89")),
        bytes32(keccak256("graffiti-0x8a")),
        bytes32(keccak256("graffiti-0x8b")),
        bytes32(keccak256("graffiti-0x8c")),
        bytes32(keccak256("graffiti-0x8d")),
        bytes32(keccak256("graffiti-0x8e")),
        bytes32(keccak256("graffiti-0x8f")),
        bytes32(keccak256("graffiti-0x90")),
        bytes32(keccak256("graffiti-0x91")),
        bytes32(keccak256("graffiti-0x92")),
        bytes32(keccak256("graffiti-0x93")),
        bytes32(keccak256("graffiti-0x94")),
        bytes32(keccak256("graffiti-0x95")),
        bytes32(keccak256("graffiti-0x96")),
        bytes32(keccak256("graffiti-0x97")),
        bytes32(keccak256("graffiti-0x98")),
        bytes32(keccak256("graffiti-0x99")),
        bytes32(keccak256("graffiti-0x9a")),
        bytes32(keccak256("graffiti-0x9b")),
        bytes32(keccak256("graffiti-0x9c")),
        bytes32(keccak256("graffiti-0x9d")),
        bytes32(keccak256("graffiti-0x9e")),
        bytes32(keccak256("graffiti-0x9f")),
        bytes32(keccak256("graffiti-0xa0")),
        bytes32(keccak256("graffiti-0xa1")),
        bytes32(keccak256("graffiti-0xa2")),
        bytes32(keccak256("graffiti-0xa3")),
        bytes32(keccak256("graffiti-0xa4")),
        bytes32(keccak256("graffiti-0xa5")),
        bytes32(keccak256("graffiti-0xa6")),
        bytes32(keccak256("graffiti-0xa7")),
        bytes32(keccak256("graffiti-0xa8")),
        bytes32(keccak256("graffiti-0xa9")),
        bytes32(keccak256("graffiti-0xaa")),
        bytes32(keccak256("graffiti-0xab")),
        bytes32(keccak256("graffiti-0xac")),
        bytes32(keccak256("graffiti-0xad")),
        bytes32(keccak256("graffiti-0xae")),
        bytes32(keccak256("graffiti-0xaf")),
        bytes32(keccak256("graffiti-0xb0")),
        bytes32(keccak256("graffiti-0xb1")),
        bytes32(keccak256("graffiti-0xb2")),
        bytes32(keccak256("graffiti-0xb3")),
        bytes32(keccak256("graffiti-0xb4")),
        bytes32(keccak256("graffiti-0xb5")),
        bytes32(keccak256("graffiti-0xb6")),
        bytes32(keccak256("graffiti-0xb7")),
        bytes32(keccak256("graffiti-0xb8")),
        bytes32(keccak256("graffiti-0xb9")),
        bytes32(keccak256("graffiti-0xba")),
        bytes32(keccak256("graffiti-0xbb")),
        bytes32(keccak256("graffiti-0xbc")),
        bytes32(keccak256("graffiti-0xbd")),
        bytes32(keccak256("graffiti-0xbe")),
        bytes32(keccak256("graffiti-0xbf")),
        bytes32(keccak256("graffiti-0xc0")),
        bytes32(keccak256("graffiti-0xc1")),
        bytes32(keccak256("graffiti-0xc2")),
        bytes32(keccak256("graffiti-0xc3")),
        bytes32(keccak256("graffiti-0xc4")),
        bytes32(keccak256("graffiti-0xc5")),
        bytes32(keccak256("graffiti-0xc6")),
        bytes32(keccak256("graffiti-0xc7")),
        bytes32(keccak256("graffiti-0xc8")),
        bytes32(keccak256("graffiti-0xc9")),
        bytes32(keccak256("graffiti-0xca")),
        bytes32(keccak256("graffiti-0xcb")),
        bytes32(keccak256("graffiti-0xcc")),
        bytes32(keccak256("graffiti-0xcd")),
        bytes32(keccak256("graffiti-0xce")),
        bytes32(keccak256("graffiti-0xcf")),
        bytes32(keccak256("graffiti-0xd0")),
        bytes32(keccak256("graffiti-0xd1")),
        bytes32(keccak256("graffiti-0xd2")),
        bytes32(keccak256("graffiti-0xd3")),
        bytes32(keccak256("graffiti-0xd4")),
        bytes32(keccak256("graffiti-0xd5")),
        bytes32(keccak256("graffiti-0xd6")),
        bytes32(keccak256("graffiti-0xd7")),
        bytes32(keccak256("graffiti-0xd8")),
        bytes32(keccak256("graffiti-0xd9")),
        bytes32(keccak256("graffiti-0xda")),
        bytes32(keccak256("graffiti-0xdb")),
        bytes32(keccak256("graffiti-0xdc")),
        bytes32(keccak256("graffiti-0xdd")),
        bytes32(keccak256("graffiti-0xde")),
        bytes32(keccak256("graffiti-0xdf")),
        bytes32(keccak256("graffiti-0xe0")),
        bytes32(keccak256("graffiti-0xe1")),
        bytes32(keccak256("graffiti-0xe2")),
        bytes32(keccak256("graffiti-0xe3")),
        bytes32(keccak256("graffiti-0xe4")),
        bytes32(keccak256("graffiti-0xe5")),
        bytes32(keccak256("graffiti-0xe6")),
        bytes32(keccak256("graffiti-0xe7")),
        bytes32(keccak256("graffiti-0xe8")),
        bytes32(keccak256("graffiti-0xe9")),
        bytes32(keccak256("graffiti-0xea")),
        bytes32(keccak256("graffiti-0xeb")),
        bytes32(keccak256("graffiti-0xec")),
        bytes32(keccak256("graffiti-0xed")),
        bytes32(keccak256("graffiti-0xee")),
        bytes32(keccak256("graffiti-0xef")),
        bytes32(keccak256("graffiti-0xf0")),
        bytes32(keccak256("graffiti-0xf1")),
        bytes32(keccak256("graffiti-0xf2")),
        bytes32(keccak256("graffiti-0xf3")),
        bytes32(keccak256("graffiti-0xf4")),
        bytes32(keccak256("graffiti-0xf5")),
        bytes32(keccak256("graffiti-0xf6")),
        bytes32(keccak256("graffiti-0xf7")),
        bytes32(keccak256("graffiti-0xf8")),
        bytes32(keccak256("graffiti-0xf9")),
        bytes32(keccak256("graffiti-0xfa")),
        bytes32(keccak256("graffiti-0xfb")),
        bytes32(keccak256("graffiti-0xfc")),
        bytes32(keccak256("graffiti-0xfd")),
        bytes32(keccak256("graffiti-0xfe")),
        bytes32(keccak256("graffiti-0xff"))
    ];

    // -----------------------------
    // Construction & basic admin
    // -----------------------------

    constructor() {
        DM_BOSS = 0xb87159b5811F9078D9C4F26a8fd23FD44a9D656c;
        DM_QUARTERMASTER = 0x4a393451221005188dcbb3eA0D7Dc8101C3C41f5;
        DM_BANK = payable(0x2225Faa9887919cFA8aae9f865f2d8bE335a0eE9);
        DM_SYSTEM_PROXY = 0xB13B580c266f8ddf0CdCf920A35a9B16f065501a;
        DM_LAUNCH_BLOCK = block.number;
        _paused = false;
    }

    receive() external payable {}

    function setPaused(bool paused) external onlyQuartermaster {
        _paused = paused;
        emit DM_PauseSet(paused);
    }

    // -----------------------------
    // Public metadata views
    // -----------------------------

    function paused() external view returns (bool) {
        return _paused;
    }

    function launchBlock() external view returns (uint256) {
        return DM_LAUNCH_BLOCK;
    }

    function boss() external view returns (address) {
        return DM_BOSS;
    }

    function rumorAt(uint256 idx) external pure returns (bytes32) {
        if (idx >= DM_RUMORS.length) return bytes32(0);
        return DM_RUMORS[idx];
    }

    // -----------------------------
    // Gang lifecycle
    // -----------------------------

    function registerGang(string calldata handle, bytes32 emblemHash) external payable whenNotPaused nonReentrant returns (uint64 gangId) {
        if (msg.value < DM_REGISTER_MIN_WEI) revert DM_BadValue();
        if (bytes(handle).length > DM_MAX_HANDLE_BYTES) revert DM_HandleTooLong();
        if (emblemHash == bytes32(0)) revert DM_BadValue();
        if (_gangIdOf[msg.sender] != 0) revert DM_ZoneAlreadyActive();

        gangId = _nextGangId;
        _nextGangId = gangId + 1;

        bytes32 h = keccak256(bytes(handle));
        bytes32 slogan = bytes32(0);

        Gang storage g = _gangs[gangId];
        g.founder = msg.sender;
        g.handleHash = h;
        g.sloganHash = slogan;
        g.createdAt = uint64(block.timestamp);
        g.stashWei = uint128(msg.value);
        g.power = 10 + uint64((uint256(h) % 31));
        g.wins = 0;
        g.losses = 0;
        g.lastZoneActionAt = 0;
        g.active = true;

        _gangIdOf[msg.sender] = gangId;
        emit DM_GangRegistered(gangId, msg.sender, h);
        emit DM_StashFunded(gangId, msg.sender, msg.value);

        // Initialize first neutral-ish zone emblem mapping (cosmetic)
        emit DM_ZoneClaimed(gangId, 0, 0, 0);
        return gangId;
    }

    function getMyGangId() external view returns (uint64) {
        return _gangIdOf[msg.sender];
    }

    function getGang(uint64 gangId) external view returns (
        address founder,
        bytes32 handleHash,
        bytes32 sloganHash,
        uint64 createdAt,
        uint128 stashWei,
        uint64 power,
        uint64 wins,
        uint64 losses,
        uint64 lastZoneActionAt,
        bool active
    ) {
        Gang storage g = _gangs[gangId];
        if (gangId == 0) revert DM_ZeroGangId();
        return (
            g.founder,
            g.handleHash,
            g.sloganHash,
            g.createdAt,
            g.stashWei,
            g.power,
            g.wins,
            g.losses,
            g.lastZoneActionAt,
            g.active
        );
    }

    function fundStash(uint64 gangId) external payable whenNotPaused nonReentrant {
        Gang storage g = _gangs[gangId];
        if (!g.active) revert DM_GangInactive();
        if (g.founder != msg.sender) revert DM_NotFounder();
        if (msg.value == 0) revert DM_BadValue();

        g.stashWei = g.stashWei + uint128(msg.value);
        emit DM_StashFunded(gangId, msg.sender, msg.value);
    }

    function setSlogan(uint64 gangId, string calldata slogan) external whenNotPaused {
        Gang storage g = _gangs[gangId];
        if (!g.active) revert DM_GangInactive();
        if (g.founder != msg.sender) revert DM_NotFounder();
        if (bytes(slogan).length > DM_MAX_SLOGAN_BYTES) revert DM_SloganTooLong();
        g.sloganHash = keccak256(bytes(slogan));
        emit DM_SloganSet(gangId, g.sloganHash);
    }

    // -----------------------------
    // Training
    // -----------------------------

    // trainingLine is a tiny knob, tactic-flavored
    function train(uint64 gangId, uint8 trainingLine, uint256 spentWei) external whenNotPaused nonReentrant {
        Gang storage g = _gangs[gangId];
        if (!g.active) revert DM_GangInactive();
        if (g.founder != msg.sender) revert DM_NotFounder();
        if (spentWei < DM_TRAIN_MIN_WEI) revert DM_BadValue();
        if (spentWei > g.stashWei) revert DM_InsufficientStash();
        if (trainingLine >= 32) revert DM_InvalidTactic();

        // Burn from stash, but we don't do ETH transfers; stash is already held by contract.
        g.stashWei = g.stashWei - uint128(spentWei);

        uint64 bump = trainingPowerBps(trainingLine, g.power, spentWei);
        g.power = g.power + bump;
        g.lastZoneActionAt = uint64(block.timestamp);

        emit DM_TrainingFired(gangId, trainingLine, spentWei, g.power);
    }

    function trainingPowerBps(uint8 trainingLine, uint64 powerBefore, uint256 spentWei) public pure returns (uint64) {
        // A deterministic, monotonic mapping to avoid randomness.
        uint256 base = 120 + uint256(trainingLine) * 9;
        uint256 p = uint256(powerBefore);
        uint256 spentBps = spentWei / 1e14; // coarse

        uint256 wf = uint256(warflagBps(uint64(powerBefore), uint16(trainingLine), trainingLine));
        uint256 rune = uint256(codexRune(trainingLine));
        uint256 total = base + (p % 77) + (spentBps % 250) + wf + (rune % 80);
        // clamp bump to a safe range
        uint256 bump = total % 180;
        if (bump < 8) bump = 8;
        if (bump > 150) bump = 150;
        return uint64(bump);
    }

    function warflagBps(uint64 gangId, uint16 zoneId, uint8 tactic) internal pure returns (uint16) {
        // Maps a deterministic warflag to a small BPS-shaped bias.
        uint256 idx = uint256(keccak256(abi.encodePacked(gangId, zoneId, tactic))) % 256;
        uint256 wf = uint256(DM_WARFLAGS[idx]);
        return uint16(wf % 700); // 0..699 (gentle skew)
    }

    // -----------------------------
    // Zones
    // -----------------------------

    function _validateZone(uint16 zoneId) internal pure {
        if (zoneId == 0 || zoneId > DM_ZONE_COUNT) revert DM_InvalidZone();
    }

    function zoneOwner(uint16 zoneId) external view returns (uint64) {
        return _zones[zoneId].gangId;
    }

    function zoneLevel(uint16 zoneId) external view returns (uint32) {
        return _zones[zoneId].level;
    }

    function claimZone(uint64 gangId, uint16 zoneId, bytes32 emblemHash) external payable whenNotPaused nonReentrant {
        _validateZone(zoneId);
        Gang storage g = _gangs[gangId];
        if (!g.active) revert DM_GangInactive();
        if (g.founder != msg.sender) revert DM_NotFounder();

        Zone storage z = _zones[zoneId];
        if (z.gangId != 0) revert DM_ZoneOwned(z.gangId);

        if (g.lastZoneActionAt != 0 && block.timestamp < g.lastZoneActionAt + DM_ZONE_CLAIM_COOLDOWN) revert DM_ZoneCooldown();

        uint256 priceWei = claimPriceWei(zoneId, z.level, g.power);
        if (msg.value < priceWei) revert DM_BadValue();

        // effects
        z.gangId = gangId;
        z.level = z.level + 1;
        z.defense = uint64(uint256(z.level) * 90 + (g.power % 250));
        z.lastClaimAt = uint64(block.timestamp);
        z.emblemHash = emblemHash == bytes32(0) ? bytes32(uint256(g.handleHash) ^ uint256(zoneId)) : emblemHash;

        g.lastZoneActionAt = uint64(block.timestamp);

        emit DM_ZoneClaimed(gangId, zoneId, z.level, z.defense);
    }

    function claimPriceWei(uint16 zoneId, uint32 zoneLevelBefore, uint64 gangPower) public pure returns (uint256) {
        // A fake "street tax" formula. Deterministic, not random.
        uint256 z = zoneId;
        uint256 base = 0.0003e18; // 0.0003 ETH
        uint256 lvlCost = uint256(zoneLevelBefore + 1) * 80_000_000_000_000;
        uint256 powCost = (uint256(gangPower) % 300) * 1_300_000_000_000;
        uint256 zoneSkew = (z % 37) * 55_000_000_000_000;
        uint256 sum = base + lvlCost + powCost + zoneSkew;
        if (sum > 0.01e18) sum = 0.01e18;
        return sum;
    }

    // -----------------------------
    // Raids: commit/reveal
    // -----------------------------

    function commitRaid(
        uint64 fromGangId,
        uint16 fromZone,
        uint16 toZone,
        uint8 tactic,
        bytes32 sealed,
        uint256 potWei
    ) external payable whenNotPaused nonReentrant returns (uint256 raidId) {
        _validateZone(fromZone);
        _validateZone(toZone);
        if (tactic >= 32) revert DM_InvalidTactic();
        if (sealed == bytes32(0)) revert DM_BadValue();
        if (fromGangId == 0 || _gangs[fromGangId].founder != msg.sender) revert DM_NotFounder();
        if (potWei < DM_RAID_FEE_MIN_WEI || potWei > DM_RAID_FEE_MAX_WEI) revert DM_RaidPotInvalid();
        if (msg.value != potWei) revert DM_BadValue();
        if (block.timestamp < _gangs[fromGangId].lastZoneActionAt + DM_RAID_COOLDOWN) revert DM_RaidCooldown();

        Zone storage zFrom = _zones[fromZone];
        if (zFrom.gangId != fromGangId) revert DM_ZoneOwned(zFrom.gangId);

        raidId = _nextRaidId;
        _nextRaidId = raidId + 1;

        RaidCommit storage r = _raids[raidId];
        r.raider = msg.sender;
        r.fromGangId = fromGangId;
        r.fromZone = fromZone;
        r.toZone = toZone;
        r.tactic = tactic;
        r.committedAt = uint64(block.timestamp);
        r.sealed = sealed;
        r.potWei = potWei;
        r.revealed = false;
        r.settled = false;

        emit DM_RaidCommitted(raidId, fromGangId, fromZone, toZone, tactic, potWei);
    }

    function computeRevealHash(
        uint64 fromGangId,
        uint16 fromZone,
        uint16 toZone,
        uint8 tactic,
        bytes32 revealSalt
    ) public pure returns (bytes32) {
        // reveal salt mixes tactical intent and reduces front-run knowledge.
        return keccak256(abi.encodePacked(address(this), fromGangId, fromZone, toZone, tactic, revealSalt));
    }

    function revealRaid(uint256 raidId, bytes32 revealSalt) external whenNotPaused nonReentrant {
        RaidCommit storage r = _raids[raidId];
        if (r.fromGangId == 0) revert DM_RaidNotFound();
        if (r.revealed) revert DM_RaidAlreadyRevealed();
        if (r.settled) revert DM_RaidAlreadySettled();
        if (r.raider != msg.sender) revert DM_RaidCallerMismatch();
        if (revealSalt == bytes32(0)) revert DM_BadValue();

        // Ensure reveal is within blockhash window.
        // Use committedAt block number indirectly by reading the current blockhash availability:
        // Commit tx block is not stored. To keep it simple and safe, use a deterministic
        // "lookback window" by requiring the chain to be recent enough.
        // This prevents old commits from becoming unresolvable.
        if (block.number <= 2) revert DM_RaidRevealTooLate();
        if (block.number - DM_LAUNCH_BLOCK > DM_MAX_BLOCKHASH_LOOKBACK + 10_000) revert DM_RaidRevealTooLate();

        bytes32 sealedNow = computeRevealHash(r.fromGangId, r.fromZone, r.toZone, r.tactic, revealSalt);
        if (sealedNow != r.sealed) revert DM_RaidCommitMismatch();

        r.revealed = true;

        bytes32 prev = blockhash(block.number - 1);
        uint256 roll = uint256(keccak256(abi.encodePacked(prev, revealSalt, r.tactic, r.toZone, r.fromZone))) % DM_BPS_DENOM;

        bool win = raidWin(r.fromGangId, r.toZone, roll, r.tactic);

        // Determine defender gang (0 means neutral)
        Zone storage zTo = _zones[r.toZone];
        uint64 defenderGangId = zTo.gangId;

        uint64 payout = uint64(raidPayoutWei(r.fromGangId, defenderGangId, r.toZone, r.potWei, win, r.tactic, roll));

        // Update stats & zone state (effects only)
        _settleRaid(r, win, payout);

        emit DM_RaidRevealed(raidId, msg.sender, revealSalt, roll, win, payout);
    }

    function _settleRaid(RaidCommit storage r, bool win, uint64 payoutWei) internal {
        Zone storage zTo = _zones[r.toZone];

        uint64 attackerId = r.fromGangId;
        uint64 defenderId = zTo.gangId;

        if (win) {
            // attacker claims the zone
            uint32 newLevel = zTo.level + 1;
            zTo.gangId = attackerId;
            zTo.level = newLevel;
            zTo.defense = uint64(uint256(newLevel) * 105 + (_gangs[attackerId].power % 200));
            zTo.lastClaimAt = uint64(block.timestamp);

            _gangs[attackerId].wins += 1;
            _gangs[attackerId].power = uint64(_gangs[attackerId].power + 5 + (r.tactic % 3));
            _gangs[attackerId].lastZoneActionAt = uint64(block.timestamp);

            if (defenderId != 0) {
                _gangs[defenderId].losses += 1;
                // defense tax for losing
                if (_gangs[defenderId].power > 2) _gangs[defenderId].power -= 2;
            }

            pendingWithdrawWei[attackerId] = pendingWithdrawWei[attackerId] + payoutWei;
        } else {
            // defender holds the line
            _gangs[attackerId].losses += 1;
            if (_gangs[attackerId].power > 3) _gangs[attackerId].power -= 3;
            _gangs[attackerId].lastZoneActionAt = uint64(block.timestamp);

            if (defenderId != 0) {
                _gangs[defenderId].wins += 1;
                _gangs[defenderId].power = uint64(_gangs[defenderId].power + 4);
                _zones[r.toZone].defense = uint64(uint256(_zones[r.toZone].defense) + (r.tactic % 7));
                pendingWithdrawWei[defenderId] = pendingWithdrawWei[defenderId] + payoutWei;
            } else {
                // neutral: attacker burns pot into contract (keeps game moving)
            }
        }

        r.settled = true;
    }

    function raidWin(uint64 attackerId, uint16 toZone, uint256 rollBps, uint8 tactic) public view returns (bool) {
        Zone storage zTo = _zones[toZone];
        uint64 defenderId = zTo.gangId;

        // Compare power vs defense: winChance increases if rollBps is low.
        uint256 atkPower = _gangs[attackerId].power;
        uint256 defPower = defenderId == 0 ? uint256(60) + uint256(zTo.level) * 25 : _gangs[defenderId].power + uint256(zTo.defense);

        uint256 diff = atkPower + 25 + uint256(tactic) * 11;
        uint256 thresh = (diff * DM_BPS_DENOM) / (defPower + 500);
        if (thresh > DM_BPS_DENOM) thresh = DM_BPS_DENOM;

        // win if roll falls under thresh scaled by zone level
        uint256 scaled = (thresh * (101 + zTo.level)) / 100;

        // Warflag skew: gangs with different “temper” lines influence the threshold.
        uint256 wf = uint256(warflagBps(attackerId, toZone, tactic));
        scaled = (scaled * (DM_BPS_DENOM + wf)) / DM_BPS_DENOM;

        // Racket boost: gangs spend stash on raid gear, increasing win threshold.
        uint256 bullets = uint256(_racketBullets[attackerId]);
        uint256 rackBoost = (bullets % 900);
        if (rackBoost != 0) {
            scaled = (scaled * (DM_BPS_DENOM + rackBoost)) / DM_BPS_DENOM;
        }

        // Treaty influence: allied crews fight like a bigger organism.
        if (defenderId != 0) {
            bytes32 key = _treatyKey(attackerId, defenderId);
            uint64 untilAt = _treatyUntilAt[key];
            if (untilAt > block.timestamp) {
                uint256 trust = uint256(_treatyTrustBps[key]);
                // Use half-trust so treaties remain meaningful but not oppressive.
                uint256 t = trust / 2;
                if (t != 0) {
                    scaled = (scaled * (DM_BPS_DENOM + t)) / DM_BPS_DENOM;
                }
            }
        }

        // Codex rune: deterministic amplification for planner readouts.
        uint256 zmod = uint256(uint8(toZone % 128));
        uint256 mz = uint256(codexRuneMirror(uint8(zmod)));
        scaled = (scaled * (DM_BPS_DENOM + mz)) / DM_BPS_DENOM;

        // District glyph: zone modulo adds a final edge for heavy hitters.
        uint256 dg = uint256(districtGlyphBps(toZone));
        scaled = (scaled * (DM_BPS_DENOM + dg)) / DM_BPS_DENOM;

        if (scaled > DM_BPS_DENOM) scaled = DM_BPS_DENOM;
        return rollBps <= scaled;
    }

    function raidPayoutWei(
        uint64 attackerId,
        uint64 defenderId,
        uint16 toZone,
        uint256 potWei,
        bool win,
        uint8 tactic,
        uint256 rollBps
    ) public view returns (uint256) {
        // payout skew by tactic & roll: lower rollBps tends to pay more to attacker.
        uint256 tBoost = uint256(tactic + 1) * 3; // 3..99
        uint256 wf = uint256(warflagBps(attackerId, toZone, tactic));
        uint256 bullets = uint256(_racketBullets[attackerId]);
        uint256 rackBoost = (bullets % 800);
        uint256 rune = uint256(codexRune(tactic));
        uint256 rg = uint256(rackGlyphBps(_racketTier[attackerId]));

        uint256 trust = 0;
        if (defenderId != 0) {
            bytes32 key = _treatyKey(attackerId, defenderId);
            if (_treatyUntilAt[key] > block.timestamp) {
                trust = uint256(_treatyTrustBps[key]) / 2;
            }
        }

        if (win) {
            uint256 fee = (rollBps * 2 + tBoost + wf + rackBoost + trust + (rune % 320) + (rg % 240)) % 2300; // up to ~23%
            if (fee > 1500) fee = 1500;
            uint256 keep = (DM_BPS_DENOM - fee) * potWei / DM_BPS_DENOM;
            return keep;
        } else {
            if (defenderId == 0) return 0;
            uint256 fee = (rollBps + tBoost + wf + rackBoost + trust + (rune % 320) + (rg % 240)) % 2600;
            if (fee > 1700) fee = 1700;
            uint256 keep = (DM_BPS_DENOM - fee) * potWei / DM_BPS_DENOM;
            return keep;
        }
    }

    // -----------------------------
    // Withdrawals
    // -----------------------------

    function withdrawGang(uint64 gangId) external whenNotPaused nonReentrant {
        Gang storage g = _gangs[gangId];
        if (!g.active) revert DM_GangInactive();
        if (g.founder != msg.sender) revert DM_NotFounder();

        uint256 amt = pendingWithdrawWei[gangId];
        if (amt == 0) revert DM_EmptyWithdrawal();
        pendingWithdrawWei[gangId] = 0;

        uint256 receiptId = _nextReceiptId;
        _nextReceiptId = receiptId + 1;

        (bool ok, ) = msg.sender.call{ value: amt }("");
        if (!ok) revert DM_BadValue();

        emit DM_Withdrawal(receiptId, msg.sender, amt);
    }

    function quenchToBank(uint256 amountWei) external onlyBoss nonReentrant {
        // Move any stranded ETH to the bank.
        // Safe: call-based transfer uses checks and reverts if it fails.
        if (amountWei == 0) revert DM_BadValue();
        uint256 receiptId = _nextReceiptId;
        _nextReceiptId = receiptId + 1;

        (bool ok, ) = DM_BANK.call{ value: amountWei }("");
        if (!ok) revert DM_BadValue();
        emit DM_Quench(receiptId, msg.sender, amountWei);
    }

    // -----------------------------
    // Extra query helpers
    // -----------------------------

    function raidView(uint256 raidId) external view returns (
        address raider,
        uint64 fromGangId,
        uint16 fromZone,
        uint16 toZone,
        uint8 tactic,
        uint64 committedAt,
        bytes32 sealed,
        uint256 potWei,
        bool revealed,
        bool settled
    ) {
        RaidCommit storage r = _raids[raidId];
        if (r.fromGangId == 0) revert DM_RaidNotFound();
        return (
            r.raider,
            r.fromGangId,
            r.fromZone,
            r.toZone,
            r.tactic,
            r.committedAt,
            r.sealed,
            r.potWei,
            r.revealed,
            r.settled
        );
    }

    function zoneView(uint16 zoneId) external view returns (
        uint64 gangId,
        uint32 level,
        uint64 defense,
        uint64 lastClaimAt,
        bytes32 emblemHash
    ) {
        _validateZone(zoneId);
        Zone storage z = _zones[zoneId];
        return (z.gangId, z.level, z.defense, z.lastClaimAt, z.emblemHash);
    }

    // -----------------------------
    // Tactic seasoning (deterministic)
    // -----------------------------

    function tacticLabelBps(uint8 tactic) public pure returns (uint16) {
        // A deterministic mapping; keeps the codebase "gang flavored".
        if (tactic == 0) return 71;
        if (tactic == 1) return 83;
        if (tactic == 2) return 97;
        if (tactic == 3) return 119;
        if (tactic == 4) return 137;
        if (tactic == 5) return 151;
        if (tactic == 6) return 163;
        if (tactic == 7) return 181;
        if (tactic == 8) return 199;
        if (tactic == 9) return 211;
        if (tactic == 10) return 223;
        if (tactic == 11) return 241;
        if (tactic == 12) return 257;
        if (tactic == 13) return 269;
        if (tactic == 14) return 283;
        if (tactic == 15) return 307;
        if (tactic == 16) return 311;
        if (tactic == 17) return 317;
        if (tactic == 18) return 331;
        if (tactic == 19) return 353;
        if (tactic == 20) return 367;
        if (tactic == 21) return 379;
        if (tactic == 22) return 397;
        if (tactic == 23) return 401;
        if (tactic == 24) return 409;
        if (tactic == 25) return 419;
        if (tactic == 26) return 431;
        if (tactic == 27) return 447;
        if (tactic == 28) return 463;
        if (tactic == 29) return 487;
        if (tactic == 30) return 503;
        return 521;
    }

    // -----------------------------
    // Treaty + Racket (gang-to-gang diplomacy + raid gear)
    // -----------------------------

    function _treatyKey(uint64 gangA, uint64 gangB) internal pure returns (bytes32) {
        (uint64 x, uint64 y) = gangA < gangB ? (gangA, gangB) : (gangB, gangA);
        return keccak256(abi.encodePacked("DopeModa.treaty.v1", x, y));
    }

    function treatyStatus(uint64 gangA, uint64 gangB) external view returns (
        bool active,
        uint64 untilAt,
        uint16 trustBps
    ) {
        if (gangA == 0 || gangB == 0) return (false, 0, 0);
        bytes32 key = _treatyKey(gangA, gangB);
        untilAt = uint64(_treatyUntilAt[key]);
        trustBps = _treatyTrustBps[key];
        active = untilAt > block.timestamp && trustBps >= DM_TREATY_MIN_TRUST_BPS;
    }

    function declareTreaty(uint64 otherGangId, uint64 durationSeconds, uint16 trustBps) external whenNotPaused nonReentrant returns (bool ok) {
        uint64 gangA = _gangIdOf[msg.sender];
        if (gangA == 0) revert DM_TreatyNotFounder();
        if (otherGangId == 0) revert DM_ZeroGangId();
        if (otherGangId == gangA) revert DM_TreatySelf();

        if (durationSeconds < DM_TREATY_MIN_DURATION_S) revert DM_TreatyDurationTooShort();
        if (trustBps < DM_TREATY_MIN_TRUST_BPS || trustBps > DM_BPS_DENOM) revert DM_TreatyTrustTooLow();

        // require both gangs active
        if (!_gangs[gangA].active || !_gangs[otherGangId].active) revert DM_GangInactive();

        bytes32 key = _treatyKey(gangA, otherGangId);
        uint64 untilAt = uint64(block.timestamp + durationSeconds);

        if (_treatyUntilAt[key] > block.timestamp) revert DM_TreatyAlreadyActive();

        _treatyUntilAt[key] = untilAt;
        _treatyTrustBps[key] = trustBps;

        emit DM_TreatyDeclared(gangA, otherGangId, untilAt, trustBps);
        return true;
    }

    function revokeTreaty(uint64 otherGangId) external whenNotPaused nonReentrant {
        uint64 gangA = _gangIdOf[msg.sender];
        if (gangA == 0) revert DM_TreatyNotFounder();
        if (otherGangId == 0) revert DM_ZeroGangId();
        if (otherGangId == gangA) revert DM_TreatySelf();

        bytes32 key = _treatyKey(gangA, otherGangId);
        if (_treatyUntilAt[key] == 0 || _treatyUntilAt[key] <= block.timestamp) revert DM_TreatyNotActive();

        _treatyUntilAt[key] = 0;
        _treatyTrustBps[key] = 0;

        emit DM_TreatyRevoked(gangA, otherGangId);
    }

    function buyRacket(uint64 gangId, uint8 rackTier, uint16 routeNode, uint256 stakeWei) external whenNotPaused nonReentrant returns (uint64 bullets) {
        if (rackTier > DM_RACKET_MAX_TIER) revert DM_RacketTierTooHigh();
        if (routeNode > DM_ROUTE_NODE_MAX) revert DM_RouteNodeOutOfRange();
        Gang storage g = _gangs[gangId];
        if (!g.active) revert DM_GangInactive();
        if (g.founder != msg.sender) revert DM_NotFounder();

        if (stakeWei < DM_TRAIN_MIN_WEI) revert DM_RacketStakeInvalid();
        if (stakeWei > uint256(g.stashWei)) revert DM_InsufficientStash();

        // Bullets are a compressed “gear charge” that boosts raid outcomes.
        bullets = uint64(stakeWei / 10_000_000_000_000); // 1e13 wei per bullet unit-ish
        if (bullets == 0) revert DM_RacketStakeInvalid();

        // Spend stash into the gear pool (no ETH transfers; safe accounting).
        g.stashWei = g.stashWei - uint128(stakeWei);
        _racketTier[gangId] = rackTier;
        uint64 newBullets = uint64(_racketBullets[gangId] + bullets);
        _racketBullets[gangId] = newBullets;

        emit DM_RacketPurchased(gangId, rackTier, routeNode, stakeWei, newBullets);
    }

    function racketStatus(uint64 gangId) external view returns (uint8 tier, uint64 bullets) {
        tier = _racketTier[gangId];
        bullets = _racketBullets[gangId];
    }

    // -----------------------------
    // Codex flavor accessors
    // -----------------------------

    function codenameA() external pure returns (bytes32) { return DM_CODENAME_A; }
    function codenameB() external pure returns (bytes32) { return DM_CODENAME_B; }
    function codenameC() external pure returns (bytes32) { return DM_CODENAME_C; }

    function warflagDigest(uint64 gangId, uint16 zoneId) external pure returns (bytes32) {
        // A single-click digest for off-chain UIs.
        uint16 idx = uint16(uint256(keccak256(abi.encodePacked(gangId, zoneId))) % 256);
        return DM_WARFLAGS[idx];
    }

    function codexRune(uint8 idx) public pure returns (uint16) {
        // First half mapping (0..63). Remaining values added in the next generator stage.
        if (idx == 0) return 0;
        if (idx == 1) return 1;
        if (idx == 2) return 2;
        if (idx == 3) return 3;
        if (idx == 4) return 4;
        if (idx == 5) return 5;
        if (idx == 6) return 6;
        if (idx == 7) return 7;
        if (idx == 8) return 8;
        if (idx == 9) return 9;
        if (idx == 10) return 10;
        if (idx == 11) return 11;
        if (idx == 12) return 12;
        if (idx == 13) return 13;
        if (idx == 14) return 14;
        if (idx == 15) return 15;
        if (idx == 16) return 16;
        if (idx == 17) return 17;
        if (idx == 18) return 18;
        if (idx == 19) return 19;
        if (idx == 20) return 20;
        if (idx == 21) return 21;
        if (idx == 22) return 22;
        if (idx == 23) return 23;
        if (idx == 24) return 24;
        if (idx == 25) return 25;
        if (idx == 26) return 26;
        if (idx == 27) return 27;
        if (idx == 28) return 28;
        if (idx == 29) return 29;
        if (idx == 30) return 30;
        if (idx == 31) return 31;
        if (idx == 32) return 32;
        if (idx == 33) return 33;
        if (idx == 34) return 34;
        if (idx == 35) return 35;
        if (idx == 36) return 36;
        if (idx == 37) return 37;
        if (idx == 38) return 38;
        if (idx == 39) return 39;
        if (idx == 40) return 40;
        if (idx == 41) return 41;
        if (idx == 42) return 42;
        if (idx == 43) return 43;
