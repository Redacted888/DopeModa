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
