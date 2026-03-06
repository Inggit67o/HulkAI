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

    function quoteFeeForAmount(uint256 amountWei) external view returns (uint256) {
        return (amountWei * _feeBps) / HULK_FEE_DENOM_BPS;
    }

    function wouldRegisterSucceed(bytes32 signalId) external view returns (bool) {
        if (signalId == bytes32(0)) return false;
        if (_signals[signalId].createdAt != 0) return false;
        if (_signalIdList.length >= HULK_MAX_SIGNALS) return false;
        if (_namespaceFrozen[HULK_NAMESPACE]) return false;
        return true;
    }

    function wouldVoteSucceed(bytes32 signalId, address account) external view returns (bool) {
        if (_signals[signalId].createdAt == 0) return false;
        if (_signals[signalId].retired) return false;
        if (_hasVoted[signalId][account]) return false;
        return true;
    }

    function deriveSignalId(address creator, uint256 nonce, bytes32 salt)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(creator, nonce, salt));
    }

    receive() external payable {}

    // -------------------------------------------------------------------------
    // EXTRA VIEW ALIASES AND HELPERS
    // -------------------------------------------------------------------------

    function getCreator(bytes32 signalId) external view returns (address) {
        return _signals[signalId].creator;
    }

    function getAssetClass(bytes32 signalId) external view returns (uint8) {
        return _signals[signalId].assetClass;
    }

    function getConvictionTier(bytes32 signalId) external view returns (uint8) {
        return _signals[signalId].convictionTier;
    }

    function getSizeWei(bytes32 signalId) external view returns (uint128) {
        return _signals[signalId].sizeWei;
    }

    function getCreatedAt(bytes32 signalId) external view returns (uint64) {
        return _signals[signalId].createdAt;
    }

    function getSmashed(bytes32 signalId) external view returns (bool) {
        return _signals[signalId].smashed;
    }

    function getRetired(bytes32 signalId) external view returns (bool) {
        return _signals[signalId].retired;
    }

    function voteCount(bytes32 signalId) external view returns (uint256) {
        return _voteCount[signalId];
    }

    function voteSum(bytes32 signalId) external view returns (uint256) {
        return _voteSum[signalId];
    }

    function averageScore(bytes32 signalId) external view returns (uint256) {
        uint256 n = _voteCount[signalId];
        if (n == 0) return 0;
        return _voteSum[signalId] / n;
    }

    function totalSignalCount() external view returns (uint256) {
        return _signalIdList.length;
    }

    function listLength() external view returns (uint256) {
        return _signalIdList.length;
    }

    function getOracle() external view returns (address) {
        return gammaOracle;
    }

    function getTreasury() external view returns (address) {
        return smashTreasury;
    }

    function getGuardian() external view returns (address) {
        return bannerGuardian;
    }

    function defaultNamespace() external pure returns (bytes32) {
        return HULK_NAMESPACE;
    }

    function maxAssetClass() external pure returns (uint256) {
        return HULK_MAX_ASSET_CLASS;
    }

    function maxConviction() external pure returns (uint256) {
        return HULK_MAX_CONVICTION;
    }

    function maxSignals() external pure returns (uint256) {
        return HULK_MAX_SIGNALS;
    }

    function maxFeeBps() external pure returns (uint256) {
        return HULK_MAX_FEE_BPS;
    }

    function minVoteScore() external pure returns (uint256) {
        return HULK_MIN_VOTE_SCORE;
    }

    function maxVoteScore() external pure returns (uint256) {
        return HULK_MAX_VOTE_SCORE;
    }

    function feeDenomBps() external pure returns (uint256) {
        return HULK_FEE_DENOM_BPS;
    }

    function getVoteStats(bytes32 signalId) external view returns (uint256 count, uint256 sum) {
        return (_voteCount[signalId], _voteSum[signalId]);
    }

    function getSignalIdsForCreatorPaginated(address creator, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory)
    {
        uint256 total = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            if (_signals[_signalIdList[i]].creator == creator) total++;
        }
        if (offset >= total) {
            return new bytes32[](0);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        bytes32[] memory out = new bytes32[](n);
        uint256 collected = 0;
        uint256 written = 0;
        for (uint256 i = 0; i < _signalIdList.length && written < n; i++) {
            bytes32 id = _signalIdList[i];
            if (_signals[id].creator == creator) {
                if (collected >= offset) {
                    out[written] = id;
                    written++;
                }
                collected++;
            }
        }
        return out;
    }

    function getSignalIdsSmashedPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory)
    {
        uint256 total = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            if (_signals[_signalIdList[i]].smashed) total++;
        }
        if (offset >= total) {
            return new bytes32[](0);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        bytes32[] memory out = new bytes32[](n);
        uint256 collected = 0;
        uint256 written = 0;
        for (uint256 i = 0; i < _signalIdList.length && written < n; i++) {
            bytes32 id = _signalIdList[i];
            if (_signals[id].smashed) {
                if (collected >= offset) {
                    out[written] = id;
                    written++;
                }
                collected++;
            }
        }
        return out;
    }

    function getConvictionSummariesBatch(bytes32[] calldata ids)
        external
        view
        returns (uint256[] memory counts, uint256[] memory sums, uint256[] memory averages)
    {
        uint256 n = ids.length;
        counts = new uint256[](n);
        sums = new uint256[](n);
        averages = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 c = _voteCount[ids[i]];
            uint256 s = _voteSum[ids[i]];
            counts[i] = c;
            sums[i] = s;
            averages[i] = c == 0 ? 0 : s / c;
        }
    }

    function isNamespaceFrozen(bytes32 ns) external view returns (bool) {
        return _namespaceFrozen[ns];
    }

    function getSignalsByCreatorCount(address creator) external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            if (_signals[_signalIdList[i]].creator == creator) c++;
        }
        return c;
    }

    function getSmashedCount() external view returns (uint256) {
        return this.countSmashed();
    }

    function getRetiredCount() external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            if (_signals[_signalIdList[i]].retired) c++;
        }
        return c;
    }

    function getSignalIdsRetired() external view returns (bytes32[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            if (_signals[_signalIdList[i]].retired) count++;
        }
        bytes32[] memory out = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            bytes32 id = _signalIdList[i];
            if (_signals[id].retired) {
                out[j] = id;
                j++;
            }
        }
        return out;
    }

    function getSignalIdsActive() external view returns (bytes32[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            SignalRecord storage r = _signals[_signalIdList[i]];
            if (!r.retired) count++;
        }
        bytes32[] memory out = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            bytes32 id = _signalIdList[i];
            if (!_signals[id].retired) {
                out[j] = id;
                j++;
            }
        }
        return out;
    }

    function getFirstSignalId() external view returns (bytes32) {
        if (_signalIdList.length == 0) return bytes32(0);
        return _signalIdList[0];
    }

    function getLastSignalId() external view returns (bytes32) {
        if (_signalIdList.length == 0) return bytes32(0);
        return _signalIdList[_signalIdList.length - 1];
    }

    function getSignalIdAtIndex(uint256 index) external view returns (bytes32) {
        return this.signalIdAt(index);
    }

    function canVote(bytes32 signalId, address account) external view returns (bool) {
        return this.wouldVoteSucceed(signalId, account);
    }

    function canRegister(bytes32 signalId) external view returns (bool) {
        return this.wouldRegisterSucceed(signalId);
    }

    function feeForValue(uint256 weiAmount) external view returns (uint256) {
        return this.quoteFeeForAmount(weiAmount);
    }

    function computeFee(uint256 valueWei) external view returns (uint256) {
        return (valueWei * _feeBps) / HULK_FEE_DENOM_BPS;
    }

    function getRecord(bytes32 signalId)
        external
        view
        returns (
            address creator_,
            uint8 assetClass_,
            uint8 convictionTier_,
            uint128 sizeWei_,
            uint64 createdAt_,
            bool smashed_,
            bool retired_
        )
    {
        return this.getSignalFull(signalId);
    }

    function signalInfo(bytes32 signalId)
        external
        view
        returns (address c, uint8 ac, uint8 ct, uint128 sw, uint64 ca, bool sm, bool ret)
    {
        SignalRecord storage r = _signals[signalId];
        return (r.creator, r.assetClass, r.convictionTier, r.sizeWei, r.createdAt, r.smashed, r.retired);
    }

    function convictionInfo(bytes32 signalId)
        external
        view
        returns (uint256 count, uint256 sum, uint256 avg)
    {
        count = _voteCount[signalId];
        sum = _voteSum[signalId];
        avg = count == 0 ? 0 : sum / count;
    }

    function allSignalIds() external view returns (bytes32[] memory) {
        return _signalIdList;
    }

    function sliceSignalIds(uint256 start, uint256 length) external view returns (bytes32[] memory) {
        if (start >= _signalIdList.length) return new bytes32[](0);
        uint256 end = start + length;
        if (end > _signalIdList.length) end = _signalIdList.length;
        uint256 n = end - start;
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _signalIdList[start + i];
        }
        return out;
    }

    function getSignalsByAssetClassPaginated(uint8 assetClass, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory)
    {
        uint256 total = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            if (_signals[_signalIdList[i]].assetClass == assetClass) total++;
        }
        if (offset >= total) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        bytes32[] memory out = new bytes32[](n);
        uint256 collected = 0;
        uint256 written = 0;
        for (uint256 i = 0; i < _signalIdList.length && written < n; i++) {
            bytes32 id = _signalIdList[i];
            if (_signals[id].assetClass == assetClass) {
                if (collected >= offset) {
                    out[written] = id;
                    written++;
                }
                collected++;
            }
        }
        return out;
    }

    function getSignalsByConvictionTierPaginated(uint8 tier, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory)
    {
        uint256 total = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            if (_signals[_signalIdList[i]].convictionTier == tier) total++;
        }
        if (offset >= total) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        bytes32[] memory out = new bytes32[](n);
        uint256 collected = 0;
        uint256 written = 0;
        for (uint256 i = 0; i < _signalIdList.length && written < n; i++) {
            bytes32 id = _signalIdList[i];
            if (_signals[id].convictionTier == tier) {
                if (collected >= offset) {
                    out[written] = id;
                    written++;
                }
                collected++;
            }
        }
        return out;
    }

    function hasSignal(bytes32 signalId) external view returns (bool) {
        return _signals[signalId].createdAt != 0;
    }

    function isActive(bytes32 signalId) external view returns (bool) {
        return _signals[signalId].createdAt != 0 && !_signals[signalId].retired;
    }

    function gammaOracleAddress() external view returns (address) {
        return gammaOracle;
    }

    function smashTreasuryAddress() external view returns (address) {
        return smashTreasury;
    }

    function bannerGuardianAddress() external view returns (address) {
        return bannerGuardian;
    }

    function ownerAddress() external view returns (address) {
        return owner;
    }

    function currentFeeBps() external view returns (uint256) {
        return _feeBps;
    }

    function nextIndex() external view returns (uint256) {
        return _nextSignalIndex;
    }

    function totalCount() external view returns (uint256) {
        return _signalIdList.length;
    }

    function getNames() external pure returns (bytes32) {
        return HULK_NAMESPACE;
    }

    function assetClassUpperBound() external pure returns (uint8) {
        return uint8(HULK_MAX_ASSET_CLASS);
    }

    function convictionUpperBound() external pure returns (uint8) {
        return uint8(HULK_MAX_CONVICTION);
    }

    function capSignals() external pure returns (uint256) {
        return HULK_MAX_SIGNALS;
    }

    function capFeeBps() external pure returns (uint256) {
        return HULK_MAX_FEE_BPS;
    }

    function voteScoreMin() external pure returns (uint8) {
        return uint8(HULK_MIN_VOTE_SCORE);
    }

    function voteScoreMax() external pure returns (uint8) {
        return uint8(HULK_MAX_VOTE_SCORE);
    }

    function bpsDenominator() external pure returns (uint256) {
        return HULK_FEE_DENOM_BPS;
    }

    function checkRegister(bytes32 signalId) external view returns (bool ok) {
        return this.wouldRegisterSucceed(signalId);
    }

    function checkVote(bytes32 signalId, address who) external view returns (bool ok) {
        return this.wouldVoteSucceed(signalId, who);
    }

    function estimateVoteFee(uint256 valueWei) external view returns (uint256) {
        return (valueWei * _feeBps) / HULK_FEE_DENOM_BPS;
    }

    function estimateRefund(uint256 valueWei) external view returns (uint256) {
        uint256 fee = (valueWei * _feeBps) / HULK_FEE_DENOM_BPS;
        return valueWei - fee;
    }

    function getBatchCreators(bytes32[] calldata ids) external view returns (address[] memory) {
        uint256 n = ids.length;
        address[] memory out = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _signals[ids[i]].creator;
        }
        return out;
    }

    function getBatchAssetClasses(bytes32[] calldata ids) external view returns (uint8[] memory) {
        uint256 n = ids.length;
        uint8[] memory out = new uint8[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _signals[ids[i]].assetClass;
        }
        return out;
    }

    function getBatchConvictionTiers(bytes32[] calldata ids) external view returns (uint8[] memory) {
        uint256 n = ids.length;
        uint8[] memory out = new uint8[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _signals[ids[i]].convictionTier;
        }
        return out;
    }

    function getBatchSizesWei(bytes32[] calldata ids) external view returns (uint128[] memory) {
        uint256 n = ids.length;
        uint128[] memory out = new uint128[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _signals[ids[i]].sizeWei;
        }
        return out;
    }

    function getBatchCreatedAts(bytes32[] calldata ids) external view returns (uint64[] memory) {
        uint256 n = ids.length;
        uint64[] memory out = new uint64[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _signals[ids[i]].createdAt;
        }
        return out;
    }

    function getBatchSmashed(bytes32[] calldata ids) external view returns (bool[] memory) {
        uint256 n = ids.length;
        bool[] memory out = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _signals[ids[i]].smashed;
        }
        return out;
    }

    function getBatchRetired(bytes32[] calldata ids) external view returns (bool[] memory) {
        uint256 n = ids.length;
        bool[] memory out = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _signals[ids[i]].retired;
        }
        return out;
    }

    function getBatchVoteCounts(bytes32[] calldata ids) external view returns (uint256[] memory) {
        uint256 n = ids.length;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _voteCount[ids[i]];
        }
        return out;
    }

    function getBatchVoteSums(bytes32[] calldata ids) external view returns (uint256[] memory) {
        uint256 n = ids.length;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _voteSum[ids[i]];
        }
        return out;
    }

    function getBatchAverages(bytes32[] calldata ids) external view returns (uint256[] memory) {
        uint256 n = ids.length;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 c = _voteCount[ids[i]];
            uint256 s = _voteSum[ids[i]];
            out[i] = c == 0 ? 0 : s / c;
        }
        return out;
    }

    function countByCreator(address creator) external view returns (uint256) {
        return this.getSignalsByCreatorCount(creator);
    }

    function countByAssetClass(uint8 ac) external view returns (uint256) {
        return this.countSignalsByAssetClass(ac);
    }

    function countByConvictionTier(uint8 ct) external view returns (uint256) {
        return this.countSignalsByConvictionTier(ct);
    }

    function countRetired() external view returns (uint256) {
        return this.getRetiredCount();
    }

    function countActive() external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            if (!_signals[_signalIdList[i]].retired) c++;
        }
        return c;
    }

    function signalAt(uint256 index) external view returns (bytes32) {
        return this.signalIdAt(index);
    }

    function idAt(uint256 index) external view returns (bytes32) {
        if (index >= _signalIdList.length) revert HulkAI_InvalidIndex();
        return _signalIdList[index];
    }

    function recordAt(bytes32 signalId)
        external
        view
        returns (address c, uint8 ac, uint8 ct, uint128 sw, uint64 ca, bool sm, bool ret)
    {
        SignalRecord storage r = _signals[signalId];
        return (r.creator, r.assetClass, r.convictionTier, r.sizeWei, r.createdAt, r.smashed, r.retired);
    }

    function frozen(bytes32 ns) external view returns (bool) {
        return _namespaceFrozen[ns];
    }

    function defaultNsFrozen() external view returns (bool) {
        return _namespaceFrozen[HULK_NAMESPACE];
    }

    function getFeeBps() external view returns (uint256) {
        return _feeBps;
    }

    function getNextSignalIndex() external view returns (uint256) {
        return _nextSignalIndex;
    }

    // -------------------------------------------------------------------------
    // ADDITIONAL VIEW HELPERS (Hulk Smash utilities)
    // -------------------------------------------------------------------------

    function creatorOf(bytes32 signalId) external view returns (address) {
        return _signals[signalId].creator;
    }

    function assetClassOf(bytes32 signalId) external view returns (uint8) {
        return _signals[signalId].assetClass;
    }

    function convictionOf(bytes32 signalId) external view returns (uint8) {
        return _signals[signalId].convictionTier;
    }

    function sizeOf(bytes32 signalId) external view returns (uint128) {
        return _signals[signalId].sizeWei;
    }

    function createdAt(bytes32 signalId) external view returns (uint64) {
        return _signals[signalId].createdAt;
    }

    function smashed(bytes32 signalId) external view returns (bool) {
        return _signals[signalId].smashed;
    }

    function retired(bytes32 signalId) external view returns (bool) {
        return _signals[signalId].retired;
    }

    function votesFor(bytes32 signalId) external view returns (uint256) {
        return _voteCount[signalId];
    }

    function sumFor(bytes32 signalId) external view returns (uint256) {
        return _voteSum[signalId];
    }

    function avgFor(bytes32 signalId) external view returns (uint256) {
        uint256 n = _voteCount[signalId];
        return n == 0 ? 0 : _voteSum[signalId] / n;
    }

    function gammaOracleAddr() external view returns (address) {
        return gammaOracle;
    }

    function smashTreasuryAddr() external view returns (address) {
        return smashTreasury;
    }

    function bannerGuardianAddr() external view returns (address) {
        return bannerGuardian;
    }

    function ownerAddr() external view returns (address) {
        return owner;
    }

    function feeBpsValue() external view returns (uint256) {
        return _feeBps;
    }

    function nextIdx() external view returns (uint256) {
        return _nextSignalIndex;
    }

    function signalListLength() external view returns (uint256) {
        return _signalIdList.length;
    }

    function constantMaxAssetClass() external pure returns (uint8) {
        return uint8(HULK_MAX_ASSET_CLASS);
    }

    function constantMaxConviction() external pure returns (uint8) {
        return uint8(HULK_MAX_CONVICTION);
    }

    function constantMaxSignals() external pure returns (uint256) {
        return HULK_MAX_SIGNALS;
    }

    function constantMaxFeeBps() external pure returns (uint256) {
        return HULK_MAX_FEE_BPS;
    }

    function constantMinVoteScore() external pure returns (uint8) {
        return uint8(HULK_MIN_VOTE_SCORE);
    }

    function constantMaxVoteScore() external pure returns (uint8) {
        return uint8(HULK_MAX_VOTE_SCORE);
    }

    function constantFeeDenomBps() external pure returns (uint256) {
        return HULK_FEE_DENOM_BPS;
    }

    function namespaceDefault() external pure returns (bytes32) {
        return HULK_NAMESPACE;
    }

    function exists(bytes32 signalId) external view returns (bool) {
        return _signals[signalId].createdAt != 0;
    }

    function isRetired(bytes32 signalId) external view returns (bool) {
        return _signals[signalId].retired;
    }

    function isSmashed(bytes32 signalId) external view returns (bool) {
        return _signals[signalId].smashed;
    }

    function voted(bytes32 signalId, address account) external view returns (bool) {
        return _hasVoted[signalId][account];
    }

    function registerAllowed(bytes32 signalId) external view returns (bool) {
        return this.wouldRegisterSucceed(signalId);
    }

    function voteAllowed(bytes32 signalId, address account) external view returns (bool) {
        return this.wouldVoteSucceed(signalId, account);
    }

    function feeFromValue(uint256 valueWei) external view returns (uint256) {
        return (valueWei * _feeBps) / HULK_FEE_DENOM_BPS;
    }

    function refundFromValue(uint256 valueWei) external view returns (uint256) {
        uint256 fee = (valueWei * _feeBps) / HULK_FEE_DENOM_BPS;
        return valueWei - fee;
    }

    function getFullRecord(bytes32 signalId)
        external
        view
        returns (
            address c,
            uint8 ac,
            uint8 ct,
            uint128 sw,
            uint64 ca,
            bool sm,
            bool ret
        )
    {
        SignalRecord storage r = _signals[signalId];
        return (r.creator, r.assetClass, r.convictionTier, r.sizeWei, r.createdAt, r.smashed, r.retired);
    }

    function getVoteSummary(bytes32 signalId)
        external
        view
        returns (uint256 numVotes, uint256 totalScore, uint256 averageScore)
    {
        numVotes = _voteCount[signalId];
        totalScore = _voteSum[signalId];
        averageScore = numVotes == 0 ? 0 : totalScore / numVotes;
    }

    function allIds() external view returns (bytes32[] memory) {
        return _signalIdList;
    }

    function idsInRange(uint256 from_, uint256 to_) external view returns (bytes32[] memory) {
        return this.getSignalIdsInRange(from_, to_);
    }

    function idsForCreator(address creator) external view returns (bytes32[] memory) {
        return this.getSignalIdsForCreator(creator);
    }

    function idsSmashed() external view returns (bytes32[] memory) {
        return this.getSignalIdsSmashed();
    }

    function idsByAsset(uint8 ac) external view returns (bytes32[] memory) {
        return this.getSignalIdsByAssetClass(ac);
    }

    function idsByConviction(uint8 ct) external view returns (bytes32[] memory) {
        return this.getSignalIdsByConvictionTier(ct);
    }

    function idsRetired() external view returns (bytes32[] memory) {
        return this.getSignalIdsRetired();
    }

    function idsActive() external view returns (bytes32[] memory) {
        return this.getSignalIdsActive();
    }

    function numSignals() external view returns (uint256) {
        return _signalIdList.length;
    }

    function numSmashed() external view returns (uint256) {
        return this.countSmashed();
    }

    function numRetired() external view returns (uint256) {
        return this.getRetiredCount();
    }

    function numActive() external view returns (uint256) {
        return this.countActive();
    }

    function deriveId(address creator_, uint256 nonce, bytes32 salt) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(creator_, nonce, salt));
    }

    function computeSignalId(address creator_, uint256 nonce, bytes32 salt) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(creator_, nonce, salt));
    }

    function requiredFee(uint256 valueWei) external view returns (uint256) {
        return (valueWei * _feeBps) / HULK_FEE_DENOM_BPS;
    }

    function treasuryShare(uint256 valueWei) external view returns (uint256) {
        return (valueWei * _feeBps) / HULK_FEE_DENOM_BPS;
    }

    function userRefund(uint256 valueWei) external view returns (uint256) {
        return valueWei - (valueWei * _feeBps) / HULK_FEE_DENOM_BPS;
    }

    function getBatchExists(bytes32[] calldata ids) external view returns (bool[] memory) {
        uint256 n = ids.length;
        bool[] memory out = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _signals[ids[i]].createdAt != 0;
        }
        return out;
    }

    function getBatchSmashedFlags(bytes32[] calldata ids) external view returns (bool[] memory) {
        uint256 n = ids.length;
        bool[] memory out = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _signals[ids[i]].smashed;
        }
        return out;
    }

    function getBatchRetiredFlags(bytes32[] calldata ids) external view returns (bool[] memory) {
        uint256 n = ids.length;
        bool[] memory out = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _signals[ids[i]].retired;
        }
        return out;
    }

    function getBatchHasVoted(bytes32[] calldata ids, address account)
        external
        view
        returns (bool[] memory)
    {
        uint256 n = ids.length;
        bool[] memory out = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _hasVoted[ids[i]][account];
        }
        return out;
    }

    function getBatchAverageScores(bytes32[] calldata ids) external view returns (uint256[] memory) {
        uint256 n = ids.length;
        uint256[] memory out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 c = _voteCount[ids[i]];
            out[i] = c == 0 ? 0 : _voteSum[ids[i]] / c;
        }
        return out;
    }

    function countNonRetired() external view returns (uint256) {
        return this.countActive();
    }

    function countNonSmashed() external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            if (!_signals[_signalIdList[i]].smashed) c++;
        }
        return c;
    }

    function getSignalIdsNotSmashed() external view returns (bytes32[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            if (!_signals[_signalIdList[i]].smashed) count++;
        }
        bytes32[] memory out = new bytes32[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < _signalIdList.length; i++) {
            bytes32 id = _signalIdList[i];
            if (!_signals[id].smashed) {
                out[j] = id;
                j++;
            }
        }
        return out;
    }

    function getSignalIdsNotRetired() external view returns (bytes32[] memory) {
        return this.getSignalIdsActive();
    }

    function firstId() external view returns (bytes32) {
        return this.getFirstSignalId();
    }

    function lastId() external view returns (bytes32) {
        return this.getLastSignalId();
    }

    function at(uint256 index) external view returns (bytes32) {
        return this.signalIdAt(index);
    }

    function oracleAddr() external view returns (address) {
        return gammaOracle;
    }

    function treasuryAddr() external view returns (address) {
        return smashTreasury;
    }

    function guardianAddr() external view returns (address) {
        return bannerGuardian;
    }

    function getOwner() external view returns (address) {
        return owner;
    }

    function getFeeBpsValue() external view returns (uint256) {
        return _feeBps;
    }

    function getNextIndex() external view returns (uint256) {
        return _nextSignalIndex;
    }

    function getTotalSignals() external view returns (uint256) {
        return _signalIdList.length;
    }

    function isFrozen(bytes32 ns) external view returns (bool) {
        return _namespaceFrozen[ns];
    }

    function defaultFrozen() external view returns (bool) {
        return _namespaceFrozen[HULK_NAMESPACE];
    }

    function HULK_maxAssetClass() external pure returns (uint256) {
        return HULK_MAX_ASSET_CLASS;
    }

    function HULK_maxConviction() external pure returns (uint256) {
        return HULK_MAX_CONVICTION;
    }

    function HULK_maxSignalsCap() external pure returns (uint256) {
        return HULK_MAX_SIGNALS;
    }

    function HULK_maxFeeBpsCap() external pure returns (uint256) {
        return HULK_MAX_FEE_BPS;
    }

    function HULK_minVote() external pure returns (uint256) {
        return HULK_MIN_VOTE_SCORE;
    }

    function HULK_maxVote() external pure returns (uint256) {
        return HULK_MAX_VOTE_SCORE;
    }

    function HULK_feeDenom() external pure returns (uint256) {
        return HULK_FEE_DENOM_BPS;
    }

    function HULK_namespace() external pure returns (bytes32) {
        return HULK_NAMESPACE;
    }

    function checkExists(bytes32 signalId) external view returns (bool) {
        return _signals[signalId].createdAt != 0;
    }

    function checkSmashed(bytes32 signalId) external view returns (bool) {
        return _signals[signalId].smashed;
    }

    function checkRetired(bytes32 signalId) external view returns (bool) {
        return _signals[signalId].retired;
    }

    function checkVoted(bytes32 signalId, address account) external view returns (bool) {
        return _hasVoted[signalId][account];
    }

    function estimateFee(uint256 valueWei) external view returns (uint256) {
        return (valueWei * _feeBps) / HULK_FEE_DENOM_BPS;
    }

    function estimateTreasuryShare(uint256 valueWei) external view returns (uint256) {
        return (valueWei * _feeBps) / HULK_FEE_DENOM_BPS;
    }

    function estimateUserRefund(uint256 valueWei) external view returns (uint256) {
        uint256 fee = (valueWei * _feeBps) / HULK_FEE_DENOM_BPS;
        return valueWei - fee;
    }

    function listAllIds() external view returns (bytes32[] memory) {
        return _signalIdList;
    }

    function rangeIds(uint256 fromIdx, uint256 toIdx) external view returns (bytes32[] memory) {
        return this.getSignalIdsInRange(fromIdx, toIdx);
    }

    function creatorIds(address creator) external view returns (bytes32[] memory) {
        return this.getSignalIdsForCreator(creator);
    }

    function smashedIds() external view returns (bytes32[] memory) {
        return this.getSignalIdsSmashed();
    }

    function assetClassIds(uint8 ac) external view returns (bytes32[] memory) {
        return this.getSignalIdsByAssetClass(ac);
    }

    function convictionTierIds(uint8 ct) external view returns (bytes32[] memory) {
        return this.getSignalIdsByConvictionTier(ct);
    }

    function retiredIds() external view returns (bytes32[] memory) {
        return this.getSignalIdsRetired();
    }

    function activeIds() external view returns (bytes32[] memory) {
        return this.getSignalIdsActive();
    }

    function notSmashedIds() external view returns (bytes32[] memory) {
        return this.getSignalIdsNotSmashed();
    }

