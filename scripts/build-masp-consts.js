#!/usr/bin/env node
/* eslint-disable no-console */
//
// Compute every deterministic constant baked into MASP.sol so they can be
// audit-reviewed and regenerated from first principles.
//
// Outputs (printed to stdout, also written to scripts/masp-consts.json):
//   - TREE_DEPTH              : 20 (matches CommitmentTree.sol:16)
//   - ZERO_0 .. ZERO_19       : Poseidon T3 zero-hash chain
//   - EMPTY_TREE_ROOT         : poseidonT3(ZERO_19, ZERO_19)
//   - DEPOSIT_CONFIG_HASH     : keccak256(abi.encode(uint256(0), uint256(1)))
//   - TX_CONFIG_HASH          : keccak256(abi.encode("v2", uint256(2), uint256(2)))
//   - TX_1X2_CONFIG_HASH      : keccak256(abi.encode("v2", uint256(1), uint256(2)))
//   - TX_1X3_CONFIG_HASH      : keccak256(abi.encode("v2", uint256(1), uint256(3)))
//   - TX_2X4_CONFIG_HASH      : keccak256(abi.encode("v2", uint256(2), uint256(4)))
//   - TX_3X3_CONFIG_HASH      : keccak256(abi.encode("v2", uint256(3), uint256(3)))
//   - TX_2X8_CONFIG_HASH      : keccak256(abi.encode("v2", uint256(2), uint256(8)))
//   - NATIVE_TOKEN_HASH       : poseidonT4(0xFF, 0, 0)
//   - DEPOSIT_VK_BLOB         : alpha||beta||gamma||delta||IC for deposit circuit
//   - TRANSACTION_VK_BLOB     : same for n=2,c=2 K=2 circuit
//   - TRANSACTION1X2_VK_BLOB  : same for n=1,c=2 K=2 circuit
//   - TRANSACTION1X3_VK_BLOB  : same for n=1,c=3 K=2 circuit  (stub-emit if missing)
//   - TRANSACTION2X4_VK_BLOB  : same for n=2,c=4 K=2 circuit
//   - TRANSACTION3X3_VK_BLOB  : same for n=3,c=3 K=2 circuit  (stub-emit if missing)
//   - TRANSACTION2X8_VK_BLOB  : same for n=2,c=8 K=2 circuit
//
// Reads VKs from /Users/gokberkgulgun/Documents/GitHub/masp/src/verifiers/*Groth16Verifier.sol
// Override path with --masp-src=/path/to/masp.

const fs   = require('fs');
const path = require('path');
const { keccak256 } = require('ethers');
const { AbiCoder } = require('ethers');
const cl   = require('circomlibjs');

const TREE_DEPTH = 20;

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  if (i === -1) {
    const eqArg = process.argv.find(a => a.startsWith(name + '='));
    return eqArg ? eqArg.split('=', 2)[1] : fallback;
  }
  return process.argv[i + 1];
}

const mascSrcDefault = path.resolve(__dirname, '..', '..', 'masp');
const maspSrc        = arg('--masp-src', mascSrcDefault);

function toHex32(bigint) {
  let h = BigInt(bigint).toString(16);
  if (h.length > 64) throw new Error(`scalar overflow: ${bigint}`);
  return h.padStart(64, '0');
}

function hex0x(bigint) { return '0x' + toHex32(bigint); }

// numPubInputs (n) per K=2 circuit:
//   layout = merkleRoot + boundParamsHash + nullifiers[nIn] + commitments[nOut]
//          + publicTokenHashes[2] + publicAmounts[2] + actionHash
//   n      = 1 + 1 + nIn + nOut + 2 + 2 + 1 = 7 + nIn + nOut
function pubInputCount(nIn, nOut) {
  return 7 + nIn + nOut;
}

function extractVkBlob(file, n) {
  if (!fs.existsSync(file)) {
    return null;
  }
  const src = fs.readFileSync(file, 'utf8');
  const grab = (key) => {
    const m = src.match(new RegExp(`uint256 constant\\s+${key}\\s*=\\s*(\\d+)\\s*;`));
    if (!m) return null;
    return m[1];
  };
  // Detect placeholder stub (no real VK constants).
  if (grab('alphax') === null) return null;

  const parts = [];
  parts.push(toHex32(grab('alphax')), toHex32(grab('alphay')));
  for (const v of ['beta', 'gamma', 'delta']) {
    parts.push(toHex32(grab(`${v}x1`)), toHex32(grab(`${v}x2`)),
               toHex32(grab(`${v}y1`)), toHex32(grab(`${v}y2`)));
  }
  for (let i = 0; i <= n; i++) {
    parts.push(toHex32(grab(`IC${i}x`)), toHex32(grab(`IC${i}y`)));
  }
  return '0x' + parts.join('');
}

(async () => {
  const p = await cl.buildPoseidon();
  const F = p.F;

  const zeros = new Array(TREE_DEPTH);
  zeros[0] = F.toObject(p([0n, 0n]));
  for (let i = 1; i < TREE_DEPTH; i++) {
    zeros[i] = F.toObject(p([zeros[i-1], zeros[i-1]]));
  }
  const emptyTreeRoot = F.toObject(p([zeros[TREE_DEPTH-1], zeros[TREE_DEPTH-1]]));

  const abi = AbiCoder.defaultAbiCoder();

  // Deposit circuit uses un-salted (legacy) layout: keccak(uint256, uint256).
  const depositCfgHash = BigInt(keccak256(abi.encode(['uint256', 'uint256'], [0, 1])));

  // K=2 transaction circuits use the "v2"-salted layout to live in a disjoint keyspace.
  const txCfg = (a, b) => BigInt(keccak256(abi.encode(['string', 'uint256', 'uint256'], ['v2', a, b])));
  const txCfgHash    = txCfg(2, 2);
  const tx1x2CfgHash = txCfg(1, 2);
  const tx1x3CfgHash = txCfg(1, 3);
  const tx2x4CfgHash = txCfg(2, 4);
  const tx3x3CfgHash = txCfg(3, 3);
  const tx2x8CfgHash = txCfg(2, 8);

  const nativeTokenHash = F.toObject(p([0xffn, 0n, 0n]));

  const verifiers = [
    { name: 'Deposit',        n: 3,                     file: 'src/verifiers/DepositGroth16Verifier.sol' },
    { name: 'Transaction',    n: pubInputCount(2, 2),   file: 'src/verifiers/Transaction2x2_Groth16Verifier.sol' },
    { name: 'Transaction1x2', n: pubInputCount(1, 2),   file: 'src/verifiers/Transaction1x2_Groth16Verifier.sol' },
    { name: 'Transaction1x3', n: pubInputCount(1, 3),   file: 'src/verifiers/Transaction1x3_Groth16Verifier.sol' },
    { name: 'Transaction2x4', n: pubInputCount(2, 4),   file: 'src/verifiers/Transaction2x4_Groth16Verifier.sol' },
    { name: 'Transaction3x3', n: pubInputCount(3, 3),   file: 'src/verifiers/Transaction3x3_Groth16Verifier.sol' },
    { name: 'Transaction2x8', n: pubInputCount(2, 8),   file: 'src/verifiers/Transaction2x8_Groth16Verifier.sol' },
  ];

  const blobs = {};
  for (const v of verifiers) {
    const full = path.join(maspSrc, v.file);
    const blob = extractVkBlob(full, v.n);
    blobs[v.name] = blob;
  }

  const out = {
    TREE_DEPTH,
    ZEROS:                  zeros.map(hex0x),
    EMPTY_TREE_ROOT:        hex0x(emptyTreeRoot),
    DEPOSIT_CONFIG_HASH:    hex0x(depositCfgHash),
    TX_CONFIG_HASH:         hex0x(txCfgHash),
    TX_1X2_CONFIG_HASH:     hex0x(tx1x2CfgHash),
    TX_1X3_CONFIG_HASH:     hex0x(tx1x3CfgHash),
    TX_2X4_CONFIG_HASH:     hex0x(tx2x4CfgHash),
    TX_3X3_CONFIG_HASH:     hex0x(tx3x3CfgHash),
    TX_2X8_CONFIG_HASH:     hex0x(tx2x8CfgHash),
    NATIVE_TOKEN_HASH:      hex0x(nativeTokenHash),
    DEPOSIT_VK_BLOB:        blobs.Deposit,
    TRANSACTION_VK_BLOB:    blobs.Transaction,
    TRANSACTION1X2_VK_BLOB: blobs.Transaction1x2,
    TRANSACTION1X3_VK_BLOB: blobs.Transaction1x3,
    TRANSACTION2X4_VK_BLOB: blobs.Transaction2x4,
    TRANSACTION3X3_VK_BLOB: blobs.Transaction3x3,
    TRANSACTION2X8_VK_BLOB: blobs.Transaction2x8,
  };

  fs.writeFileSync(
    path.resolve(__dirname, 'masp-consts.json'),
    JSON.stringify(out, null, 2)
  );

  console.log(`// Auto-generated by scripts/build-masp-consts.js`);
  console.log(`// Source: ${maspSrc}`);
  console.log(`uint256 internal constant TREE_DEPTH = ${TREE_DEPTH};`);
  for (let i = 0; i < TREE_DEPTH; i++) {
    console.log(`uint256 internal constant ZERO_${i.toString().padStart(2,'0')} = ${hex0x(zeros[i])};`);
  }
  console.log(`uint256 internal constant EMPTY_TREE_ROOT     = ${hex0x(emptyTreeRoot)};`);
  console.log(`uint256 internal constant DEPOSIT_CONFIG_HASH  = ${hex0x(depositCfgHash)};`);
  console.log(`uint256 internal constant TX_CONFIG_HASH       = ${hex0x(txCfgHash)};`);
  console.log(`uint256 internal constant TX_1X2_CONFIG_HASH   = ${hex0x(tx1x2CfgHash)};`);
  console.log(`uint256 internal constant TX_1X3_CONFIG_HASH   = ${hex0x(tx1x3CfgHash)};`);
  console.log(`uint256 internal constant TX_2X4_CONFIG_HASH   = ${hex0x(tx2x4CfgHash)};`);
  console.log(`uint256 internal constant TX_3X3_CONFIG_HASH   = ${hex0x(tx3x3CfgHash)};`);
  console.log(`uint256 internal constant TX_2X8_CONFIG_HASH   = ${hex0x(tx2x8CfgHash)};`);
  console.log(`uint256 internal constant NATIVE_TOKEN_HASH    = ${hex0x(nativeTokenHash)};`);
  console.log('');
  for (const v of verifiers) {
    const blob = blobs[v.name];
    if (blob === null) {
      console.log(`// ${v.name}_VK_BLOB: source verifier missing or stub — set via governance after trusted-setup ceremony.`);
      continue;
    }
    console.log(`// ${v.name}: numPubInputs=${v.n}, IC count=${v.n + 1}, blob = ${(blob.length - 2) / 2} bytes`);
    console.log(`bytes constant ${v.name.toUpperCase()}_VK_BLOB = hex"${blob.slice(2)}";`);
  }
})().catch(e => { console.error(e); process.exit(1); });
