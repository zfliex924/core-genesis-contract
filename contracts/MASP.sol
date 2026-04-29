// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.24;

import "./System.sol";
import "./interface/IParamSubscriber.sol";
import "./lib/Memory.sol";
import "./lib/BytesToTypes.sol";
import "./lib/RLPDecode.sol";

/// @notice Minimal Association Set Provider interface (compliance screening).
interface IASP {
    function isApproved(address wallet) external view returns (bool approved, uint256 lastUpdated);
    function getAssociationSetRoot() external view returns (uint256 root);
    function providerInfo() external view returns (string memory name, string memory version);
}

/// @title MASP
/// @notice Z Protocol Multi-Asset Shielded Pool — single-file system contract at MASP_ADDR (0x1020).
/// @dev    Inlines MASPPool + CommitmentTree + ASPManager + NoteLib helpers from
///         /Users/gokberkgulgun/Documents/GitHub/masp/src/. All Poseidon and Groth16
///         operations dispatch directly to chain precompiles (0x6a/0x6b/0x6c) — no
///         intermediate Solidity Poseidon contracts, no separate verifier wrappers.
///         Governance via GovHub (0x1006) using the IParamSubscriber.updateParam pattern.
contract MASP is System, IParamSubscriber {
    using RLPDecode for bytes;
    using RLPDecode for RLPDecode.RLPItem;

    // ═══════════════════════════════════════════════════════════════════
    //                          STRUCTS (from IMASP)
    // ═══════════════════════════════════════════════════════════════════

    struct Proof {
        uint256[2]    a;
        uint256[2][2] b;
        uint256[2]    c;
    }

    struct ShieldParams {
        Proof   proof;
        uint256 commitment;
        uint8   tokenType;
        address tokenAddress;
        uint256 tokenSubID;
        uint128 value;
        bytes   encryptedNote;
    }

    struct TransactParams {
        Proof     proof;
        uint256   treeNumber;
        uint256   merkleRoot;
        uint256   boundParamsHash;
        uint256   tokenHash;
        uint256   actionHash;
        uint256[] nullifiers;
        uint256[] commitments;
        bytes[]   encryptedNotes;
    }

    struct UnshieldParams {
        Proof     proof;
        uint256   treeNumber;
        uint256   merkleRoot;
        uint256   boundParamsHash;
        uint256   actionHash;
        uint256[] nullifiers;
        uint256[] commitments;
        bytes[]   encryptedNotes;
        address   recipient;
        address   token;
        uint256   amount;
        uint256   fee;
        address   broadcaster;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════════

    event Shield(uint256 indexed treeNumber, uint256 startPosition, uint256[] commitments, bytes[] encryptedNotes);
    event Transact(uint256 indexed treeNumber, uint256[] nullifiers, uint256[] commitments, bytes[] encryptedNotes);
    event Unshield(address indexed recipient, address indexed token, uint256 amount, uint256 fee, uint256 protocolFee, address indexed broadcaster);
    event AssetWhitelisted(uint256 indexed tokenHash, address token);
    event AssetRemovedFromWhitelist(uint256 indexed tokenHash, address token);
    event PauseStatusChanged(bool paused);
    event ProtocolFeeUpdated(uint256 feeBps);
    event TreasuryUpdated(address indexed treasury);
    event UnshieldDelayUpdated(uint256 newDelay);
    event TreeCreated(uint256 indexed treeNumber);
    event ASPAdded(address indexed asp, string name);
    event ASPRemoved(address indexed asp);
    event ASPStalenessThresholdUpdated(uint256 newThreshold);
    event AssociationSetRootUpdated(address indexed asp, uint256 root);
    event VerifierVKUpdated(uint256 indexed configHash, uint256 vkLength);

    // ═══════════════════════════════════════════════════════════════════
    //                          ERRORS
    // ═══════════════════════════════════════════════════════════════════

    error InvalidProof();
    error VKNotSet(uint256 configHash);
    error VKLengthMismatch(uint256 got, uint256 expected);
    error NullifierAlreadySpent(uint256 nullifier);
    error UnknownMerkleRoot(uint256 root);
    error AssetNotWhitelisted(uint256 tokenHash);
    error InputOutOfField(uint256 value);
    error InvalidRecipient();
    error InsufficientDeposit();
    error TransferFailed();
    error ETHTransferFailed();
    error PausedError();
    error InvalidBroadcasterFee();
    error TreeFull();
    error FeeTooHigh();
    error TreasuryNotSet();
    error InvalidEncryptedNotesLength();
    error InvalidTreeNumber();
    error InvalidCircuitConfig();
    error UnshieldDelayNotMet(uint256 rootTimestamp, uint256 requiredDelay);
    error UnshieldDelayTooLong();
    error InvalidMsgValue();
    error InvalidTokenType();
    error FeeOnTransferNotSupported();
    error ZeroAddressErr();
    error ReentrancyErr();
    error LeafOutOfField();
    error ZeroLeaf();
    error WalletNotApproved(address wallet);
    error ASPDataStale(address asp, uint256 lastUpdated, uint256 threshold);
    error ASPAlreadyRegistered(address asp);
    error ASPNotRegisteredErr(address asp);
    error TooManyASPs();
    error DuplicateNullifierInBatch();
    // Note: MismatchParamLength, OutOfBounds, UnsupportedGovParam are inherited from System.sol.

    // ═══════════════════════════════════════════════════════════════════
    //                       CONSTANTS — fixed at deploy
    // ═══════════════════════════════════════════════════════════════════

    uint256 internal constant SNARK_SCALAR_FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    uint8   internal constant TOKEN_TYPE_ERC20  = 0;
    uint8   internal constant TOKEN_TYPE_NATIVE = 0xFF;
    address internal constant NATIVE_TOKEN      = address(0);

    uint256 internal constant MAX_PROTOCOL_FEE_BPS = 500;
    uint256 internal constant MAX_UNSHIELD_DELAY   = 7 days;

    uint256 internal constant TREE_DEPTH        = 20;
    uint256 internal constant MAX_LEAVES        = 2 ** 20;   // 1,048,576
    uint256 internal constant MAX_ASP_PROVIDERS = 10;

    address internal constant POSEIDON_T3_PRECOMPILE = address(0x6b);
    address internal constant POSEIDON_T4_PRECOMPILE = address(0x6c);
    address internal constant GROTH16_PRECOMPILE     = address(0x6a);

    // ─── Auto-generated by scripts/build-masp-consts.js ───
    // Depth-20 Poseidon T3 zero-hash chain.
    uint256 internal constant ZERO_00 = 0x2098f5fb9e239eab3ceac3f27b81e481dc3124d55ffed523a839ee8446b64864;
    uint256 internal constant ZERO_01 = 0x1069673dcdb12263df301a6ff584a7ec261a44cb9dc68df067a4774460b1f1e1;
    uint256 internal constant ZERO_02 = 0x18f43331537ee2af2e3d758d50f72106467c6eea50371dd528d57eb2b856d238;
    uint256 internal constant ZERO_03 = 0x07f9d837cb17b0d36320ffe93ba52345f1b728571a568265caac97559dbc952a;
    uint256 internal constant ZERO_04 = 0x2b94cf5e8746b3f5c9631f4c5df32907a699c58c94b2ad4d7b5cec1639183f55;
    uint256 internal constant ZERO_05 = 0x2dee93c5a666459646ea7d22cca9e1bcfed71e6951b953611d11dda32ea09d78;
    uint256 internal constant ZERO_06 = 0x078295e5a22b84e982cf601eb639597b8b0515a88cb5ac7fa8a4aabe3c87349d;
    uint256 internal constant ZERO_07 = 0x2fa5e5f18f6027a6501bec864564472a616b2e274a41211a444cbe3a99f3cc61;
    uint256 internal constant ZERO_08 = 0x0e884376d0d8fd21ecb780389e941f66e45e7acce3e228ab3e2156a614fcd747;
    uint256 internal constant ZERO_09 = 0x1b7201da72494f1e28717ad1a52eb469f95892f957713533de6175e5da190af2;
    uint256 internal constant ZERO_10 = 0x1f8d8822725e36385200c0b201249819a6e6e1e4650808b5bebc6bface7d7636;
    uint256 internal constant ZERO_11 = 0x2c5d82f66c914bafb9701589ba8cfcfb6162b0a12acf88a8d0879a0471b5f85a;
    uint256 internal constant ZERO_12 = 0x14c54148a0940bb820957f5adf3fa1134ef5c4aaa113f4646458f270e0bfbfd0;
    uint256 internal constant ZERO_13 = 0x190d33b12f986f961e10c0ee44d8b9af11be25588cad89d416118e4bf4ebe80c;
    uint256 internal constant ZERO_14 = 0x22f98aa9ce704152ac17354914ad73ed1167ae6596af510aa5b3649325e06c92;
    uint256 internal constant ZERO_15 = 0x2a7c7c9b6ce5880b9f6f228d72bf6a575a526f29c66ecceef8b753d38bba7323;
    uint256 internal constant ZERO_16 = 0x2e8186e558698ec1c67af9c14d463ffc470043c9c2988b954d75dd643f36b992;
    uint256 internal constant ZERO_17 = 0x0f57c5571e9a4eab49e2c8cf050dae948aef6ead647392273546249d1c1ff10f;
    uint256 internal constant ZERO_18 = 0x1830ee67b5fb554ad5f63d4388800e1cfe78e310697d46e43c9ce36134f72cca;
    uint256 internal constant ZERO_19 = 0x2134e76ac5d21aab186c2be1dd8f84ee880a1e46eaf712f9d371b6df22191f3e;
    uint256 internal constant EMPTY_TREE_ROOT     = 0x19df90ec844ebc4ffeebd866f33859b0c051d8c958ee3aa88f8f8df3db91a5b1;

    uint256 internal constant DEPOSIT_CONFIG_HASH  = 0xa6eef7e35abe7026729641147f7915573c7e97b47efa546f5f6e3230263bcb49;
    uint256 internal constant TX_CONFIG_HASH       = 0x679795a0195a1b76cdebb7c51d74e058aee92919b8c3389af86ef24535e8a28c;
    uint256 internal constant TX_1X2_CONFIG_HASH   = 0xe90b7bceb6e7df5418fb78d8ee546e97c83a08bbccc01a0644d599ccd2a7c2e0;
    uint256 internal constant NATIVE_TOKEN_HASH    = 0x122a4347836b3a5fb826882d08eb53ff8217fcff441464b5bfbacdd048fa40f3;

    // ─── Per-network init constants — patched by patch-contracts.js from configs/<net>.json ───
    uint256 internal constant INIT_PROTOCOL_FEE_BPS = 0;
    address internal constant INIT_TREASURY         = 0x0000000000000000000000000000000000000000;
    uint256 internal constant INIT_UNSHIELD_DELAY   = 0;
    uint256 internal constant INIT_ASP_STALENESS    = 86400;
    bytes   internal constant INIT_WHITELIST_TOKENS = hex"c0";
    bytes   internal constant INIT_ASP_LIST         = hex"c0";

    // ─── VK blobs (precompile-format: alpha||beta||gamma||delta||IC[0..n]) ───
    bytes internal constant DEPOSIT_VK_BLOB =
        hex"036a40a44350038a6699f50a82351fbccb3313aa873f6ccf66e2076605727c0a"
        hex"155928afaf5a45ca683061414d69fbe5a20f3ee45124bfbeebe769d1e86025a4"
        hex"234e4c7640273bc903e5d1871783af7a8bb8834a7489cccf360e1c4c955de4d6"
        hex"0b6f90089edb63e0a54c59bdda6546c4a47f4e1433b67af1a117c3b8818824c4"
        hex"2986ffb3f8524fd796d3bcbf19791c7c5a1223a0543e5ebfcfd966eacf8fa0e7"
        hex"1e1edef0ca11913f3c06939f2cb80890ac2e7cc343de3754dfaeb027684517bf"
        hex"198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2"
        hex"1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed"
        hex"090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b"
        hex"12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa"
        hex"2cfa9c54286023e5899b41a5cd3ed8444b13b1c5421c3cc20239b4bd6acaeee5"
        hex"2b67fc84483d2cc6894c8603198a102202503ec96b70f2c1adda0a505cde07bb"
        hex"21d3c39755af38707d9349a148eb8cbccf2650fb637defb06fd6277a38b6d099"
        hex"03a9c0e9afbb7796cc609c68bcd25afa3c826b56107849fecdead421aaaf845d"
        hex"075b528827f2aa1df31d614a95f4aebb38d5eebaa0d2f894045b27cc551f9a6a"
        hex"24df44797f0ef748972a3e5a39d7635599b69dbcebc6ffdae23a498dabc327bb"
        hex"016ca787d3566ea5789752b3c4bb9a581945dd3ac3490bffd9308cd730c5eec0"
        hex"04b58d702d3f0497fe8b923793a8336fa677ecde65aeff95384538d476638be7"
        hex"0a8bb4f6dc0380556e662deccbe5e09166967cdcb6a158687aaf6a8c6b22121f"
        hex"2ce229da3b513c10fa15f8d59a1a2bd76937dd8ad79da27eafd4987cccc9d750"
        hex"2d78597cd73e900d22078f9895f53d3ada91661bae0acbf9d78f70c5b6e10534"
        hex"0ed19ccca0818ee4ded355181414a40e46e5f635c0188c6957d0c5a2a21b81bc";

    bytes internal constant TRANSACTION_VK_BLOB =
        hex"036a40a44350038a6699f50a82351fbccb3313aa873f6ccf66e2076605727c0a"
        hex"155928afaf5a45ca683061414d69fbe5a20f3ee45124bfbeebe769d1e86025a4"
        hex"234e4c7640273bc903e5d1871783af7a8bb8834a7489cccf360e1c4c955de4d6"
        hex"0b6f90089edb63e0a54c59bdda6546c4a47f4e1433b67af1a117c3b8818824c4"
        hex"2986ffb3f8524fd796d3bcbf19791c7c5a1223a0543e5ebfcfd966eacf8fa0e7"
        hex"1e1edef0ca11913f3c06939f2cb80890ac2e7cc343de3754dfaeb027684517bf"
        hex"198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2"
        hex"1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed"
        hex"090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b"
        hex"12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa"
        hex"2b53d8076ffe9c5694fa7644d27eaf2a7450d93f16e318421d02c07c20cb72bb"
        hex"19d00bd4a9992b6e833f6356d908b6f63e206cc23d765c46aa182d660c9eb609"
        hex"0533e6a19170362a3dc5e714815c0d955dff816ab4ac26dc8f445333fa48b1d8"
        hex"147ea6fe50a2f6c545649cc76ad3dabbcf2442010a184302e26d6c06b6a66823"
        hex"1d0f095a398e7696b4f6a3a0866015b1d9f3bd4a1e03138897868dde00d886ff"
        hex"080127a177cbf3d0f92f8ab8e1f59fb3bb4608ea3d7043924612cb56831f11b6"
        hex"10c6a887e824367767277acbe48c48745501de1659fa368e6132be7cd030964e"
        hex"21cfb7269339bba62641b3ef769f5305a0ee041be3d843f75efb62c4d851be37"
        hex"138ba30a8eb9b123860ab8fd3b94870a2d1ced31c3dd3eb25224ab86a547981b"
        hex"045cbef55e6c825adfd83e7d1aaa63b843f2fef62661fd5135f90cd9f18697bf"
        hex"29dfe396176b5e7a3426539c7b40c227ede640cd76c947568b713e229b64f765"
        hex"16c98de3f349dd7bef7fa6349b5ebc2b00625afca721a566467e7788fb040567"
        hex"183eeadf380042efd63184200c14aed4e4501e6c65b8f2ad1f71122a16fb915d"
        hex"1bdecedcfd17d9997f989db30879204a476da63413faade3606668cc15d439bb"
        hex"21a5b45e5c2d936c0d71071b6e5dee98d3c96580ca0cf48c880b3a93091a110a"
        hex"0895683b733f1cc47124efd680f6ee01746606ccba3335ad5a91a257feafa896"
        hex"0271fe66a84a5869bc07c7d3a3720decd82980c4832d93829230d59963de2a86"
        hex"0153a101e344863a82affdf2910b15db9fe8cc12ed910ce899aa8b0055657b10"
        hex"254475d79451b89571feca2be81bd121fd88cc2d70f30b4fea5a42d7f9a183f5"
        hex"2e3d26b90f64dc8edb698e8ccfc2470a043ba72c11bbf9243ec558306bf7e566"
        hex"280c45be11f51b25a3b2cd086ff2fbbab8e94e154273d2a8906c2086f3c1928d"
        hex"27a402b6d0392b8e4dfdb3ce7f116f399b8860834c2b2d592ff407d4f230b204"
        hex"14056dc7b85c23a3ef0ba4f0e7fbe6bbd13d629c6d873f1a5d8e7efb27b84f04"
        hex"27d48f287233aba6c67918e615ab772ccb64b7d0136fd920096f652003481d72";

    bytes internal constant TRANSACTION1X2_VK_BLOB =
        hex"036a40a44350038a6699f50a82351fbccb3313aa873f6ccf66e2076605727c0a"
        hex"155928afaf5a45ca683061414d69fbe5a20f3ee45124bfbeebe769d1e86025a4"
        hex"234e4c7640273bc903e5d1871783af7a8bb8834a7489cccf360e1c4c955de4d6"
        hex"0b6f90089edb63e0a54c59bdda6546c4a47f4e1433b67af1a117c3b8818824c4"
        hex"2986ffb3f8524fd796d3bcbf19791c7c5a1223a0543e5ebfcfd966eacf8fa0e7"
        hex"1e1edef0ca11913f3c06939f2cb80890ac2e7cc343de3754dfaeb027684517bf"
        hex"198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2"
        hex"1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed"
        hex"090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b"
        hex"12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa"
        hex"20e5cac0db6e6157a94d7d9e998ffbc2cd9324706ebff9597118b8a7cf90c0c9"
        hex"0d4bb923888df8dfffd692fc6811115e6a2df70203f2d85c7c65ddd3536b4178"
        hex"2dce82191f223fef389734b0d2f678b73791b52afe9b3ebed6477bbf411c95bd"
        hex"24d296a51117fdf21046427a5616b3ee7f5e3ab609337c72a01ec2285533269c"
        hex"1c84b20b24040d8f48d36d84e5b4456e066c9e9ccf655ed92e71a8c635d706b8"
        hex"0855a3b76765ad49b9a2c2994aed89a6ceb14f23744c2d3bb9ee875acda35ba2"
        hex"15d02559b585950b4294ff4459ba8347f8cd9f4ef5b12b8d5cfa8cc27fd47b74"
        hex"1aa1b9aba6b2c5aa1bbf5ba399daaa9c0f8c7af43682d994a5f9a549ae041a1a"
        hex"26052851b055edbc619db83a2e17fad04be54ffadcfc47a90dd04058f2194812"
        hex"2dc2e272c8c83025bba31c3d8401fe24f4a80e6e8c581b94668b4e90cbf97f2f"
        hex"2bb845c96f1382a7e41f9d51b4c1880026f12ddafe12ccdfde0ae897f8a7530b"
        hex"0d940cf28cf99bdd8971240de501452bebfb5eb72b9d5a3ffe545dfb6e49d0d2"
        hex"0f2b4392f0d2af0ddfcba714ea1ffd8f9906244646505513d7ee31231f2a3a8c"
        hex"1e16ad6c52fc484fa4acf7671a9a2017e9fc3e3422b17caaacd1a8103b7a23a3"
        hex"165ddb6fae7c3775615a52ff18fbceaba69f2cb6a5b92ff39a0d9a7365d29bfe"
        hex"0ea0b29b6199115d8006a3058b7ea5525cf945e91fb6b8e77dccd27cc4c6ccbb"
        hex"0e636dbcfe76ecdb5a723e38e7cbc9494d49a1ec2f575edb5ab9dec126c06b70"
        hex"05789557d0062b7413ac15e890d4679ed0d879128044f10e30c4049abe5517e6"
        hex"17ee1bbb5d31309ce09ebf52bb208d595d46db20deee418277cdbfe3c2cf3d1d"
        hex"1ed3a984a4cac062322a750e596aa1e3ee0c08a5903cd9a7706887ee5cf0a308"
        hex"18a1a5d4ddd9e9bcffe1f4d0d65d9d897d5878e16322ac9d6169966f27a9d0de"
        hex"2447946aa604bd1d61de3cd5aed4be8b736d56d55e18e991a566fcd682dd6e21";

    // ═══════════════════════════════════════════════════════════════════
    //                            STORAGE
    // ═══════════════════════════════════════════════════════════════════

    bool    public paused;
    uint256 public protocolFeeBps;
    address public treasury;
    uint256 public unshieldDelay;
    uint256 private _locked;

    mapping(uint256 => bool)  public nullifiers;
    mapping(uint256 => bool)  public whitelistedTokens;
    mapping(uint256 => bytes) public verifierVKs;

    // CommitmentTree state
    uint256 public currentTreeNumber;
    mapping(uint256 => uint256) public nextLeafIndex;
    mapping(bytes32 => uint256) internal _filledSubtrees;
    mapping(uint256 => mapping(uint256 => bool))    internal _rootHistory;
    mapping(uint256 => mapping(uint256 => uint256)) internal _rootTimestamps;
    mapping(uint256 => uint256) internal _currentRoot;

    // ASPManager state
    IASP[] public aspProviders;
    mapping(address => bool)    public isActiveASP;
    uint256 public aspStalenessThreshold;
    mapping(address => uint256) public associationSetRoots;

    // ═══════════════════════════════════════════════════════════════════
    //                          MODIFIERS
    // ═══════════════════════════════════════════════════════════════════

    modifier nonReentrant() {
        if (_locked != 1) revert ReentrancyErr();
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier whenNotPaused() {
        if (paused) revert PausedError();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════
    //                            INIT
    // ═══════════════════════════════════════════════════════════════════

    function init() external onlyNotInit {
        protocolFeeBps        = INIT_PROTOCOL_FEE_BPS;
        treasury              = INIT_TREASURY;
        unshieldDelay         = INIT_UNSHIELD_DELAY;
        aspStalenessThreshold = INIT_ASP_STALENESS;
        _locked = 1;

        // VK blobs into storage so governance can rotate per circuit later.
        verifierVKs[DEPOSIT_CONFIG_HASH]   = DEPOSIT_VK_BLOB;
        verifierVKs[TX_CONFIG_HASH]        = TRANSACTION_VK_BLOB;
        verifierVKs[TX_1X2_CONFIG_HASH]    = TRANSACTION1X2_VK_BLOB;

        // Tree 0 starts with the precomputed empty-tree root.
        _currentRoot[0]                       = EMPTY_TREE_ROOT;
        _rootHistory[0][EMPTY_TREE_ROOT]      = true;
        _rootTimestamps[0][EMPTY_TREE_ROOT]   = block.timestamp;

        // Native ETH whitelisted by default.
        whitelistedTokens[NATIVE_TOKEN_HASH] = true;
        emit AssetWhitelisted(NATIVE_TOKEN_HASH, NATIVE_TOKEN);

        _applyInitialWhitelist();
        _applyInitialASPs();

        alreadyInit = true;
    }

    function _applyInitialWhitelist() internal {
        bytes memory data = INIT_WHITELIST_TOKENS;
        if (data.length == 0) return;
        RLPDecode.RLPItem[] memory items = data.toRLPItem().toList();
        uint256 n = items.length;
        for (uint256 i = 0; i < n; i++) {
            RLPDecode.RLPItem[] memory entry = items[i].toList();
            uint8   tType = uint8(entry[0].toUint());
            address tk    = entry[1].toAddress();
            uint256 sub   = entry[2].toUint();
            uint256 hash  = _poseidonT4(uint256(tType), uint256(uint160(tk)), sub);
            whitelistedTokens[hash] = true;
            emit AssetWhitelisted(hash, tk);
        }
    }

    function _applyInitialASPs() internal {
        bytes memory data = INIT_ASP_LIST;
        if (data.length == 0) return;
        RLPDecode.RLPItem[] memory items = data.toRLPItem().toList();
        uint256 n = items.length;
        for (uint256 i = 0; i < n; i++) {
            address aspAddr = items[i].toAddress();
            if (aspAddr == address(0)) continue;
            if (isActiveASP[aspAddr]) continue;
            if (aspProviders.length >= MAX_ASP_PROVIDERS) revert TooManyASPs();
            IASP asp = IASP(aspAddr);
            aspProviders.push(asp);
            isActiveASP[aspAddr] = true;
            (string memory name,) = asp.providerInfo();
            emit ASPAdded(aspAddr, name);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //                  PRECOMPILE DISPATCHERS
    // ═══════════════════════════════════════════════════════════════════

    function _poseidonT3(uint256 a, uint256 b) internal view returns (uint256 r) {
        assembly {
            let p := mload(0x40)
            mstore(p, a)
            mstore(add(p, 32), b)
            if iszero(staticcall(gas(), 0x6b, p, 64, p, 32)) { revert(0, 0) }
            r := mload(p)
        }
    }

    function _poseidonT4(uint256 a, uint256 b, uint256 c) internal view returns (uint256 r) {
        assembly {
            let p := mload(0x40)
            mstore(p, a)
            mstore(add(p, 32), b)
            mstore(add(p, 64), c)
            if iszero(staticcall(gas(), 0x6c, p, 96, p, 32)) { revert(0, 0) }
            r := mload(p)
        }
    }

    /// @dev Dispatch a Groth16 verification to precompile 0x6a. The VK is loaded
    ///      from storage into memory by Solidity before this function runs.
    ///      Precompile input layout (see zsp-chain core/vm/contracts_groth16.go:17-29):
    ///        [0:4]    n (uint32 BE)
    ///        [4:68]   proof.A   (G1, 64B)
    ///        [68:132] proof.C   (G1, 64B)
    ///        [132:260] proof.B  (G2, 128B)
    ///        [260:260+vkLen] vk (alpha||beta||gamma||delta||IC[0..n])
    ///        [260+vkLen:end] public inputs (n × 32B)
    function _verifyProof(
        uint256 cfgHash,
        Proof calldata proof,
        uint256[] memory pubSignals
    ) internal view returns (bool valid) {
        bytes memory vk = verifierVKs[cfgHash];
        if (vk.length == 0) revert VKNotSet(cfgHash);
        uint256 n = pubSignals.length;
        uint256 expectedVkLen = 448 + (n + 1) * 64;
        if (vk.length != expectedVkLen) revert VKLengthMismatch(vk.length, expectedVkLen);

        uint256 vkLen     = vk.length;
        uint256 totalLen  = 4 + 64 + 64 + 128 + vkLen + n * 32;

        assembly {
            let buf := mload(0x40)
            // Reserve buf + totalLen + 32 (for output) of memory.
            mstore(0x40, add(buf, add(totalLen, 32)))

            // numPubInputs as uint32 big-endian in the first 4 bytes.
            mstore(buf, shl(224, n))
            let p := add(buf, 4)

            // Calldata layout of `Proof`:
            //   offset 0:    a   (uint256[2]   = 64 bytes)
            //   offset 64:   b   (uint256[2][2]= 128 bytes)
            //   offset 192:  c   (uint256[2]   = 64 bytes)
            calldatacopy(p, proof, 64)             // A
            p := add(p, 64)
            calldatacopy(p, add(proof, 192), 64)   // C
            p := add(p, 64)
            calldatacopy(p, add(proof, 64), 128)   // B
            p := add(p, 128)

            // Copy VK from memory (skip the 32-byte length prefix).
            mcopy(p, add(vk, 32), vkLen)
            p := add(p, vkLen)

            // Public inputs (uint256[] memory) — element data starts at pubSignals + 32.
            mcopy(p, add(pubSignals, 32), mul(n, 32))

            // staticcall to precompile 0x6a; output is a single 32-byte word (1 = valid).
            let outBuf := mload(0x40)
            mstore(0x40, add(outBuf, 32))
            let ok := staticcall(gas(), 0x6a, buf, totalLen, outBuf, 32)
            if iszero(ok) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            valid := eq(mload(outBuf), 1)
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //                  COMMITMENT TREE (inlined)
    // ═══════════════════════════════════════════════════════════════════

    function _zeroAtLevel(uint256 i) internal pure returns (uint256) {
        if (i == 0)  return ZERO_00;
        if (i == 1)  return ZERO_01;
        if (i == 2)  return ZERO_02;
        if (i == 3)  return ZERO_03;
        if (i == 4)  return ZERO_04;
        if (i == 5)  return ZERO_05;
        if (i == 6)  return ZERO_06;
        if (i == 7)  return ZERO_07;
        if (i == 8)  return ZERO_08;
        if (i == 9)  return ZERO_09;
        if (i == 10) return ZERO_10;
        if (i == 11) return ZERO_11;
        if (i == 12) return ZERO_12;
        if (i == 13) return ZERO_13;
        if (i == 14) return ZERO_14;
        if (i == 15) return ZERO_15;
        if (i == 16) return ZERO_16;
        if (i == 17) return ZERO_17;
        if (i == 18) return ZERO_18;
        if (i == 19) return ZERO_19;
        revert();
    }

    function _insertLeaf(uint256 leaf) internal returns (uint256 treeNum, uint256 leafIdx) {
        if (leaf == 0) revert ZeroLeaf();
        if (leaf >= SNARK_SCALAR_FIELD) revert LeafOutOfField();

        treeNum = currentTreeNumber;
        leafIdx = nextLeafIndex[treeNum];

        if (leafIdx >= MAX_LEAVES) {
            unchecked { treeNum++; }
            currentTreeNumber = treeNum;
            leafIdx = 0;
            _currentRoot[treeNum]                       = EMPTY_TREE_ROOT;
            _rootHistory[treeNum][EMPTY_TREE_ROOT]      = true;
            _rootTimestamps[treeNum][EMPTY_TREE_ROOT]   = block.timestamp;
            emit TreeCreated(treeNum);
        }

        uint256 currentIndex = leafIdx;
        uint256 currentLevelHash = leaf;

        for (uint256 i = 0; i < TREE_DEPTH;) {
            bytes32 subtreeKey = keccak256(abi.encode(treeNum, i));
            if (currentIndex & 1 == 0) {
                _filledSubtrees[subtreeKey] = currentLevelHash;
                currentLevelHash = _poseidonT3(currentLevelHash, _zeroAtLevel(i));
            } else {
                currentLevelHash = _poseidonT3(_filledSubtrees[subtreeKey], currentLevelHash);
            }
            currentIndex >>= 1;
            unchecked { ++i; }
        }

        _currentRoot[treeNum]                       = currentLevelHash;
        _rootHistory[treeNum][currentLevelHash]     = true;
        _rootTimestamps[treeNum][currentLevelHash]  = block.timestamp;
        unchecked { nextLeafIndex[treeNum] = leafIdx + 1; }
    }

    function _insertLeaves(uint256[] memory leaves) internal returns (uint256 treeNum, uint256 startIdx) {
        uint256 len = leaves.length;
        if (len == 0) return (currentTreeNumber, nextLeafIndex[currentTreeNumber]);
        (treeNum, startIdx) = _insertLeaf(leaves[0]);
        for (uint256 i = 1; i < len;) {
            _insertLeaf(leaves[i]);
            unchecked { ++i; }
        }
    }

    function _isKnownRoot(uint256 treeNumber, uint256 root) internal view returns (bool) {
        if (root == 0) return false;
        return _rootHistory[treeNumber][root];
    }

    // ═══════════════════════════════════════════════════════════════════
    //                  ASP MANAGER (inlined)
    // ═══════════════════════════════════════════════════════════════════

    function _screenWallet(address wallet) internal view {
        uint256 len = aspProviders.length;
        if (len == 0) return;
        for (uint256 i = 0; i < len;) {
            IASP asp = aspProviders[i];
            if (isActiveASP[address(asp)]) {
                (bool approved, uint256 lastUpdated) = asp.isApproved(wallet);
                if (block.timestamp - lastUpdated > aspStalenessThreshold) {
                    revert ASPDataStale(address(asp), lastUpdated, aspStalenessThreshold);
                }
                if (!approved) revert WalletNotApproved(wallet);
            }
            unchecked { ++i; }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    //                  TOKEN HASH HELPERS (from NoteLib)
    // ═══════════════════════════════════════════════════════════════════

    function _computeTokenHash(uint8 tokenType, address tokenAddr, uint256 tokenSubID)
        internal view returns (uint256)
    {
        return _poseidonT4(uint256(tokenType), uint256(uint160(tokenAddr)), tokenSubID);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                  CIRCUIT CONFIG / VALIDATION HELPERS
    // ═══════════════════════════════════════════════════════════════════

    function _getCircuitConfigHash(uint256 numIn, uint256 numOut) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(numIn, numOut)));
    }

    function _isSupportedTxConfig(uint256 cfgHash) internal pure returns (bool) {
        return cfgHash == TX_CONFIG_HASH || cfgHash == TX_1X2_CONFIG_HASH;
    }

    function _validateMerkleRootInTree(uint256 treeNumber, uint256 root) internal view {
        if (root == 0) revert InputOutOfField(0);
        if (root >= SNARK_SCALAR_FIELD) revert InputOutOfField(root);
        if (treeNumber > currentTreeNumber) revert InvalidTreeNumber();
        if (!_isKnownRoot(treeNumber, root)) revert UnknownMerkleRoot(root);
    }

    function _validateAndMarkNullifiers(uint256[] calldata _nullifiers) internal {
        uint256 len = _nullifiers.length;
        for (uint256 i = 0; i < len;) {
            uint256 nullifier = _nullifiers[i];
            if (nullifier == 0) revert InputOutOfField(0);
            if (nullifier >= SNARK_SCALAR_FIELD) revert InputOutOfField(nullifier);
            for (uint256 j = 0; j < i;) {
                if (_nullifiers[j] == nullifier) revert DuplicateNullifierInBatch();
                unchecked { ++j; }
            }
            if (nullifiers[nullifier]) revert NullifierAlreadySpent(nullifier);
            nullifiers[nullifier] = true;
            unchecked { ++i; }
        }
    }

    function _validateCommitments(uint256[] calldata _commitments) internal pure {
        uint256 len = _commitments.length;
        for (uint256 i = 0; i < len;) {
            if (_commitments[i] == 0) revert InputOutOfField(0);
            if (_commitments[i] >= SNARK_SCALAR_FIELD) revert InputOutOfField(_commitments[i]);
            unchecked { ++i; }
        }
    }

    function _buildPubSignals(
        uint256 merkleRoot,
        uint256 boundParamsHash,
        uint256[] calldata _nullifiers,
        uint256[] calldata _commitments,
        uint256 publicAmount,
        uint256 tokenHash,
        uint256 actionHash
    ) internal pure returns (uint256[] memory pubSignals) {
        uint256 nLen = _nullifiers.length;
        uint256 cLen = _commitments.length;
        pubSignals = new uint256[](5 + nLen + cLen);
        pubSignals[0] = merkleRoot;
        pubSignals[1] = boundParamsHash;
        for (uint256 i = 0; i < nLen;) { pubSignals[2 + i] = _nullifiers[i]; unchecked { ++i; } }
        for (uint256 i = 0; i < cLen;) { pubSignals[2 + nLen + i] = _commitments[i]; unchecked { ++i; } }
        pubSignals[2 + nLen + cLen] = publicAmount;
        pubSignals[3 + nLen + cLen] = tokenHash;
        pubSignals[4 + nLen + cLen] = actionHash;
    }

    function _toMemoryArray(uint256[] calldata arr) internal pure returns (uint256[] memory mem) {
        uint256 n = arr.length;
        mem = new uint256[](n);
        for (uint256 i = 0; i < n;) { mem[i] = arr[i]; unchecked { ++i; } }
    }

    // ═══════════════════════════════════════════════════════════════════
    //                            SHIELD
    // ═══════════════════════════════════════════════════════════════════

    function shield(ShieldParams[] calldata params) external payable nonReentrant whenNotPaused {
        uint256 len = params.length;
        if (len == 0) revert InsufficientDeposit();

        _screenWallet(msg.sender);

        uint256[] memory commitmentsList = new uint256[](len);
        bytes[] memory encryptedNotes    = new bytes[](len);

        uint256 totalETHRequired = 0;

        for (uint256 i = 0; i < len;) {
            ShieldParams calldata p = params[i];
            if (p.value == 0) revert InsufficientDeposit();
            if (p.commitment == 0) revert InputOutOfField(0);
            if (p.commitment >= SNARK_SCALAR_FIELD) revert InputOutOfField(p.commitment);

            uint256 tokenHash;
            bool isNative = p.tokenAddress == NATIVE_TOKEN;
            if (isNative) {
                tokenHash = NATIVE_TOKEN_HASH;
            } else {
                tokenHash = _computeTokenHash(p.tokenType, p.tokenAddress, p.tokenSubID);
            }
            if (!whitelistedTokens[tokenHash]) revert AssetNotWhitelisted(tokenHash);

            {
                uint256[] memory pubs = new uint256[](3);
                pubs[0] = p.commitment;
                pubs[1] = tokenHash;
                pubs[2] = uint256(p.value);
                if (!_verifyProof(DEPOSIT_CONFIG_HASH, p.proof, pubs)) revert InvalidProof();
            }

            {
                uint256 fee = uint256(p.value) * protocolFeeBps / 10_000;
                if (isNative) {
                    totalETHRequired += uint256(p.value) + fee;
                    if (fee > 0) {
                        if (treasury == address(0)) revert TreasuryNotSet();
                        _safeTransferETH(treasury, fee);
                    }
                } else {
                    uint256 balBefore = _balanceOf(p.tokenAddress, address(this));
                    _safeTransferFrom(p.tokenAddress, msg.sender, address(this), uint256(p.value));
                    if (_balanceOf(p.tokenAddress, address(this)) - balBefore != uint256(p.value)) {
                        revert FeeOnTransferNotSupported();
                    }
                    if (fee > 0) {
                        if (treasury == address(0)) revert TreasuryNotSet();
                        _safeTransferFrom(p.tokenAddress, msg.sender, treasury, fee);
                    }
                }
            }

            commitmentsList[i] = p.commitment;
            encryptedNotes[i]  = p.encryptedNote;
            unchecked { ++i; }
        }

        if (totalETHRequired > 0) {
            if (msg.value != totalETHRequired) revert InvalidMsgValue();
        } else {
            if (msg.value != 0) revert InvalidMsgValue();
        }

        (uint256 treeNum, uint256 startIdx) = _insertLeaves(commitmentsList);
        emit Shield(treeNum, startIdx, commitmentsList, encryptedNotes);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                            TRANSACT
    // ═══════════════════════════════════════════════════════════════════

    function transact(TransactParams calldata params) external nonReentrant whenNotPaused {
        uint256 numNullifiers  = params.nullifiers.length;
        uint256 numCommitments = params.commitments.length;

        uint256 cfgHash = _getCircuitConfigHash(numNullifiers, numCommitments);
        if (!_isSupportedTxConfig(cfgHash)) revert InvalidCircuitConfig();
        if (params.encryptedNotes.length != numCommitments) revert InvalidEncryptedNotesLength();
        if (params.boundParamsHash >= SNARK_SCALAR_FIELD) revert InputOutOfField(params.boundParamsHash);
        if (params.tokenHash == 0 || params.tokenHash >= SNARK_SCALAR_FIELD) revert InputOutOfField(params.tokenHash);
        if (!whitelistedTokens[params.tokenHash]) revert AssetNotWhitelisted(params.tokenHash);

        _validateMerkleRootInTree(params.treeNumber, params.merkleRoot);
        _validateAndMarkNullifiers(params.nullifiers);
        _validateCommitments(params.commitments);

        uint256[] memory pubs = _buildPubSignals(
            params.merkleRoot, params.boundParamsHash, params.nullifiers, params.commitments,
            0, params.tokenHash, params.actionHash
        );
        if (!_verifyProof(cfgHash, params.proof, pubs)) revert InvalidProof();

        uint256[] memory commitmentsMem = _toMemoryArray(params.commitments);
        (uint256 treeNum,) = _insertLeaves(commitmentsMem);

        emit Transact(treeNum, params.nullifiers, commitmentsMem, params.encryptedNotes);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                            UNSHIELD
    // ═══════════════════════════════════════════════════════════════════

    function unshield(UnshieldParams calldata params) external nonReentrant whenNotPaused {
        if (params.recipient == address(0)) revert InvalidRecipient();
        if (params.amount == 0) revert InsufficientDeposit();

        uint256 protocolFee = params.amount * protocolFeeBps / 10_000;
        if (params.fee + protocolFee > params.amount) revert InvalidBroadcasterFee();
        if (params.boundParamsHash >= SNARK_SCALAR_FIELD) revert InputOutOfField(params.boundParamsHash);

        _validateUnshieldConfig(params);
        _screenWallet(params.recipient);

        {
            uint256 expectedBoundHash = uint256(keccak256(abi.encode(
                params.recipient, params.token, params.amount, params.fee, params.broadcaster
            ))) % SNARK_SCALAR_FIELD;
            if (expectedBoundHash != params.boundParamsHash) revert InvalidBroadcasterFee();
        }

        bool isNative = params.token == NATIVE_TOKEN;
        uint256 expectedTokenHash = isNative
            ? NATIVE_TOKEN_HASH
            : _computeTokenHash(TOKEN_TYPE_ERC20, params.token, 0);

        _validateMerkleRootInTree(params.treeNumber, params.merkleRoot);

        if (unshieldDelay > 0) {
            uint256 rootTs = _rootTimestamps[params.treeNumber][params.merkleRoot];
            if (block.timestamp - rootTs < unshieldDelay) {
                revert UnshieldDelayNotMet(rootTs, unshieldDelay);
            }
        }

        _validateAndMarkNullifiers(params.nullifiers);
        _validateCommitments(params.commitments);

        {
            uint256 cfgHash = _getCircuitConfigHash(params.nullifiers.length, params.commitments.length);
            uint256[] memory pubs = _buildPubSignals(
                params.merkleRoot, params.boundParamsHash, params.nullifiers, params.commitments,
                params.amount, expectedTokenHash, params.actionHash
            );
            if (!_verifyProof(cfgHash, params.proof, pubs)) revert InvalidProof();
        }

        if (params.commitments.length > 0) {
            _insertLeaves(_toMemoryArray(params.commitments));
        }

        uint256 recipientAmount = params.amount - protocolFee - params.fee;
        if (isNative) {
            _safeTransferETH(params.recipient, recipientAmount);
        } else {
            _safeTransfer(params.token, params.recipient, recipientAmount);
        }

        if (protocolFee > 0) {
            if (treasury == address(0)) revert TreasuryNotSet();
            if (isNative) _safeTransferETH(treasury, protocolFee);
            else          _safeTransfer(params.token, treasury, protocolFee);
        }

        if (params.fee > 0 && params.broadcaster != address(0)) {
            if (isNative) _safeTransferETH(params.broadcaster, params.fee);
            else          _safeTransfer(params.token, params.broadcaster, params.fee);
        }

        emit Unshield(params.recipient, params.token, params.amount, params.fee, protocolFee, params.broadcaster);
    }

    function _validateUnshieldConfig(UnshieldParams calldata params) internal pure {
        uint256 cfgHash = _getCircuitConfigHash(params.nullifiers.length, params.commitments.length);
        if (!_isSupportedTxConfig(cfgHash)) revert InvalidCircuitConfig();
        if (params.encryptedNotes.length != params.commitments.length) revert InvalidEncryptedNotesLength();
    }

    // ═══════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════

    function isKnownRoot(uint256 treeNumber, uint256 root) external view returns (bool) {
        return _isKnownRoot(treeNumber, root);
    }

    function isNullifierSpent(uint256 nullifier) external view returns (bool) {
        return nullifiers[nullifier];
    }

    function getMerkleRoot(uint256 treeNumber) external view returns (uint256) {
        return _currentRoot[treeNumber];
    }

    function getRootTimestamp(uint256 treeNumber, uint256 root) external view returns (uint256) {
        return _rootTimestamps[treeNumber][root];
    }

    function getCircuitConfigHash(uint256 numIn, uint256 numOut) external pure returns (uint256) {
        return _getCircuitConfigHash(numIn, numOut);
    }

    function getDepositConfigHash() external pure returns (uint256) { return DEPOSIT_CONFIG_HASH; }
    function getTxConfigHash() external pure returns (uint256)      { return TX_CONFIG_HASH; }
    function getTx1x2ConfigHash() external pure returns (uint256)   { return TX_1X2_CONFIG_HASH; }
    function getTreeDepth() external pure returns (uint256)         { return TREE_DEPTH; }
    function getNativeTokenHash() external pure returns (uint256)   { return NATIVE_TOKEN_HASH; }

    function updateAssociationSetRoot(IASP asp) external {
        if (!isActiveASP[address(asp)]) revert ASPNotRegisteredErr(address(asp));
        uint256 root = asp.getAssociationSetRoot();
        associationSetRoots[address(asp)] = root;
        emit AssociationSetRootUpdated(address(asp), root);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                       SAFE TRANSFER HELPERS
    // ═══════════════════════════════════════════════════════════════════

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _balanceOf(address token, address account) internal view returns (uint256) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSelector(0x70a08231, account)
        );
        if (!success || data.length < 32) revert TransferFailed();
        return abi.decode(data, (uint256));
    }

    function _safeTransferETH(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert ETHTransferFailed();
    }

    // ═══════════════════════════════════════════════════════════════════
    //                  GOVERNANCE: IParamSubscriber
    // ═══════════════════════════════════════════════════════════════════

    /// @inheritdoc IParamSubscriber
    /// @dev Routes governance proposals from GovHub (0x1006) to MASP admin operations.
    ///      All `value` payloads are abi.encode of the argument list expected by the corresponding action.
    ///
    /// Supported keys:
    ///   "protocolFeeBps"          : uint256 feeBps                    (0–500)
    ///   "treasury"                : address treasury
    ///   "unshieldDelay"           : uint256 seconds                   (0–7 days)
    ///   "paused"                  : bool paused
    ///   "aspStaleness"            : uint256 seconds
    ///   "addASP"                  : address asp
    ///   "removeASP"               : address asp
    ///   "whitelistToken"          : (uint8 tType, address tk, uint256 sub)
    ///   "removeWhitelistedToken"  : (uint8 tType, address tk, uint256 sub)
    ///   "vk"                      : (uint256 cfgHash, bytes vkBytes)  — circuit-rotation
    function updateParam(string calldata key, bytes calldata value)
        external
        override
        onlyInit
        onlyGov
    {
        if (Memory.compareStrings(key, "protocolFeeBps")) {
            if (value.length != 32) revert MismatchParamLength(key);
            uint256 feeBps = BytesToTypes.bytesToUint256(32, value);
            if (feeBps > MAX_PROTOCOL_FEE_BPS) revert OutOfBounds(key, feeBps, 0, MAX_PROTOCOL_FEE_BPS);
            protocolFeeBps = feeBps;
            emit ProtocolFeeUpdated(feeBps);

        } else if (Memory.compareStrings(key, "treasury")) {
            if (value.length != 32) revert MismatchParamLength(key);
            address t = BytesToTypes.bytesToAddress(32, value);
            if (t == address(0)) revert ZeroAddressErr();
            treasury = t;
            emit TreasuryUpdated(t);

        } else if (Memory.compareStrings(key, "unshieldDelay")) {
            if (value.length != 32) revert MismatchParamLength(key);
            uint256 d = BytesToTypes.bytesToUint256(32, value);
            if (d > MAX_UNSHIELD_DELAY) revert UnshieldDelayTooLong();
            unshieldDelay = d;
            emit UnshieldDelayUpdated(d);

        } else if (Memory.compareStrings(key, "paused")) {
            if (value.length != 32) revert MismatchParamLength(key);
            bool p = BytesToTypes.bytesToBool(32, value);
            paused = p;
            emit PauseStatusChanged(p);

        } else if (Memory.compareStrings(key, "aspStaleness")) {
            if (value.length != 32) revert MismatchParamLength(key);
            uint256 s = BytesToTypes.bytesToUint256(32, value);
            aspStalenessThreshold = s;
            emit ASPStalenessThresholdUpdated(s);

        } else if (Memory.compareStrings(key, "addASP")) {
            if (value.length != 32) revert MismatchParamLength(key);
            address aspAddr = BytesToTypes.bytesToAddress(32, value);
            if (aspAddr == address(0)) revert ZeroAddressErr();
            if (isActiveASP[aspAddr]) revert ASPAlreadyRegistered(aspAddr);
            if (aspProviders.length >= MAX_ASP_PROVIDERS) revert TooManyASPs();
            IASP asp = IASP(aspAddr);
            aspProviders.push(asp);
            isActiveASP[aspAddr] = true;
            (string memory name,) = asp.providerInfo();
            emit ASPAdded(aspAddr, name);

        } else if (Memory.compareStrings(key, "removeASP")) {
            if (value.length != 32) revert MismatchParamLength(key);
            address aspAddr = BytesToTypes.bytesToAddress(32, value);
            if (!isActiveASP[aspAddr]) revert ASPNotRegisteredErr(aspAddr);
            isActiveASP[aspAddr] = false;
            emit ASPRemoved(aspAddr);

        } else if (Memory.compareStrings(key, "whitelistToken")) {
            (uint8 tType, address tk, uint256 sub) = abi.decode(value, (uint8, address, uint256));
            if (tType != TOKEN_TYPE_ERC20) revert InvalidTokenType();
            if (tk == address(0)) revert ZeroAddressErr();
            uint256 hash = _computeTokenHash(tType, tk, sub);
            whitelistedTokens[hash] = true;
            emit AssetWhitelisted(hash, tk);

        } else if (Memory.compareStrings(key, "removeWhitelistedToken")) {
            (uint8 tType, address tk, uint256 sub) = abi.decode(value, (uint8, address, uint256));
            uint256 hash = _computeTokenHash(tType, tk, sub);
            whitelistedTokens[hash] = false;
            emit AssetRemovedFromWhitelist(hash, tk);

        } else if (Memory.compareStrings(key, "vk")) {
            (uint256 cfgHash, bytes memory vkBytes) = abi.decode(value, (uint256, bytes));
            // Sanity check: VK must be the precompile-format alpha||beta||gamma||delta||IC[0..n].
            // For some n, len = 448 + (n+1)*64 = 512 + n*64.
            if (vkBytes.length < 512 || (vkBytes.length - 512) % 64 != 0) {
                revert VKLengthMismatch(vkBytes.length, 0);
            }
            verifierVKs[cfgHash] = vkBytes;
            emit VerifierVKUpdated(cfgHash, vkBytes.length);

        } else {
            revert UnsupportedGovParam(key);
        }

        emit paramChange(key, value);
    }
}
