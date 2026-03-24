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
