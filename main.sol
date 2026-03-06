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
    // -------------------------------------------------------------------------

    address public owner;
    address public immutable gammaOracle;
    address public immutable smashTreasury;
    address public immutable bannerGuardian;

    uint256 private _feeBps;
    uint256 private _nextSignalIndex;
    uint256 private _locked;
    mapping(bytes32 => bool) private _namespaceFrozen;

    struct SignalRecord {
        address creator;
        uint8 assetClass;
        uint8 convictionTier;
        uint128 sizeWei;
        uint64 createdAt;
        bool smashed;
        bool retired;
    }
    mapping(bytes32 => SignalRecord) private _signals;
    mapping(bytes32 => mapping(address => bool)) private _hasVoted;
    mapping(bytes32 => uint256) private _voteCount;
    mapping(bytes32 => uint256) private _voteSum;
    bytes32[] private _signalIdList;

    // -------------------------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------------------------

    constructor() {
        owner = msg.sender;
        gammaOracle = address(0x7B3E9a2F5c8D1e4A6b0C3f7E9a2D5b8F1c4A7e0);
        smashTreasury = address(0xE2f5A8c1D4e7B0a3F6c9E2d5F8b1A4e7C0d3F6);
        bannerGuardian = address(0x4C0d3F6A9e2B5c8D1f4A7e0C3b6E9a2D5F8c1);
        _feeBps = 50;
        _nextSignalIndex = 0;
    }

    // -------------------------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert HulkAI_NotOwner();
        _;
    }

    modifier onlyGammaOracle() {
        if (msg.sender != gammaOracle) revert HulkAI_NotGammaOracle();
        _;
    }

    modifier onlyBannerGuardian() {
        if (msg.sender != bannerGuardian) revert HulkAI_NotBannerGuardian();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 0) revert HulkAI_Reentrant();
        _locked = 1;
        _;
        _locked = 0;
    }

    modifier whenNamespaceNotFrozen(bytes32 ns) {
        if (_namespaceFrozen[ns]) revert HulkAI_NamespaceFrozen();
        _;
    }

    // -------------------------------------------------------------------------
    // WRITES (OWNER)
    // -------------------------------------------------------------------------

    function setFeeBps(uint256 bps) external onlyOwner {
        if (bps > HULK_MAX_FEE_BPS) revert HulkAI_InvalidFeeBps();
        uint256 prev = _feeBps;
        _feeBps = bps;
        emit FeeBpsUpdated(prev, bps, block.number);
    }

    function setNamespaceFrozen(bytes32 ns, bool frozen) external onlyBannerGuardian {
        _namespaceFrozen[ns] = frozen;
        emit NamespaceFrozen(ns, frozen, block.number);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert HulkAI_ZeroAddress();
        owner = newOwner;
    }

    // -------------------------------------------------------------------------
    // WRITES (REGISTER / SMASH / VOTE)
    // -------------------------------------------------------------------------

    function registerSignal(
        bytes32 signalId,
        uint8 assetClass,
        uint8 convictionTier,
        uint128 sizeWei
    ) external nonReentrant whenNamespaceNotFrozen(HULK_NAMESPACE) {
        if (signalId == bytes32(0)) revert HulkAI_ZeroSignal();
        if (_signals[signalId].createdAt != 0) revert HulkAI_AlreadyExists();
        if (assetClass > HULK_MAX_ASSET_CLASS) revert HulkAI_InvalidAssetClass();
        if (convictionTier > HULK_MAX_CONVICTION) revert HulkAI_InvalidConviction();
        if (_signalIdList.length >= HULK_MAX_SIGNALS) revert HulkAI_TooManySignals();

        uint64 t = uint64(block.timestamp);
        _signals[signalId] = SignalRecord({
            creator: msg.sender,
            assetClass: assetClass,
            convictionTier: convictionTier,
            sizeWei: sizeWei,
            createdAt: t,
            smashed: false,
            retired: false
        });
        _signalIdList.push(signalId);
        _nextSignalIndex += 1;

        emit SignalRegistered(signalId, msg.sender, assetClass, convictionTier, sizeWei, t);
    }

    function smashPick(bytes32 signalId) external onlyGammaOracle {
        SignalRecord storage r = _signals[signalId];
        if (r.createdAt == 0) revert HulkAI_NotFound();
        if (r.retired) revert HulkAI_AlreadyRetired();
        if (r.smashed) return;
        r.smashed = true;
        emit PickSmashed(signalId, msg.sender, uint64(block.timestamp));
    }

    function unsmashPick(bytes32 signalId) external onlyGammaOracle {
        SignalRecord storage r = _signals[signalId];
        if (r.createdAt == 0) revert HulkAI_NotFound();
        if (!r.smashed) revert HulkAI_NotSmashed();
        r.smashed = false;
        emit PickUnsmash(signalId, msg.sender, uint64(block.timestamp));
    }

    function retireSignal(bytes32 signalId) external onlyBannerGuardian {
        SignalRecord storage r = _signals[signalId];
        if (r.createdAt == 0) revert HulkAI_NotFound();
        if (r.retired) revert HulkAI_AlreadyRetired();
        r.retired = true;
        emit SignalRetired(signalId, msg.sender, uint64(block.timestamp));
    }

    function voteConviction(bytes32 signalId, uint8 score) external payable nonReentrant {
        SignalRecord storage r = _signals[signalId];
        if (r.createdAt == 0) revert HulkAI_NotFound();
        if (r.retired) revert HulkAI_AlreadyRetired();
        if (_hasVoted[signalId][msg.sender]) revert HulkAI_AlreadyVoted();
        if (score < HULK_MIN_VOTE_SCORE || score > HULK_MAX_VOTE_SCORE) revert HulkAI_InvalidVoteScore();

        uint256 feeWei = (msg.value * _feeBps) / HULK_FEE_DENOM_BPS;
        if (msg.value < feeWei) revert HulkAI_InsufficientFee();
        uint256 refund = msg.value - feeWei;
        if (feeWei > 0) {
            (bool ok,) = smashTreasury.call{value: feeWei}("");
            require(ok, "HulkAI: treasury send failed");
        }
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "HulkAI: refund failed");
        }

        _hasVoted[signalId][msg.sender] = true;
        _voteCount[signalId] += 1;
