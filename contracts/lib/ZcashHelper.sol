// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./TypedMemView.sol";
import "./SafeCast.sol";

library ZcashHelper {

    using SafeCast for uint96;
    using SafeCast for uint256;

    using TypedMemView for bytes;
    using TypedMemView for bytes29;

    // Zcash transparent address types only; SegWit (P2WPKH, P2WSH) and Taproot (P2TR) are not supported.
    enum ScriptType {
        P2PK,  // 32 bytes
        P2PKH, // 20 bytes
        P2SH   // 20 bytes
    }

    enum MemViewType {
        Unknown,            // 0x0
        CompactInt,         // 0x1 - reserved; length encoding tag not yet needed as a standalone type
        ScriptSig,          // 0x2 - with length prefix
        Outpoint,           // 0x3
        TxIn,               // 0x4
        IntermediateTxIns,  // 0x5 - used in vin parsing
        Vin,                // 0x6
        ScriptPubkey,       // 0x7 - with length prefix
        PK,                 // 0x8 - reserved; P2PK 32-byte digest (mirrors ScriptType.P2PK)
        PKH,                // 0x9 - reserved; P2PKH 20-byte digest (mirrors ScriptType.P2PKH)
        SH,                 // 0xa - reserved; P2SH 20-byte digest (mirrors ScriptType.P2SH)
        OpReturnPayload,    // 0xb
        TxOut,              // 0xc
        IntermediateTxOuts, // 0xd - used in vout parsing
        Vout                // 0xe
    }

    /// @notice             parses a Zcash v5 transparent transaction and returns its fields
    /// Bundling into a struct keeps caller stack depth low when fields are forwarded together.
    struct ZcashTx {
        // ─── 1. Header Area ──────────────────────────────────────
        uint32  version;           // fOverwintered bit stripped
        uint32  versionGroupId;    // 0x26A7270A for v5 (NU5)
        uint32  consensusBranchId;
        uint32  lockTime;          // Block height or timestamp
        uint32  expiryHeight;      // Block height expiration

        // ─── 2. Transparent Bundle Area (Variable length) ────────
        bytes29 vinView;           // MemViewType.Vin (inputs)
        bytes29 voutView;          // MemViewType.Vout (outputs)
    }

    // BLAKE2b-256 precompile deployed at 0x67 on Z Protocol chain.
    address private constant BLAKE2B_PRECOMPILE = address(0x67);

    /// @notice             requires `_memView` to be of a specified type
    /// @dev                passes if it is the correct type, errors if not
    /// @param _memView     a 29-byte view with a 5-byte type
    /// @param _t           the expected type (e.g. MemViewType.Outpoint, MemViewType.TxIn, etc)
    modifier typeAssert(bytes29 _memView, MemViewType _t) {
        _memView.assertType(uint40(_t));
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            UTILITIES
    //////////////////////////////////////////////////////////////*/

    /// @notice             reads a compact int from the view at the specified index
    /// @param _memView     a 29-byte view with a 5-byte type
    /// @param _index       the index
    /// @return number      the compact int at the specified index
    function indexCompactInt(bytes29 _memView, uint256 _index) internal pure returns (uint64 number) {
        uint256 flag = _memView.indexUint(_index, 1);
        if (flag <= 0xfc) {
            return flag.toUint64();
        } else if (flag == 0xfd) {
            number = _memView.indexLEUint(_index + 1, 2).toUint64();
            if (_compactIntLength(number) != 3) {_revertNonMinimal(_memView.slice(_index, 3, 0));}
        } else if (flag == 0xfe) {
            number = _memView.indexLEUint(_index + 1, 4).toUint64();
            if (_compactIntLength(number) != 5) {_revertNonMinimal(_memView.slice(_index, 5, 0));}
        } else if (flag == 0xff) {
            number = _memView.indexLEUint(_index + 1, 8).toUint64();
            if (_compactIntLength(number) != 9) {_revertNonMinimal(_memView.slice(_index, 9, 0));}
        }
    }

    /// @notice             extracts the LE txid from an outpoint
    /// @param _outpoint    the outpoint
    /// @return             the LE txid
    function txidLE(bytes29 _outpoint) internal pure typeAssert(_outpoint, MemViewType.Outpoint) returns (bytes32) {
        return _outpoint.index(0, 32);
    }

    /// @notice Calls the BLAKE2b-256 precompile (0x67).
    /// @dev Input layout: first 16 bytes = personalisation string, remainder = message body.
    ///      Output is always 32 bytes, so scratch space (0x00) is safe to use as the output buffer.
    /// @param _input Raw bytes to hash (personalisation prefix + message)
    /// @return result BLAKE2b-256 digest
    function blake2b256(bytes memory _input) internal view returns (bytes32 result) {
        address precompile = BLAKE2B_PRECOMPILE;
        uint256 inputLen = _input.length;
        assembly {
            let ptr := add(_input, 0x20)
            if iszero(staticcall(gas(), precompile, ptr, inputLen, 0x00, 0x20)) {
                revert(0, 0)
            }
            result := mload(0x00)
        }
    }

    // Revert with an error message re: non-minimal VarInts
    function _revertNonMinimal(bytes29 _ref) private pure returns (string memory) {
        (, uint256 g) = TypedMemView.encodeHex(_ref.indexUint(0, _ref.len().toUint8()));
        string memory err = string(
            abi.encodePacked(
                "Non-minimal var int. Got 0x",
                uint144(g)
            )
        );
        revert(err);
    }

    /// @notice          gives the total length (in bytes) of a CompactInt-encoded number
    /// @param _number   the number as uint64
    /// @return          the compact integer length as uint8
    function _compactIntLength(uint64 _number) private pure returns (uint8) {
        if (_number <= 0xfc) {
            return 1;
        } else if (_number <= 0xffff) {
            return 3;
        } else if (_number <= 0xffffffff) {
            return 5;
        } else {
            return 9;
        }
    }

    /// @notice  Serialises a uint32 as 4 little-endian bytes (matching Zcash wire format).
    function _leBytes4(uint32 _v) private pure returns (bytes4) {
        return bytes4(
            (uint32(uint8(_v))         << 24) |
            (uint32(uint8(_v >>  8))   << 16) |
            (uint32(uint8(_v >> 16))   <<  8) |
             uint32(uint8(_v >> 24))
        );
    }

    /*//////////////////////////////////////////////////////////////
                           VIN PARSING
    //////////////////////////////////////////////////////////////*/

    /// @notice                           Parses outpoint info from an input
    /// @dev                              Reverts if vin is null
    /// @param _vin                       The vin of a Zcash transaction
    /// @param _index                     Index of the input that we are looking at
    /// @return txId                      Output tx id
    /// @return outputIndex               Output tx index
    function extractOutpoint(
        bytes memory _vin,
        uint256 _index
    ) internal pure returns (bytes32, uint32) {
        bytes29 vin = tryAsVin(_vin.ref(uint40(MemViewType.Unknown)));
        require(!vin.isNull(), "ZcashHelper: vin is null");
        return extractOutpoint(vin, _index);
    }

    /// @notice                           Parses outpoint info from an input
    /// @dev                              Reverts if vin is null
    /// @param _vinView                   The vin of a Zcash transaction
    /// @param _index                     Index of the input that we are looking at
    /// @return txId                      Output tx id
    /// @return outputIndex               Output tx index
    function extractOutpoint(
        bytes29 _vinView,
        uint256 _index
    ) internal pure typeAssert(_vinView, MemViewType.Vin) returns (bytes32 txId, uint32 outputIndex) {
        bytes29 input = indexVin(_vinView, _index);
        bytes29 outpointView = outpoint(input);
        txId = txidLE(outpointView);
        outputIndex = outpointIdx(outpointView);
    }

    /// @notice              Extracts all outpoints from a vin.
    /// @param _vinView      The vin of a Zcash transaction
    /// @return outpointHashes  Outpoint txid for each input
    /// @return opIndices       Outpoint index for each input
    function extractOutpoints(
        bytes29 _vinView
    ) internal pure typeAssert(_vinView, MemViewType.Vin) returns (bytes32[] memory outpointHashes, uint32[] memory opIndices) {
        uint256 numberOfInputs = uint256(indexCompactInt(_vinView, 0));
        outpointHashes = new bytes32[](numberOfInputs);
        opIndices = new uint32[](numberOfInputs);
        for (uint256 i = 0; i < numberOfInputs; ++i) {
            (outpointHashes[i], opIndices[i]) = extractOutpoint(_vinView, i);
        }
    }

    /// @notice             extracts the index as an integer from the outpoint
    /// @param _outpoint    the outpoint
    /// @return             the index
    function outpointIdx(bytes29 _outpoint) internal pure typeAssert(_outpoint, MemViewType.Outpoint) returns (uint32) {
        return _outpoint.indexLEUint(32, 4).toUint32();
    }

    /// @notice          extracts the outpoint from an input
    /// @param _input    the input
    /// @return          the outpoint as a typed memory
    function outpoint(bytes29 _input) internal pure typeAssert(_input, MemViewType.TxIn) returns (bytes29) {
        return _input.slice(0, 36, uint40(MemViewType.Outpoint));
    }

    /// @notice           extracts the script sig from an input
    /// @param _input     the input
    /// @return           the script sig as a typed memory
    function scriptSig(bytes29 _input) internal pure typeAssert(_input, MemViewType.TxIn) returns (bytes29) {
        uint64 scriptLength = indexCompactInt(_input, 36);
        return _input.slice(36, _compactIntLength(scriptLength) + scriptLength, uint40(MemViewType.ScriptSig));
    }

    /// @notice         determines the length of the first input in an array of inputs
    /// @param _inputs  the vin without its length prefix
    /// @return         the input length
    function _inputLength(bytes29 _inputs) private pure typeAssert(_inputs, MemViewType.IntermediateTxIns) returns (uint256) {
        uint64 scriptLength = indexCompactInt(_inputs, 36);
        return uint256(_compactIntLength(scriptLength)) + uint256(scriptLength) + 36 + 4;
    }

    /// @notice         extracts the input at a specified index
    /// @param _vin     the vin
    /// @param _index   the index of the desired input
    /// @return         the desired input
    function indexVin(bytes29 _vin, uint256 _index) internal pure typeAssert(_vin, MemViewType.Vin) returns (bytes29) {
        uint256 nIns = uint256(indexCompactInt(_vin, 0));
        uint256 viewLen = _vin.len();
        require(_index < nIns, "ZcashHelper: vin read overrun");

        uint256 offset = uint256(_compactIntLength(uint64(nIns)));
        bytes29 remaining;
        for (uint256 i = 0; i < _index; ++i) {
            remaining = _vin.postfix(viewLen - offset, uint40(MemViewType.IntermediateTxIns));
            offset += _inputLength(remaining);
        }

        remaining = _vin.postfix(viewLen - offset, uint40(MemViewType.IntermediateTxIns));
        uint256 len = _inputLength(remaining);
        return _vin.slice(offset, len, uint40(MemViewType.TxIn));
    }

    /*//////////////////////////////////////////////////////////////
                          VOUT PARSING
    //////////////////////////////////////////////////////////////*/

    /// @notice         extracts the value from an output
    /// @param _output  the output
    /// @return         the value
    function value(bytes29 _output) internal pure typeAssert(_output, MemViewType.TxOut) returns (uint64) {
        return _output.indexLEUint(0, 8).toUint64();
    }

    /// @notice                   Finds the value of a specific output
    /// @dev                      Reverts if vout is null
    /// @param _vout              The vout of a Zcash transaction
    /// @param _index             Index of output
    /// @return outputValue       Value of the specified output
    function parseOutputValue(bytes memory _vout, uint256 _index) internal pure returns (uint64) {
        bytes29 voutView = tryAsVout(_vout.ref(uint40(MemViewType.Unknown)));
        require(!voutView.isNull(), "ZcashHelper: vout is null");
        return parseOutputValue(voutView, _index);
    }

    /// @notice              Finds the value of a specific output
    /// @dev                 Reverts if vout is null
    /// @param _voutView     The vout of a Zcash transaction
    /// @param _index        Index of output
    /// @return outputValue  Value of the specified output
    function parseOutputValue(bytes29 _voutView, uint256 _index) internal pure typeAssert(_voutView, MemViewType.Vout) returns (uint64 outputValue) {
        bytes29 output = indexVout(_voutView, _index);
        outputValue = value(output);
    }

    /// @notice                Finds the value of a specific output
    /// @dev                   Reverts if vout is null
    /// @param _voutView       The vout of a Zcash transaction
    /// @param _index          Index of output
    /// @return outputValue    Value of the specified output
    /// @return pkScriptView   Parsed pk script view
    function parseOutputValueAndScript(bytes29 _voutView, uint256 _index) internal pure typeAssert(_voutView, MemViewType.Vout) returns (uint64 outputValue, bytes29 pkScriptView) {
        bytes29 output = indexVout(_voutView, _index);
        outputValue = value(output);
        pkScriptView = scriptPubkey(output);
    }

    /// @notice                   Finds total outputs value
    /// @dev                      Reverts if vout is null
    /// @param _vout              The vout of a Zcash transaction
    /// @return totalValue        Total vout value
    function parseOutputsTotalValue(bytes memory _vout) internal pure returns (uint64) {
        bytes29 voutView = tryAsVout(_vout.ref(uint40(MemViewType.Unknown)));
        require(!voutView.isNull(), "ZcashHelper: vout is null");
        return parseOutputsTotalValue(voutView);
    }

    /// @notice                   Finds total outputs value
    /// @dev                      Reverts if vout is null
    /// @param _voutView          The vout of a Zcash transaction
    /// @return totalValue        Total vout value
    function parseOutputsTotalValue(bytes29 _voutView) internal pure typeAssert(_voutView, MemViewType.Vout) returns (uint64 totalValue) {
        bytes29 output;
        uint256 nOuts = uint256(indexCompactInt(_voutView, 0));
        for (uint256 i = 0; i < nOuts; ++i) {
            output = indexVout(_voutView, i);
            totalValue += value(output);
        }
    }

    /// @notice                           Parses the ZEC amount that has been sent to
    ///                                   a specific script in a specific output
    /// @param _vout                      The vout of a Zcash transaction
    /// @param _voutIndex                 Index of the output that we are looking at
    /// @param _script                    Desired recipient script
    /// @param _scriptType                Type of the script (e.g. P2PK)
    /// @return amount                    Amount of ZEC sent to _script
    function parseValueFromSpecificOutputHavingScript(
        bytes memory _vout,
        uint256 _voutIndex,
        bytes memory _script,
        ScriptType _scriptType
    ) internal pure returns (uint64) {
        bytes29 voutView = tryAsVout(_vout.ref(uint40(MemViewType.Unknown)));
        require(!voutView.isNull(), "ZcashHelper: vout is null");
        return parseValueFromSpecificOutputHavingScript(voutView, _voutIndex, _script, _scriptType);
    }

    /// @notice                           Parses the ZEC amount that has been sent to
    ///                                   a specific script in a specific output
    /// @param _voutView                  The vout of a Zcash transaction
    /// @param _voutIndex                 Index of the output that we are looking at
    /// @param _script                    Desired recipient script
    /// @param _scriptType                Type of the script (e.g. P2PK)
    /// @return amount                    Amount of ZEC sent to _script
    function parseValueFromSpecificOutputHavingScript(
        bytes29 _voutView,
        uint256 _voutIndex,
        bytes memory _script,
        ScriptType _scriptType
    ) internal pure typeAssert(_voutView, MemViewType.Vout) returns (uint64 amount) {
        bytes29 output = indexVout(_voutView, _voutIndex);
        bytes29 scriptPubkeyView = scriptPubkey(output);

        if (_scriptType == ScriptType.P2PK) {
            // note: first byte is Pushdata Bytelength; public key length is 32.
            amount = keccak256(_script) == keccak256(abi.encodePacked(scriptPubkeyView.index(1, 32))) ? value(output) : 0;
        } else if (_scriptType == ScriptType.P2PKH) {
            // note: first three bytes are OP_DUP, OP_HASH160, Pushdata Bytelength; pkh length is 20.
            amount = keccak256(_script) == keccak256(abi.encodePacked(scriptPubkeyView.indexAddress(3))) ? value(output) : 0;
        } else if (_scriptType == ScriptType.P2SH) {
            // note: first two bytes are OP_HASH160, Pushdata Bytelength; script hash length is 20.
            amount = keccak256(_script) == keccak256(abi.encodePacked(scriptPubkeyView.indexAddress(2))) ? value(output) : 0;
        }
    }

    /// @notice                           Parses the ZEC amount of a transaction
    /// @dev                              Finds the ZEC amount that has been sent to the locking script
    ///                                   Returns zero if no matching locking script is found
    /// @param _vout                      The vout of a Zcash transaction
    /// @param _lockingScript             Desired locking script
    /// @return amount                    Amount of ZEC sent to _lockingScript
    function parseValueHavingLockingScript(
        bytes memory _vout,
        bytes memory _lockingScript
    ) internal view returns (uint64) {
        bytes29 voutView = tryAsVout(_vout.ref(uint40(MemViewType.Unknown)));
        require(!voutView.isNull(), "ZcashHelper: vout is null");
        return parseValueHavingLockingScript(voutView, _lockingScript);
    }

    /// @notice                           Parses the ZEC amount of a transaction
    /// @dev                              Finds the ZEC amount that has been sent to the locking script
    ///                                   Returns zero if no matching locking script is found
    /// @param _voutView                  The vout of a Zcash transaction
    /// @param _lockingScript             Desired locking script
    /// @return amount                    Amount of ZEC sent to _lockingScript
    function parseValueHavingLockingScript(
        bytes29 _voutView,
        bytes memory _lockingScript
    ) internal view returns (uint64 amount) {
        bytes29 output;
        bytes29 scriptPubkeyView;

        uint256 nOuts = uint256(indexCompactInt(_voutView, 0));

        for (uint256 i = 0; i < nOuts; ++i) {
            output = indexVout(_voutView, i);
            scriptPubkeyView = scriptPubkey(output);

            if (
                keccak256(abi.encodePacked(scriptPubkeyView.clone())) == keccak256(abi.encodePacked(_lockingScript))
            ) {
                amount = value(output);
                break;
            }
        }
    }

    /// @notice                           Parses the ZEC amount and the op_return of a transaction
    /// @dev                              Finds the ZEC amount that has been sent to the locking script
    ///                                   Assumes that payload size is less than 80 bytes
    /// @param _vout                      The vout of a Zcash transaction
    /// @param _lockingScript             Desired locking script
    /// @return amount                    Amount of ZEC sent to _lockingScript
    /// @return arbitraryData             Opreturn data of the transaction
    function parseValueAndDataHavingLockingScript(
        bytes memory _vout,
        bytes memory _lockingScript
    ) internal view returns (uint64, bytes memory) {
        bytes29 voutView = tryAsVout(_vout.ref(uint40(MemViewType.Unknown)));
        require(!voutView.isNull(), "ZcashHelper: vout is null");
        return parseValueAndDataHavingLockingScript(voutView, _lockingScript);
    }

    /// @notice                           Parses the ZEC amount and the op_return of a transaction
    /// @dev                              Finds the ZEC amount that has been sent to the locking script
    ///                                   Assumes that payload size is less than 80 bytes
    /// @param _voutView                  The vout of a Zcash transaction
    /// @param _lockingScript             Desired locking script
    /// @return amount                    Amount of ZEC sent to _lockingScript
    /// @return arbitraryData             Opreturn data of the transaction
    function parseValueAndDataHavingLockingScript(
        bytes29 _voutView,
        bytes memory _lockingScript
    ) internal view typeAssert(_voutView, MemViewType.Vout) returns (uint64 amount, bytes memory arbitraryData) {
        bytes29 output;
        bytes29 scriptPubkeyView;
        bytes29 scriptPubkeyWithLengthView;
        bytes29 arbitraryDataView;

        uint256 nOuts = uint256(indexCompactInt(_voutView, 0));

        for (uint256 i = 0; i < nOuts; ++i) {
            output = indexVout(_voutView, i);
            scriptPubkeyView = scriptPubkey(output);
            scriptPubkeyWithLengthView = scriptPubkeyWithLength(output);
            arbitraryDataView = opReturnPayload(scriptPubkeyWithLengthView);

            if (arbitraryDataView == TypedMemView.NULL) {
                if (
                    keccak256(abi.encodePacked(scriptPubkeyView.clone())) == keccak256(abi.encodePacked(_lockingScript))
                ) {
                    amount = value(output);
                }
            } else {
                arbitraryData = arbitraryDataView.clone();
            }
        }
    }

    /// @notice                           Parses the ZEC amount and OP_RETURN data from a vout
    /// @dev                              Matches output by P2SH or script hash; assumes OP_RETURN payload is less than 80 bytes
    /// @param _voutView                  The vout of a Zcash transaction
    /// @param _script                    Desired locking script
    /// @return amount                    Amount of ZEC sent to the matching output
    /// @return arbitraryData             OP_RETURN payload of the transaction
    function parseToScriptValueAndData(
        bytes29 _voutView,
        bytes memory _script
    ) internal pure typeAssert(_voutView, MemViewType.Vout) returns (uint64 amount, bytes29 arbitraryData, uint32 outputIndex) {
        bytes29 outputView;
        bytes29 scriptPubkeyView;
        bytes29 scriptPubkeyWithLengthView;
        bytes29 arbitraryDataView;

        uint256 nOuts = uint256(indexCompactInt(_voutView, 0));

        for (uint256 i = 0; i < nOuts; ++i) {
            outputView = indexVout(_voutView, i);
            scriptPubkeyView = scriptPubkey(outputView);
            scriptPubkeyWithLengthView = scriptPubkeyWithLength(outputView);
            arbitraryDataView = opReturnPayload(scriptPubkeyWithLengthView);

            if (arbitraryDataView == TypedMemView.NULL) {
                if (
                    (scriptPubkeyView.len() == 23 &&
                    scriptPubkeyView.indexUint(0, 1) == 0xa9 &&
                    scriptPubkeyView.indexUint(1, 1) == 0x14 &&
                    scriptPubkeyView.indexUint(22, 1) == 0x87 &&
                    bytes20(scriptPubkeyView.indexAddress(2)) == ripemd160(abi.encode(sha256(_script)))) ||
                    (scriptPubkeyView.len() == 34 &&
                    scriptPubkeyView.indexUint(0, 1) == 0 &&
                    scriptPubkeyView.indexUint(1, 1) == 32 &&
                    scriptPubkeyView.index(2, 32) == sha256(_script))
                ) {
                    amount = value(outputView);
                    outputIndex = uint32(i);
                }
            } else {
                arbitraryData = arbitraryDataView;
            }
        }
    }

    /// @notice             extracts the scriptPubkey from an output
    /// @param _output      the output
    /// @return             the scriptPubkey
    function scriptPubkey(bytes29 _output) internal pure typeAssert(_output, MemViewType.TxOut) returns (bytes29) {
        uint64 scriptLength = indexCompactInt(_output, 8);
        return _output.slice(8 + _compactIntLength(scriptLength), scriptLength, uint40(MemViewType.ScriptPubkey));
    }

    /// @notice             extracts the scriptPubkey from an output, including its CompactInt length prefix
    /// @param _output      the output
    /// @return             the scriptPubkey with length prefix
    function scriptPubkeyWithLength(bytes29 _output) internal pure typeAssert(_output, MemViewType.TxOut) returns (bytes29) {
        uint64 scriptLength = indexCompactInt(_output, 8);
        return _output.slice(8, _compactIntLength(scriptLength) + scriptLength, uint40(MemViewType.ScriptPubkey));
    }

    /// @notice                           Parses locking script from an output
    /// @dev                              Reverts if vout is null
    /// @param _vout                      The vout of a Zcash transaction
    /// @param _index                     Index of the output that we are looking at
    /// @return lockingScript             Parsed locking script
    function getLockingScript(
        bytes memory _vout,
        uint256 _index
    ) internal view returns (bytes memory) {
        bytes29 vout = tryAsVout(_vout.ref(uint40(MemViewType.Unknown)));
        require(!vout.isNull(), "ZcashHelper: vout is null");
        return getLockingScript(vout, _index);
    }

    /// @notice                           Parses locking script from an output
    /// @dev                              Reverts if vout is null
    /// @param _voutView                  The vout of a Zcash transaction
    /// @param _index                     Index of the output that we are looking at
    /// @return lockingScript             Parsed locking script
    function getLockingScript(
        bytes29 _voutView,
        uint256 _index
    ) internal view returns (bytes memory lockingScript) {
        bytes29 output = indexVout(_voutView, _index);
        bytes29 lockingScriptView = scriptPubkey(output);
        lockingScript = lockingScriptView.clone();
    }

    /// @notice                   Returns number of outputs in a vout
    /// @param _vout              The vout of a Zcash transaction
    /// @return                   Number of outputs
    function numberOfOutputs(bytes memory _vout) internal pure returns (uint256) {
        bytes29 voutView = tryAsVout(_vout.ref(uint40(MemViewType.Unknown)));
        require(!voutView.isNull(), "ZcashHelper: vout is null");
        return numberOfOutputs(voutView);
    }

    /// @notice                   Returns number of outputs in a vout
    /// @param _voutView          The vout of a Zcash transaction
    /// @return count             Number of outputs
    function numberOfOutputs(bytes29 _voutView) internal pure typeAssert(_voutView, MemViewType.Vout) returns (uint256 count) {
        count = uint256(indexCompactInt(_voutView, 0));
    }

    /// @notice             determines the length of the first output in an array of outputs
    /// @param _outputs     the vout without its length prefix
    /// @return             the output length
    function _outputLength(bytes29 _outputs) private pure typeAssert(_outputs, MemViewType.IntermediateTxOuts) returns (uint256) {
        uint64 scriptLength = indexCompactInt(_outputs, 8);
        return uint256(_compactIntLength(scriptLength)) + uint256(scriptLength) + 8;
    }

    /// @notice         extracts the output at a specified index
    /// @param _vout    the vout
    /// @param _index   the index of the desired output
    /// @return         the desired output
    function indexVout(bytes29 _vout, uint256 _index) internal pure typeAssert(_vout, MemViewType.Vout) returns (bytes29) {
        uint256 nOuts = uint256(indexCompactInt(_vout, 0));
        uint256 viewLen = _vout.len();
        require(_index < nOuts, "ZcashHelper: vout read overrun");

        uint256 offset = uint256(_compactIntLength(uint64(nOuts)));
        bytes29 remaining;
        for (uint256 i = 0; i < _index; ++i) {
            remaining = _vout.postfix(viewLen - offset, uint40(MemViewType.IntermediateTxOuts));
            offset += _outputLength(remaining);
        }

        remaining = _vout.postfix(viewLen - offset, uint40(MemViewType.IntermediateTxOuts));
        uint256 len = _outputLength(remaining);
        return _vout.slice(offset, len, uint40(MemViewType.TxOut));
    }

    /// @notice             extracts the Op Return Payload
    /// @dev                structure of the input is: 1 byte op return + 2 bytes indicating the length of payload + max length for op return payload is 80 bytes
    /// @param _skp         the scriptPubkey
    /// @return             the Op Return Payload (or null if not a valid Op Return output)
    function opReturnPayload(bytes29 _skp) internal pure typeAssert(_skp, MemViewType.ScriptPubkey) returns (bytes29) {
        uint64 bodyLength = indexCompactInt(_skp, 0);
        if (_skp.indexUint(1, 1) == 0x6a) {
            if (_skp.indexUint(2, 1) == 0x4c) {
                uint64 payloadLen = _skp.indexUint(3, 1).toUint64();
                require(payloadLen == bodyLength - 3 &&
                    bodyLength <= 83 && bodyLength >= 79, "ZcashHelper: invalid opreturn");
                return _skp.slice(4, payloadLen, uint40(MemViewType.OpReturnPayload));
            } else {
                uint64 payloadLen = _skp.indexUint(2, 1).toUint64();
                require(payloadLen == bodyLength - 2 &&
                    bodyLength <= 77 && bodyLength >= 4, "ZcashHelper: invalid opreturn");
                return _skp.slice(3, payloadLen, uint40(MemViewType.OpReturnPayload));
            }
        }
        return TypedMemView.nullView();
    }

    /*//////////////////////////////////////////////////////////////
                       TRANSACTION PARSING
    //////////////////////////////////////////////////////////////*/

    /// @notice     verifies the vin and converts to a typed memory
    /// @dev        will return null in error cases
    /// @param _vin the vin
    /// @return     the typed vin (or null if error)
    function tryAsVin(bytes29 _vin) internal pure typeAssert(_vin, MemViewType.Unknown) returns (bytes29) {
        if (getVinLength(_vin) != _vin.len()) {
            return TypedMemView.nullView();
        }
        return _vin.castTo(uint40(MemViewType.Vin));
    }

    /// @notice         verifies the vout and converts to a typed memory
    /// @dev            will return null in error cases
    /// @param _vout    the vout
    /// @return         the typed vout (or null if error)
    function tryAsVout(bytes29 _vout) internal pure typeAssert(_vout, MemViewType.Unknown) returns (bytes29) {
        if (getVoutLength(_vout) != _vout.len()) {
            return TypedMemView.nullView();
        }
        return _vout.castTo(uint40(MemViewType.Vout));
    }

    /// @notice             returns size of vin
    /// @param _vinView     the vin
    /// @return             the size of vin
    function getVinLength(bytes29 _vinView) internal pure returns (uint256) {
        if (_vinView.len() == 0) {
            return 0;
        }
        uint64 nIns = indexCompactInt(_vinView, 0);
        uint256 viewLen = _vinView.len();
        if (nIns == 0) {
            return 0;
        }

        uint256 offset = uint256(_compactIntLength(nIns));
        for (uint256 i = 0; i < nIns; ++i) {
            if (offset >= viewLen) {
                return 0;
            }
            bytes29 remaining = _vinView.postfix(viewLen - offset, uint40(MemViewType.IntermediateTxIns));
            offset += _inputLength(remaining);
        }
        return offset;
    }

    /// @notice             returns size of vout
    /// @param _voutView    the vout
    /// @return             the size of vout
    function getVoutLength(bytes29 _voutView) internal pure returns (uint256) {
        if (_voutView.len() == 0) {
            return 0;
        }
        uint64 nOuts = indexCompactInt(_voutView, 0);

        uint256 viewLen = _voutView.len();
        if (nOuts == 0) {
            return 0;
        }

        uint256 offset = uint256(_compactIntLength(nOuts));
        for (uint256 i = 0; i < nOuts; ++i) {
            if (offset >= viewLen) {
                return 0;
            }
            bytes29 remaining = _voutView.postfix(viewLen - offset, uint40(MemViewType.IntermediateTxOuts));
            offset += _outputLength(remaining);
        }
        return offset;
    }

    /// @notice                    Parses a Zcash v5 (NU5) transparent transaction.
    /// @dev                       Wire layout: [nVersion(4)] [nVersionGroupId(4)] [nConsensusBranchId(4)]
    ///                                         [nLockTime(4)] [nExpiryHeight(4)] [vin] [vout] [Sapling/Orchard data (ignored)]
    ///                            Bit 31 of the version word is the fOverwintered flag; it is stripped before
    ///                            storing into version.  Trailing shielded bundle bytes are silently ignored.
    /// @param _tx                 Raw Zcash v5 transaction bytes
    /// @return parsedTx           Parsed transaction fields
    function extractTx(bytes memory _tx) internal pure returns (ZcashTx memory parsedTx) {
        bytes29 txView = _tx.ref(uint40(MemViewType.Unknown));

        uint32 rawVersion = txView.indexLEUint(0, 4).toUint32();
        require(rawVersion & 0x80000000 != 0, "ZcashHelper: fOverwintered flag not set");
        parsedTx.version = rawVersion & 0x7FFFFFFF;
        require(parsedTx.version == 5, "ZcashHelper: unsupported tx version");

        parsedTx.versionGroupId     = txView.indexLEUint(4, 4).toUint32();
        parsedTx.consensusBranchId  = txView.indexLEUint(8, 4).toUint32();

        parsedTx.lockTime     = txView.indexLEUint(12, 4).toUint32();
        parsedTx.expiryHeight = txView.indexLEUint(16, 4).toUint32();

        uint256 offset = 20; // start of vin

        uint256 vinLen = getVinLength(txView.postfix(txView.len() - offset, uint40(MemViewType.Unknown)));
        parsedTx.vinView = txView.slice(offset, vinLen, uint40(MemViewType.Vin));
        offset += vinLen;

        uint256 voutLen = getVoutLength(txView.postfix(txView.len() - offset, uint40(MemViewType.Unknown)));
        parsedTx.voutView = txView.slice(offset, voutLen, uint40(MemViewType.Vout));

        // Trailing bytes are Sapling/Orchard shielded bundle data; ignored for transparent parsing.
    }

    /// @notice  Computes the txid for a Zcash v5 (NU5) transaction via ZIP-244 BLAKE2b tree-hash.
    /// @dev     Requires the on-chain BLAKE2b precompile at address 0x67.
    ///          Call extractTx first so the raw bytes are parsed exactly once.
    function calculateTxId(ZcashTx memory _tx) internal view returns (bytes32) {
        bytes memory prevoutsData;
        bytes memory seqData;
        {
            uint256 nIns = uint256(indexCompactInt(_tx.vinView, 0));
            for (uint256 i = 0; i < nIns; ++i) {
                bytes29 inputView = indexVin(_tx.vinView, i);
                prevoutsData = abi.encodePacked(prevoutsData, outpoint(inputView).clone());

                uint64 scriptLen = indexCompactInt(inputView, 36);
                uint256 seqOffset = 36 + _compactIntLength(scriptLen) + scriptLen;
                seqData = abi.encodePacked(seqData, bytes4(inputView.index(seqOffset, 4)));
            }
        }

        bytes memory outsData;
        {
            uint256 nOuts = uint256(indexCompactInt(_tx.voutView, 0));
            for (uint256 i = 0; i < nOuts; ++i) {
                outsData = abi.encodePacked(outsData, indexVout(_tx.voutView, i).clone());
            }
        }

        bytes32 headerHash = blake2b256(abi.encodePacked(
            bytes16("ZTxIdHeadersHash"),
            _leBytes4(_tx.version | 0x80000000),
            _leBytes4(_tx.versionGroupId),
            _leBytes4(_tx.consensusBranchId),
            _leBytes4(_tx.lockTime),
            _leBytes4(_tx.expiryHeight)
        ));

        bytes32 prevoutsHash = blake2b256(abi.encodePacked(bytes16("ZTxIdPrevoutHash"), prevoutsData));
        bytes32 sequenceHash = blake2b256(abi.encodePacked(bytes16("ZTxIdSequencHash"), seqData));
        bytes32 outputsHash  = blake2b256(abi.encodePacked(bytes16("ZTxIdOutputsHash"), outsData));

        bytes32 transparentHash = blake2b256(abi.encodePacked(
            bytes16("ZTxIdTranspaHash"),
            prevoutsHash,
            sequenceHash,
            outputsHash
        ));

        bytes32 saplingHash = blake2b256(abi.encodePacked(bytes16("ZTxIdSaplingHash")));
        bytes32 orchardHash = blake2b256(abi.encodePacked(bytes16("ZTxIdOrchardHash")));

        return blake2b256(abi.encodePacked(
            bytes12("ZcashTxHash_"), _leBytes4(_tx.consensusBranchId),
            headerHash,
            transparentHash,
            saplingHash,
            orchardHash
        ));
    }

}
