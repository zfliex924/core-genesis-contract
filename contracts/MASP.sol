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
        Proof      proof;
        uint256    treeNumber;
        uint256    merkleRoot;
        uint256    boundParamsHash;
        uint256    actionHash;
        uint256[]  nullifiers;
        uint256[]  commitments;
        bytes[]    encryptedNotes;
        uint256[2] publicTokenHashes;
    }

    struct UnshieldParams {
        Proof      proof;
        uint256    treeNumber;
        uint256    merkleRoot;
        uint256    boundParamsHash;
        uint256    actionHash;
        uint256[]  nullifiers;
        uint256[]  commitments;
        bytes[]    encryptedNotes;
        address    recipient;
        address    broadcaster;
        address[2] tokens;
        uint8[2]   tokenTypes;
        uint256[2] tokenSubIDs;
        uint256[2] amounts;
        uint256[2] fees;
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
    error InvalidERC721Value();
    error ERC721TransferFailed();
    error UnsupportedTokenSubID();
    // Note: MismatchParamLength, OutOfBounds, UnsupportedGovParam are inherited from System.sol.

    // ═══════════════════════════════════════════════════════════════════
    //                       CONSTANTS — fixed at deploy
    // ═══════════════════════════════════════════════════════════════════

    uint256 internal constant SNARK_SCALAR_FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    uint8   internal constant TOKEN_TYPE_ERC20  = 0;
    uint8   internal constant TOKEN_TYPE_ERC721 = 1;
    uint8   internal constant TOKEN_TYPE_NATIVE = 0xFF;
    address internal constant NATIVE_TOKEN      = address(0);
    bytes4  internal constant ERC721_RECEIVED   = 0x150b7a02;

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
    uint256 internal constant TX_CONFIG_HASH       = 0xb83181f813bc01d9ef3672a7e7501a60cc906f0ffcc4c9dc10e237ddc944074d;
    uint256 internal constant TX_1X2_CONFIG_HASH   = 0xd641d45893dbf9c9105683da450b8f2f1b8b42aca80e7f4f41d74ac6f5b60c99;
    uint256 internal constant TX_1X3_CONFIG_HASH   = 0x3612a9617b34a751d5c0ea221087de877dc82f35389024228f1f907989eb11f8;
    uint256 internal constant TX_2X4_CONFIG_HASH   = 0xd5c213812c1fe873369f86a110aea54fbb31db5d63c5aa5e84ee1b2e3890331b;
    uint256 internal constant TX_3X3_CONFIG_HASH   = 0x351c8ee00ea3334170b7e1a2be6488d4b31010c4ff39e5f1697286fd782d5ed3;
    uint256 internal constant TX_2X8_CONFIG_HASH   = 0x50850f7a432e6555b482bcd558984e73a37755025b3db397a83a2134173f7f67;
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
        hex"213b752e619d8d4c9c02848ab9e7e3818e6cb46c692e2ffa7d3b649db159d947"
        hex"1202ce1ad0bf674f14f0dfa777d424e611780a75e1cc1e531a8dff7b97a1dd05"
        hex"0ab1acfeffba487ad46f505667132a38d622500aefab32a525d3ca2a1994fab8"
        hex"1c7a2fae2731190438fa55b228fa48a0a495f581b4fc819f8fedd46505d852ad"
        hex"0296b9b2f8679356ed283e42bc6d939ff166cc84cd2de4900685cbd8a7e02be2"
        hex"240eba6dbcf2e8090c8c68e1d8d6c231e9dbd26c5de7a55d133df6ebb1ee4bf7"
        hex"198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2"
        hex"1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed"
        hex"090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b"
        hex"12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa"
        hex"293db4c708c9aec70b0f27e9055178ba3b3d62fd30d28c241e44c7809181c596"
        hex"0389cf3fb60baba19f23cffe209ac2a53ba943fd225c3c8fce3a315aaec88d0f"
        hex"094c0f0eed3082e98c244a32da92f588b395576eec589dcdcd3093eb5cca22aa"
        hex"1ea7558125316ef869359f82e9b7ddfcaea60995f53d725a6bf796f263a1f794"
        hex"10644b2a6a176b2dbc0dfd0833f115972b7db3fef9041ce40948be7ce87554c3"
        hex"1abf92ba8e1c44d77cc14d357ffd9315b35f87b6a7cb651ed5390e709557177e"
        hex"183cf36e05d027f248538bed9e77fa839539167a17a5a8cfe5d7d1a2879f15e1"
        hex"2090d0ac6761d2f9271f6e901f1186a37f6da211fe702b31e36600cb44039dd1"
        hex"0fd6d7ed2d8c1aa2ac1ba6884ff4319f803a641eb74c83aa5abbb4d0f0f4deab"
        hex"2ed85bea955e88230ff2904c9cfbf8bc521bdf99670bf18a02714bd1c11d3301"
        hex"2fcbd5335b4092a5f11be5e715d13180ffeefc3050ea601fa2cebd8295f196ef"
        hex"2ebd6b93dbe56c4de58ad9da2c0a592cee8141aefa56940a21b2f912c8cd5a4e"
        hex"1980d60efebd6b1bbd29fc8659c9cfb01922c9ef34750592736e8101b9751052"
        hex"20c49de81eb4cad708a3ad79b7f92867340514823c0f0f18120240cc9d01454b"
        hex"27492fedc18f15785229ba1cccb421d88ae4d0bdebf8c33e6efae25172b18164"
        hex"029e997afb890342ce44e35beb8d1590e4df27bb2288816eed92dd4f977f842d"
        hex"0c91359cf0ab49e3837440149df18411b7b37ab65bca4159d4051751172f3b58"
        hex"000c888cd0c0e660180bb2ae417c1dea4c1759327cd5560828f5e127bde9b827"
        hex"2a5c9982bc9aac60f2fa922ef4d7ec44e14b4e8b96252a78e11da90eacf0db4d"
        hex"1a379a237d336bb0c6543853bd7722a4b91919d582a5b33489e44a091e78bcc3"
        hex"09da3eb98ab6acb7f4d2144212baf93be4b9c75e82d66d078ad4829183f77dd4"
        hex"01a64cff7d8e7dced765d036049de1b4df29fda70445d11d65c40068dd8e1925"
        hex"2b31ec822d93ad27f29e27914ddeadebfc80f90075fe526460326d38293c746f"
        hex"2352d5af52132d288027da9be3ad10dd6f388a12580491c9b09fa02e32be4ca6"
        hex"107d0c7f66f0d95b913d85168f0f2009fb77ff7f8ba0ff2af583adea06a14505"
        hex"1531547a12c43ec4fb06ec6ab64d4a1d5c53a53faf4d98b3a6f4ca1329b684b1"
        hex"2dd90dfd8cb2d7fbbefe63f5ab51356f0ce0a8664de9ff81b0e85ac62308d1e8"
        hex"06812c14457ed4a4851f39b5055284914d35f1a5d5746937f43d60caf29d36fb";

    bytes internal constant TRANSACTION1X2_VK_BLOB =
        hex"213b752e619d8d4c9c02848ab9e7e3818e6cb46c692e2ffa7d3b649db159d947"
        hex"1202ce1ad0bf674f14f0dfa777d424e611780a75e1cc1e531a8dff7b97a1dd05"
        hex"0ab1acfeffba487ad46f505667132a38d622500aefab32a525d3ca2a1994fab8"
        hex"1c7a2fae2731190438fa55b228fa48a0a495f581b4fc819f8fedd46505d852ad"
        hex"0296b9b2f8679356ed283e42bc6d939ff166cc84cd2de4900685cbd8a7e02be2"
        hex"240eba6dbcf2e8090c8c68e1d8d6c231e9dbd26c5de7a55d133df6ebb1ee4bf7"
        hex"198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2"
        hex"1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed"
        hex"090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b"
        hex"12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa"
        hex"3025563302ef8d3fed88ad26e70427c7ec6b2703afb0f66c9c9bd0bb8acb408f"
        hex"209c818ebed8a5eddbba6aef9690b4dacb2e263d41f6308a7d7e5b3ece7cdaad"
        hex"2563cd4386a3ab00d99982fb6c485da09b6481c0b476900ef70d9d4f5720e3c1"
        hex"01f5d10cb11e1adbc424d0a30045efc280256a3da3173f9d133e542e907b8c4f"
        hex"1702ba18d7e1670bb29a9f54e8422684de7eaf92074b9dd24c1bcc5929660415"
        hex"12a8c8e40e61b159f1bc59d9e47b13f5a39f66b7c3067220e36de9499f3181c5"
        hex"237e5aa6a9698fa1fd06ff70e86b7480143760b6a123be56372b64305bf54dec"
        hex"2d29d4690c6f27c95873548c1d39a5ac1eed53170ccc8916b47ed370947440b4"
        hex"10e872bddb693166c3f7ff5aadd5522bd6ae7d3649d557aaeab6536beff9162e"
        hex"0eb3d89577566210ec3bcd5e17211ad9c9d894ff58f512c6bfee948edcb254bc"
        hex"24627b2a8e32bd4ca00398cc5f309dcd66cb24a1c2255723b932a66e3464753d"
        hex"03eb76c8bce935619aafb9402f597814629912b59e131c43f1782a45a0da7436"
        hex"24b4730a50f7b40d3cabfe11a0a51513c74a0574c1501cdad49364bdec7e55bd"
        hex"0839e0b2cb21452807ae9c7d67fe94b81fd9bd288d2bdfb0d60d20ddca41f0ef"
        hex"01d8e89ddc437f6d7176c416f2488fe8c14fdf1fefaab27a4b9d4c5110b4b307"
        hex"0f8ee7c21187eb08f52e1eb93f7ac69d9be009c1af1be1ebdd4da6a524ae0c19"
        hex"1b55bd05d506d0f4bd1b0f441edf67d2e453df959fbede42319b7160f7231a07"
        hex"26059aeb96cfb12d669f98cd6cb420e2d438d2374be05f3a8085ad416c6686fe"
        hex"1ba9cd51f7a577071909202869511207a3bb07f84614133c942f83123a138d2e"
        hex"25f22d2ddf6c0376970d40581fafe97ccf1f6ce996ba5e129f7ff09e6619854f"
        hex"297f093758633233d1419fbf8ab30d7359a931c0c1d5b6597154c6ba8bd49b74"
        hex"151330f4eec2658d98bea25e3f5a0e178cc6ce861fa19e44bdbd06acbd7a82a8"
        hex"23c3bf2d29a6557a19cab3593b76c72bbbc2e82c7b20ca496fa4a9addb74cc35"
        hex"0d0e6615c1706b7cc1f76a3a4a8fdf4fe8a9f55e2d624820e2cfe742098537e6"
        hex"30323f8e315ea10f648a8ac36908ec1a2cd90b9f3bc45ed339aa12a3f176ffc8"
        hex"00a8c346692911138b2c59f09ab638a7dbfcfd2562a01462692e7c135fc6373e";

    bytes internal constant TRANSACTION2X4_VK_BLOB =
        hex"213b752e619d8d4c9c02848ab9e7e3818e6cb46c692e2ffa7d3b649db159d947"
        hex"1202ce1ad0bf674f14f0dfa777d424e611780a75e1cc1e531a8dff7b97a1dd05"
        hex"0ab1acfeffba487ad46f505667132a38d622500aefab32a525d3ca2a1994fab8"
        hex"1c7a2fae2731190438fa55b228fa48a0a495f581b4fc819f8fedd46505d852ad"
        hex"0296b9b2f8679356ed283e42bc6d939ff166cc84cd2de4900685cbd8a7e02be2"
        hex"240eba6dbcf2e8090c8c68e1d8d6c231e9dbd26c5de7a55d133df6ebb1ee4bf7"
        hex"198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2"
        hex"1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed"
        hex"090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b"
        hex"12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa"
        hex"1b1f05a671814055f38e755210b736290613a1fe45b3eaab6d880339540e2376"
        hex"07c6c10f656e95c60e4c9fa50bdb334620545fee33e2c995227446f199604c7b"
        hex"0489649ad4e1cc6ecb0c2ebeac617f6cd5709f17db2d6541f68312b855e8f6fd"
        hex"1bfefc17702e90433b889330cdfab09ba89b4e7428c12135636ec9aafe883130"
        hex"0486f9bebef5511c70a112e316d74c8f72c2910bde0a382d12930beb57789b64"
        hex"0193342229e2b92365bb3a97d28576d48f4ef87c24730da34354e53d3ba043d4"
        hex"30125651ab9ded8bf7db676ca99db53bac7b519bcce37a89cfb536ce838b387f"
        hex"1bdc748bd5a690f879ea14f777c850f38404a990d90bc8ee645a3e3985bde8da"
        hex"194f24dc37fa0a78f823fc22c5e2c7a00ed0f019343bce196055c3f9f280f3f2"
        hex"0f2b39d8647068e13e8f57f9b25dc1fe72574fd843a26b92837419ea170a16d5"
        hex"186b24e6d400e9f900136435846a15ad10721281d7caa0b1367050db9847eced"
        hex"16ccd9f0a11ef5976a83633cbc8bd51cb57e53430cf3c8b244f63700e4ee85e7"
        hex"1facbac655cd10470e3d585fa1b41dc1f4a210741ad7e05f74c278616b9ba94b"
        hex"0a8643d0bab10c121288ac29f9f9d077df577c3577c1a097728999cd802da0b6"
        hex"0862cc106b6b530ecf4bffb2794e55545d40e4679eac6cbf12c2f584c1089db8"
        hex"2fcdfe498cb36e163e95202857dfbbd8cb0dc82814477b1a68514b40f6637b54"
        hex"29691cfaf8880f26de8c41e6fc6a886dc97ab406db8283805c1a1a465b8c604a"
        hex"144fd7f7083b04d4cefd02cd5f7a70668d7f46db2b47eb3444e6dc12972a7129"
        hex"0d73210f495319a04c55bec042c344e96d49d6a179ca376dd055e8f3b997bad6"
        hex"249d3987c926f15269ebba85a35f4724830e3e7ec3400293dbeaba86fe593162"
        hex"19f55c942e51149531fe3b51983f9b314ccd1ab3245223017527263f847a8b53"
        hex"2007aeb1bbbb6d8ac5053cb330944371fc3b7556477e02bdf1f2ae2029cd2593"
        hex"12628ee9df04686a93e1703903aed9a2f6616b119f0c3a2082104d9e6aa0bc77"
        hex"088a043e3ad3f3c73db621d830499439ed8eca37581fc45375f48870d4f559f1"
        hex"11d3dc039d842ec38812e4bc3b5b13b3f4e92280adc18ddfa5e88bc769b8a6ed"
        hex"219c5ac5b8e0db817038c1019ea9a314358bc63066dae4d1ba9c17ce26fa3ebe"
        hex"2ef182d6e710ce2617c833a5213d6e1f488e82f1968877b20523959b476dda3e"
        hex"22fd1385d678df3ecea344e1fe48fa75ac599c8fa5a506313e39bb51e0a406af"
        hex"16f967ea67e9d8b68a7d373fef4e4b23cc7e101897202cbc652445cba9088290"
        hex"0303ab4fd00a216511679cd37893265bdc7b6d306bc8e9a63711ea7933c385ec"
        hex"03206707a3b40657a962f437227f3bb923dbb4071a116c7df71d75a94d5ac6fe"
        hex"2c99a7f05fcce0b5e5997e2a024f70e71f8ebe609abbf3b97ad52cf037e06149";

    bytes internal constant TRANSACTION2X8_VK_BLOB =
        hex"213b752e619d8d4c9c02848ab9e7e3818e6cb46c692e2ffa7d3b649db159d947"
        hex"1202ce1ad0bf674f14f0dfa777d424e611780a75e1cc1e531a8dff7b97a1dd05"
        hex"0ab1acfeffba487ad46f505667132a38d622500aefab32a525d3ca2a1994fab8"
        hex"1c7a2fae2731190438fa55b228fa48a0a495f581b4fc819f8fedd46505d852ad"
        hex"0296b9b2f8679356ed283e42bc6d939ff166cc84cd2de4900685cbd8a7e02be2"
        hex"240eba6dbcf2e8090c8c68e1d8d6c231e9dbd26c5de7a55d133df6ebb1ee4bf7"
        hex"198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2"
        hex"1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed"
        hex"090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b"
        hex"12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa"
        hex"1b9e551c3209615631728015ec31b16068b19427018d5c4438e4d21013e2d853"
        hex"1511fdc0d4e5075b75f384dfcde72a9b2a9cc0527437113d2d439d0fdc7b31f0"
        hex"11a018f98c075a49b388029b8ae5706c7f03c98ae7fc30b6b03bd599a480954f"
        hex"175bfb6508a892c7a4df80f660adc9f06984662f224898d6b3f0d48ccac537b5"
        hex"0eb72a2bba1da928f286d41ff1bb4e6ce76979f98ddab41b6bcf7ba58382286d"
        hex"0e799fe316617772fb3d605151686b2ad1f7beadeee82672260a5d3d17e3007b"
        hex"2eabdbde9cdfd4697bd2d5878571d479245892eda65a9a25e42a75727e222c9c"
        hex"1fc6e0755597930b8f032f8389a25aed30d5b5dda85ef3480b144e0815e6a51b"
        hex"18cccc4acb410fad843bff3aed414734aa089c91a462e9aa017b34e1b00cafa4"
        hex"2d2c39e8fc6b36e0a9a97c401e644a0724de94780d949b04b6643a8603e4dd94"
        hex"1e78d7f49b5af9c15f99cd47284ce6653d677112239de9cb32bf027340ad648a"
        hex"29844bd92b387fc2a824688e797ec7be600f60df379eff5a7538ffa252a35f1e"
        hex"1713347d49a88f7f2751b8113adc67986d4afecb43268c85f860a49ec76ecb5a"
        hex"1149f6a864951f554d9646c2b40e0b821598578713647bd547a966ae131fc757"
        hex"255ade643004308f5a5a0bf172c8f7c041735849e67457466e9b1c242e305797"
        hex"2a949b894f22dbdcec27b04fa75152344df46d711f3d9caa87c733e1c586e7e5"
        hex"1116c043904ce7fe28217eaa1e2c5ba8fedd00cfa4951838a4d90d05c09127d2"
        hex"13916d2b2c81d5a37457a4376c6707a1a1bee2c0f41de28d0c6237fa1ecee5d4"
        hex"2b7c523995681185d62774d918e42dcb18561c1b08ec110160ac5ddd42982234"
        hex"0c050f9cf2146444ab70a8bd31a8e4c61e1c22177a197fffdad8c1201ff1fada"
        hex"2b23bbde140960f70bd9fe16b6e0d818903ebf4e36c2bc62721378fc0cf04cd3"
        hex"2778183ebbb35e5d975b20a6244c63e2dea96f6b503883664afee79743a4d91d"
        hex"19ce66f772a00527fd6fc697ca5a53cb26347b7353c3a2f7006d508087757c1a"
        hex"15d44f3c57b3edaadf22020c42d2035aff1d871af86b9a86aa5de5bef59be7ad"
        hex"1242f2564cced5b433fe84c4d34ed5c26923c8f87a4246027445a106e2bfb464"
        hex"0e20ae8db457056500a61278f3b462c1918f946f802daa6b2ee59c4d071c4d78"
        hex"0e623d0db8ba68629eefe188ecddbce4751c9b9b44d4b724dcbd517b5917aba6"
        hex"1a9cb87f78f15119edc87254402d953b702e5d992ea4e27ac5a5b1a6057f4137"
        hex"159e10d09d051913dcee6c22007a5a8e7b2468711ca5d77d76b99be895e5a7a3"
        hex"1ba5b0d4142e59c8fefd7ce5ddf7b291b15574b29be56220f83fbc77d13d6596"
        hex"051d51326976723ab32dc2fe5e23d0e1c4a4dda77e21994dd6cc38d7c8d33156"
        hex"16ca8f303868febd7a08f3f924489dfc3d0374fdf723631e430e1b48ccde9965"
        hex"19efda5e51ce5bf56f5d0af22c4f76b908b35da3bf01ef7081718986d610008e"
        hex"2f448498f28696cf7697d1152f8cca2b2821c2d7196126603121e0537c1d9b3b"
        hex"16073dd8bd7061e8c6033ada6613191216af12b32c1fe4dcb0fddcb319b47eaa"
        hex"0ce42b684eca3f642cefeb31b923665614214fddd4b17da8d4b74871a150231d"
        hex"28a841fb9cd3c388a6157e266e37ad3a8d7705d95164b6cfec347981dcbfdbb6"
        hex"0c3cc47bbd33e8fce9c7c270c99ec0ea794caf003dda422d6adfbcd1026ed90d"
        hex"1a36f527e1d63281d6b9e799c2d1c3075e70c7928d7bad6fdaa2138ef828cee9"
        hex"2904d7c3898bf9935d9c04ca401e559bc890857ca92f33417797887eb0186a5a";

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
        // 1x3 / 3x3 blobs are intentionally absent at genesis — set via the "vk"
        // governance action once the trusted-setup ceremony emits the verifiers.
        verifierVKs[DEPOSIT_CONFIG_HASH]   = DEPOSIT_VK_BLOB;
        verifierVKs[TX_CONFIG_HASH]        = TRANSACTION_VK_BLOB;
        verifierVKs[TX_1X2_CONFIG_HASH]    = TRANSACTION1X2_VK_BLOB;
        verifierVKs[TX_2X4_CONFIG_HASH]    = TRANSACTION2X4_VK_BLOB;
        verifierVKs[TX_2X8_CONFIG_HASH]    = TRANSACTION2X8_VK_BLOB;

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
            if (tType != TOKEN_TYPE_ERC20 && tType != TOKEN_TYPE_ERC721) revert InvalidTokenType();
            // ERC-721 whitelist is collection-level — sub MUST be zero.
            if (sub != 0) revert UnsupportedTokenSubID();
            uint256 hash = _poseidonT4(uint256(tType), uint256(uint160(tk)), 0);
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

    /// @dev Multi-asset (K=2) keyspace: salted with the tag "v2" for forward
    ///      compatibility — disjoint from any pre-multi-asset legacy layout.
    ///      The deposit circuit uses its own un-salted layout
    ///      (DEPOSIT_CONFIG_HASH constant) and is not produced here.
    function _getCircuitConfigHash(uint256 numIn, uint256 numOut) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode("v2", numIn, numOut)));
    }

    function _isSupportedTxConfig(uint256 cfgHash) internal pure returns (bool) {
        return cfgHash == TX_1X2_CONFIG_HASH
            || cfgHash == TX_CONFIG_HASH
            || cfgHash == TX_1X3_CONFIG_HASH
            || cfgHash == TX_2X4_CONFIG_HASH
            || cfgHash == TX_3X3_CONFIG_HASH
            || cfgHash == TX_2X8_CONFIG_HASH;
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

    /// @dev Multi-asset (K=2) public signal layout:
    ///      [merkleRoot, boundParamsHash, nullifiers..., commitments...,
    ///       publicTokenHashes[0], publicTokenHashes[1],
    ///       publicAmounts[0],     publicAmounts[1],
    ///       actionHash]
    function _buildPubSignals(
        uint256 merkleRoot,
        uint256 boundParamsHash,
        uint256[] calldata _nullifiers,
        uint256[] calldata _commitments,
        uint256[2] memory publicTokenHashes,
        uint256[2] memory publicAmounts,
        uint256 actionHash
    ) internal pure returns (uint256[] memory pubSignals) {
        uint256 nLen = _nullifiers.length;
        uint256 cLen = _commitments.length;
        // 2 (root, bound) + nLen + cLen + 2 (tokenHashes) + 2 (amounts) + 1 (actionHash)
        pubSignals = new uint256[](7 + nLen + cLen);
        pubSignals[0] = merkleRoot;
        pubSignals[1] = boundParamsHash;
        for (uint256 i = 0; i < nLen;) { pubSignals[2 + i] = _nullifiers[i]; unchecked { ++i; } }
        for (uint256 i = 0; i < cLen;) { pubSignals[2 + nLen + i] = _commitments[i]; unchecked { ++i; } }
        pubSignals[2 + nLen + cLen] = publicTokenHashes[0];
        pubSignals[3 + nLen + cLen] = publicTokenHashes[1];
        pubSignals[4 + nLen + cLen] = publicAmounts[0];
        pubSignals[5 + nLen + cLen] = publicAmounts[1];
        pubSignals[6 + nLen + cLen] = actionHash;
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
            uint256 whitelistKey;
            bool isNative = p.tokenAddress == NATIVE_TOKEN;
            bool isNFT    = p.tokenType == TOKEN_TYPE_ERC721;

            if (isNative) {
                tokenHash    = NATIVE_TOKEN_HASH;
                whitelistKey = tokenHash;
            } else {
                tokenHash = _computeTokenHash(p.tokenType, p.tokenAddress, p.tokenSubID);
                // ERC-721 whitelist is collection-level (tokenSubID = 0). The
                // commitment carries the per-tokenId tokenHash so each NFT is
                // uniquely accounted, but membership is checked against the
                // collection key.
                whitelistKey = isNFT
                    ? _computeTokenHash(TOKEN_TYPE_ERC721, p.tokenAddress, 0)
                    : tokenHash;
            }
            if (!whitelistedTokens[whitelistKey]) revert AssetNotWhitelisted(whitelistKey);

            // ERC-721 notes carry exactly one NFT — value MUST be 1.
            if (isNFT && uint256(p.value) != 1) revert InvalidERC721Value();

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
                } else if (isNFT) {
                    // Single NFT, no protocol fee (value = 1).
                    _safeTransferFromERC721(p.tokenAddress, msg.sender, address(this), p.tokenSubID);
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

    /// @dev Multi-asset (K=2) shielded→shielded transfer. No public token movement —
    ///      `publicAmounts` is asserted to be `[0, 0]` here and re-asserted in the
    ///      proof. `publicTokenHashes[k]` must reference whitelisted assets.
    function transact(TransactParams calldata params) external nonReentrant whenNotPaused {
        uint256 numNullifiers  = params.nullifiers.length;
        uint256 numCommitments = params.commitments.length;

        uint256 cfgHash = _getCircuitConfigHash(numNullifiers, numCommitments);
        if (!_isSupportedTxConfig(cfgHash)) revert InvalidCircuitConfig();
        if (params.encryptedNotes.length != numCommitments) revert InvalidEncryptedNotesLength();
        if (params.boundParamsHash >= SNARK_SCALAR_FIELD) revert InputOutOfField(params.boundParamsHash);

        // Validate publicTokenHashes per slot (in-field + whitelisted).
        for (uint256 k = 0; k < 2;) {
            uint256 th = params.publicTokenHashes[k];
            if (th == 0 || th >= SNARK_SCALAR_FIELD) revert InputOutOfField(th);
            if (!whitelistedTokens[th]) revert AssetNotWhitelisted(th);
            unchecked { ++k; }
        }

        _validateMerkleRootInTree(params.treeNumber, params.merkleRoot);
        _validateAndMarkNullifiers(params.nullifiers);
        _validateCommitments(params.commitments);

        // No public movement on transact — both publicAmounts must be zero.
        uint256[2] memory zeroAmounts;

        uint256[] memory pubs = _buildPubSignals(
            params.merkleRoot, params.boundParamsHash, params.nullifiers, params.commitments,
            params.publicTokenHashes, zeroAmounts, params.actionHash
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
        if (params.amounts[0] == 0 && params.amounts[1] == 0) revert InsufficientDeposit();
        if (params.boundParamsHash >= SNARK_SCALAR_FIELD) revert InputOutOfField(params.boundParamsHash);

        uint256 cfgHash = _getCircuitConfigHash(params.nullifiers.length, params.commitments.length);
        if (!_isSupportedTxConfig(cfgHash)) revert InvalidCircuitConfig();
        if (params.encryptedNotes.length != params.commitments.length) revert InvalidEncryptedNotesLength();

        _screenWallet(params.recipient);

        // Per-slot tokenHashes + per-slot value-1 enforcement for ERC-721.
        uint256[2] memory expectedTokenHashes = _resolveUnshieldTokenHashes(params);

        // Bind ALL public unshield data to the proof via boundParamsHash.
        // Layout: keccak256(recipient, broadcaster, tokens, types, subIDs, amounts, fees) % FIELD
        {
            uint256 expectedBoundHash = uint256(keccak256(abi.encode(
                params.recipient,
                params.broadcaster,
                params.tokens,
                params.tokenTypes,
                params.tokenSubIDs,
                params.amounts,
                params.fees
            ))) % SNARK_SCALAR_FIELD;
            if (expectedBoundHash != params.boundParamsHash) revert InvalidBroadcasterFee();
        }

        _validateMerkleRootInTree(params.treeNumber, params.merkleRoot);
        if (unshieldDelay > 0) {
            uint256 rootTs = _rootTimestamps[params.treeNumber][params.merkleRoot];
            if (block.timestamp - rootTs < unshieldDelay) {
                revert UnshieldDelayNotMet(rootTs, unshieldDelay);
            }
        }

        _validateAndMarkNullifiers(params.nullifiers);
        _validateCommitments(params.commitments);

        // Per-slot fees + proof verify.
        uint256[2] memory protoFees = _computeUnshieldProtocolFees(params);
        {
            uint256[] memory pubs = _buildPubSignals(
                params.merkleRoot, params.boundParamsHash, params.nullifiers, params.commitments,
                expectedTokenHashes, params.amounts, params.actionHash
            );
            if (!_verifyProof(cfgHash, params.proof, pubs)) revert InvalidProof();
        }

        if (params.commitments.length > 0) {
            _insertLeaves(_toMemoryArray(params.commitments));
        }

        // Effects done; payouts last.
        _payoutUnshield(params, protoFees);
    }

    /// @dev Resolve per-slot tokenHash with ERC-721 collection-level whitelist semantics.
    function _resolveUnshieldTokenHashes(UnshieldParams calldata params)
        internal
        view
        returns (uint256[2] memory tokenHashes)
    {
        for (uint256 k = 0; k < 2;) {
            if (params.amounts[k] == 0) { unchecked { ++k; } continue; }

            address tk = params.tokens[k];
            uint8 tt = params.tokenTypes[k];

            if (tk == NATIVE_TOKEN || tt == TOKEN_TYPE_NATIVE) {
                tokenHashes[k] = NATIVE_TOKEN_HASH;
                if (!whitelistedTokens[tokenHashes[k]]) revert AssetNotWhitelisted(tokenHashes[k]);
            } else if (tt == TOKEN_TYPE_ERC721) {
                if (params.amounts[k] != 1) revert InvalidERC721Value();
                if (params.fees[k] != 0) revert InvalidBroadcasterFee();
                tokenHashes[k] = _computeTokenHash(tt, tk, params.tokenSubIDs[k]);
                // Collection-level whitelist key (tokenSubID = 0).
                uint256 collectionKey = _computeTokenHash(tt, tk, 0);
                if (!whitelistedTokens[collectionKey]) revert AssetNotWhitelisted(collectionKey);
            } else if (tt == TOKEN_TYPE_ERC20) {
                tokenHashes[k] = _computeTokenHash(tt, tk, 0);
                if (!whitelistedTokens[tokenHashes[k]]) revert AssetNotWhitelisted(tokenHashes[k]);
            } else {
                revert InvalidTokenType();
            }
            unchecked { ++k; }
        }
    }

    /// @dev Per-slot protocol fee (skipped for ERC-721; rounded for ERC-20 / native).
    function _computeUnshieldProtocolFees(UnshieldParams calldata params)
        internal
        view
        returns (uint256[2] memory protoFees)
    {
        for (uint256 k = 0; k < 2;) {
            if (params.amounts[k] == 0) { unchecked { ++k; } continue; }
            if (params.tokenTypes[k] == TOKEN_TYPE_ERC721) {
                protoFees[k] = 0;
            } else {
                protoFees[k] = params.amounts[k] * protocolFeeBps / 10_000;
            }
            if (params.fees[k] + protoFees[k] > params.amounts[k]) revert InvalidBroadcasterFee();
            unchecked { ++k; }
        }
    }

    /// @dev Pay out per-slot amounts to recipient / treasury / broadcaster.
    function _payoutUnshield(UnshieldParams calldata params, uint256[2] memory protoFees) internal {
        for (uint256 k = 0; k < 2;) {
            if (params.amounts[k] == 0) { unchecked { ++k; } continue; }

            address tk = params.tokens[k];
            uint8 tt = params.tokenTypes[k];
            uint256 broadcasterFee = params.fees[k];
            uint256 protoFee = protoFees[k];
            uint256 recipientAmount = params.amounts[k] - protoFee - broadcasterFee;

            if (tt == TOKEN_TYPE_ERC721) {
                _safeTransferERC721(tk, params.recipient, params.tokenSubIDs[k]);
            } else if (tk == NATIVE_TOKEN || tt == TOKEN_TYPE_NATIVE) {
                _safeTransferETH(params.recipient, recipientAmount);
                if (protoFee > 0) {
                    if (treasury == address(0)) revert TreasuryNotSet();
                    _safeTransferETH(treasury, protoFee);
                }
                if (broadcasterFee > 0 && params.broadcaster != address(0)) {
                    _safeTransferETH(params.broadcaster, broadcasterFee);
                }
            } else {
                _safeTransfer(tk, params.recipient, recipientAmount);
                if (protoFee > 0) {
                    if (treasury == address(0)) revert TreasuryNotSet();
                    _safeTransfer(tk, treasury, protoFee);
                }
                if (broadcasterFee > 0 && params.broadcaster != address(0)) {
                    _safeTransfer(tk, params.broadcaster, broadcasterFee);
                }
            }

            emit Unshield(params.recipient, tk, params.amounts[k], broadcasterFee, protoFee, params.broadcaster);
            unchecked { ++k; }
        }
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
    function getTx1x3ConfigHash() external pure returns (uint256)   { return TX_1X3_CONFIG_HASH; }
    function getTx2x4ConfigHash() external pure returns (uint256)   { return TX_2X4_CONFIG_HASH; }
    function getTx3x3ConfigHash() external pure returns (uint256)   { return TX_3X3_CONFIG_HASH; }
    function getTx2x8ConfigHash() external pure returns (uint256)   { return TX_2X8_CONFIG_HASH; }
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

    /// @dev IERC721.safeTransferFrom(from, to, tokenId) — selector 0x42842e0e.
    ///      Used during shield (pull NFT into pool).
    function _safeTransferFromERC721(address token, address from, address to, uint256 tokenId) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x42842e0e, from, to, tokenId)
        );
        if (!success) {
            if (data.length > 0) {
                assembly { revert(add(data, 32), mload(data)) }
            }
            revert ERC721TransferFailed();
        }
    }

    /// @dev IERC721.safeTransferFrom(this, to, tokenId) — used during unshield.
    function _safeTransferERC721(address token, address to, uint256 tokenId) internal {
        _safeTransferFromERC721(token, address(this), to, tokenId);
    }

    /// @notice IERC721Receiver hook. Required so the pool can receive NFTs via
    ///         safeTransferFrom (used in shield).
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return ERC721_RECEIVED;
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
            if (tType != TOKEN_TYPE_ERC20 && tType != TOKEN_TYPE_ERC721) revert InvalidTokenType();
            if (tk == address(0)) revert ZeroAddressErr();
            // ERC-721 whitelist is collection-level — sub MUST be zero.
            if (sub != 0) revert UnsupportedTokenSubID();
            uint256 hash = _computeTokenHash(tType, tk, 0);
            whitelistedTokens[hash] = true;
            emit AssetWhitelisted(hash, tk);

        } else if (Memory.compareStrings(key, "removeWhitelistedToken")) {
            (uint8 tType, address tk, uint256 sub) = abi.decode(value, (uint8, address, uint256));
            if (tType != TOKEN_TYPE_ERC20 && tType != TOKEN_TYPE_ERC721) revert InvalidTokenType();
            if (sub != 0) revert UnsupportedTokenSubID();
            uint256 hash = _computeTokenHash(tType, tk, 0);
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
