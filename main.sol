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
        _voteSum[signalId] += score;
        emit ConvictionVote(signalId, msg.sender, score, uint64(block.timestamp));
    }

    // -------------------------------------------------------------------------
    // VIEWS (SIGNAL)
    // -------------------------------------------------------------------------

    function getSignalCreator(bytes32 signalId) external view returns (address) {
        return _signals[signalId].creator;
    }

    function getSignalAssetClass(bytes32 signalId) external view returns (uint8) {
        return _signals[signalId].assetClass;
    }

    function getSignalConvictionTier(bytes32 signalId) external view returns (uint8) {
        return _signals[signalId].convictionTier;
    }

    function getSignalSizeWei(bytes32 signalId) external view returns (uint128) {
        return _signals[signalId].sizeWei;
    }

    function getSignalCreatedAt(bytes32 signalId) external view returns (uint64) {
        return _signals[signalId].createdAt;
    }

    function isSignalSmashed(bytes32 signalId) external view returns (bool) {
        return _signals[signalId].smashed;
    }

    function isSignalRetired(bytes32 signalId) external view returns (bool) {
        return _signals[signalId].retired;
    }

    function getSignalFull(bytes32 signalId)
        external
        view
        returns (
            address creator,
            uint8 assetClass,
            uint8 convictionTier,
            uint128 sizeWei,
            uint64 createdAt,
            bool smashed,
            bool retired
        )
    {
        SignalRecord storage r = _signals[signalId];
        return (
            r.creator,
            r.assetClass,
            r.convictionTier,
            r.sizeWei,
            r.createdAt,
            r.smashed,
            r.retired
        );
    }

    function signalExists(bytes32 signalId) external view returns (bool) {
        return _signals[signalId].createdAt != 0;
    }

    function hasVoted(bytes32 signalId, address account) external view returns (bool) {
        return _hasVoted[signalId][account];
    }

    function getVoteCount(bytes32 signalId) external view returns (uint256) {
        return _voteCount[signalId];
    }

    function getVoteSum(bytes32 signalId) external view returns (uint256) {
        return _voteSum[signalId];
    }

    function getAverageConvictionScore(bytes32 signalId) external view returns (uint256) {
        uint256 n = _voteCount[signalId];
        if (n == 0) return 0;
        return _voteSum[signalId] / n;
    }

    function feeBps() external view returns (uint256) {
        return _feeBps;
    }

    function nextSignalIndex() external view returns (uint256) {
        return _nextSignalIndex;
    }

    function namespaceFrozen(bytes32 ns) external view returns (bool) {
        return _namespaceFrozen[ns];
    }

    function totalSignals() external view returns (uint256) {
        return _signalIdList.length;
    }

    function signalIdAt(uint256 index) external view returns (bytes32) {
        if (index >= _signalIdList.length) revert HulkAI_InvalidIndex();
        return _signalIdList[index];
    }

    // -------------------------------------------------------------------------
    // BATCH VIEWS
    // -------------------------------------------------------------------------

    function getSignalsBatch(bytes32[] calldata ids)
        external
        view
        returns (
            address[] memory creators,
            uint8[] memory assetClasses,
            uint8[] memory convictionTiers,
            uint128[] memory sizesWei,
            uint64[] memory createdAts,
            bool[] memory smasheds,
            bool[] memory retireds
        )
    {
        uint256 n = ids.length;
        creators = new address[](n);
        assetClasses = new uint8[](n);
        convictionTiers = new uint8[](n);
        sizesWei = new uint128[](n);
        createdAts = new uint64[](n);
        smasheds = new bool[](n);
        retireds = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            SignalRecord storage r = _signals[ids[i]];
            creators[i] = r.creator;
            assetClasses[i] = r.assetClass;
            convictionTiers[i] = r.convictionTier;
            sizesWei[i] = r.sizeWei;
            createdAts[i] = r.createdAt;
            smasheds[i] = r.smashed;
            retireds[i] = r.retired;
        }
    }

    function getSignalIdsInRange(uint256 fromIndex, uint256 toIndex)
        external
        view
        returns (bytes32[] memory)
    {
        if (fromIndex > toIndex || toIndex > _signalIdList.length) revert HulkAI_InvalidIndex();
        uint256 n = toIndex - fromIndex;
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _signalIdList[fromIndex + i];
        }
        return out;
    }

    function getSignalIdsForCreator(address creator) external view returns (bytes32[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            if (_signals[_signalIdList[i]].creator == creator) count++;
        }
        bytes32[] memory out = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            bytes32 id = _signalIdList[i];
            if (_signals[id].creator == creator) {
                out[j] = id;
                j++;
            }
        }
        return out;
    }

    function getSignalIdsSmashed() external view returns (bytes32[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            if (_signals[_signalIdList[i]].smashed) count++;
        }
        bytes32[] memory out = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            bytes32 id = _signalIdList[i];
            if (_signals[id].smashed) {
                out[j] = id;
                j++;
            }
        }
        return out;
    }

    function getSignalIdsByAssetClass(uint8 assetClass) external view returns (bytes32[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            if (_signals[_signalIdList[i]].assetClass == assetClass) count++;
        }
        bytes32[] memory out = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            bytes32 id = _signalIdList[i];
            if (_signals[id].assetClass == assetClass) {
                out[j] = id;
                j++;
            }
        }
        return out;
    }

    function getSignalIdsByConvictionTier(uint8 tier) external view returns (bytes32[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            if (_signals[_signalIdList[i]].convictionTier == tier) count++;
        }
        bytes32[] memory out = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            bytes32 id = _signalIdList[i];
            if (_signals[id].convictionTier == tier) {
                out[j] = id;
                j++;
            }
        }
        return out;
    }

    function countSignalsByAssetClass(uint8 assetClass) external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            if (_signals[_signalIdList[i]].assetClass == assetClass) c++;
        }
        return c;
    }

    function countSignalsByConvictionTier(uint8 tier) external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            if (_signals[_signalIdList[i]].convictionTier == tier) c++;
        }
        return c;
    }

    function countSmashed() external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            if (_signals[_signalIdList[i]].smashed) c++;
        }
        return c;
    }

    // -------------------------------------------------------------------------
    // HELPERS
    // -------------------------------------------------------------------------

    function requiredVoteFeeWei(uint256 valueSent) external view returns (uint256) {
        return (valueSent * _feeBps) / HULK_FEE_DENOM_BPS;
    }

