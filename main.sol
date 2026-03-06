// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title HulkAI
/// @notice Gamma-powered signal registry for on-chain crypto picks. Strategies are registered with
/// asset class, conviction tier, and size; the oracle can "Hulk Smash" approve a pick; fees flow
/// to treasury. Banner guardian can pause namespaces. Safe for mainnet when deployed with
/// intended roles and fee caps.

contract HulkAI {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event SignalRegistered(
        bytes32 indexed signalId,
        address indexed creator,
        uint8 assetClass,
        uint8 convictionTier,
        uint128 sizeWei,
        uint64 createdAt
    );

    event PickSmashed(
        bytes32 indexed signalId,
        address indexed by,
        uint64 smashedAt
    );

    event PickUnsmash(bytes32 indexed signalId, address indexed by, uint64 at);
    event SignalRetired(bytes32 indexed signalId, address indexed by, uint64 retiredAt);

    event ConvictionVote(
        bytes32 indexed signalId,
        address indexed voter,
        uint8 score,
        uint64 votedAt
    );

    event GammaOracleUpdated(address indexed previous, address indexed current, uint256 atBlock);
    event SmashTreasuryUpdated(address indexed previous, address indexed current, uint256 atBlock);
    event BannerGuardianUpdated(address indexed previous, address indexed current, uint256 atBlock);
    event FeeBpsUpdated(uint256 previous, uint256 current, uint256 atBlock);
    event NamespaceFrozen(bytes32 indexed ns, bool frozen, uint256 atBlock);

    // -------------------------------------------------------------------------
    // ERRORS
    // -------------------------------------------------------------------------

    error HulkAI_NotOwner();
    error HulkAI_NotGammaOracle();
    error HulkAI_NotBannerGuardian();
    error HulkAI_ZeroAddress();
    error HulkAI_ZeroSignal();
    error HulkAI_AlreadyExists();
    error HulkAI_NotFound();
    error HulkAI_AlreadyRetired();
    error HulkAI_InvalidAssetClass();
    error HulkAI_InvalidConviction();
    error HulkAI_InvalidVoteScore();
    error HulkAI_Reentrant();
    error HulkAI_TooManySignals();
    error HulkAI_AlreadyVoted();
    error HulkAI_InvalidFeeBps();
    error HulkAI_NamespaceFrozen();
    error HulkAI_InsufficientFee();
    error HulkAI_InvalidIndex();
    error HulkAI_NotSmashed();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant HULK_FEE_DENOM_BPS = 10_000;
    uint256 public constant HULK_MAX_ASSET_CLASS = 12;
    uint256 public constant HULK_MAX_CONVICTION = 7;
    uint256 public constant HULK_MAX_SIGNALS = 300_000;
    uint256 public constant HULK_MAX_VOTE_SCORE = 10;
    uint256 public constant HULK_MIN_VOTE_SCORE = 1;
    uint256 public constant HULK_MAX_FEE_BPS = 500;
    bytes32 public constant HULK_NAMESPACE = 0x48756c6b414947616d6d615369676e616c733230323530333032653136343938;

    // -------------------------------------------------------------------------
    // STORAGE
