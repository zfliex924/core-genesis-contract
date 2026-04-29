#!/usr/bin/env node
// genesis-config.js
// Loads configs/<network>.json and computes contract constant patches in memory.
//
// As a library (imported by generate-genesis.js):
//   const { loadConfig } = require('./genesis-config');
//   const { raw, patches } = loadConfig('mainnet');
//
// As a CLI (inspect computed patches without generating genesis):
//   node genesis-config.js --network mainnet

// Suppress DEP0040: punycode deprecation from web3's transitive deps.
process.noDeprecation = true;

const fs   = require('fs');
const path = require('path');
const web3 = require('web3');
const RLP  = require('rlp');

const KNOWN_NETWORKS    = ['mainnet', 'testnet', 'devnet'];
const DEFAULT_VOTE_ADDR = '0x' + '00'.repeat(48);

// ─── Encoding utilities ────────────────────────────────────────────────────

function normalizeValidators(validators) {
  return validators.map(v => ({
    consensusAddr: v.consensusAddr,
    feeAddr:       v.feeAddr,
    voteAddr:      v.voteAddr || DEFAULT_VOTE_ADDR,
  }));
}

function validatorSetRlpEncode(validators) {
  const vals = validators.map(v => [v.consensusAddr, v.feeAddr, v.voteAddr]);
  return web3.utils.bytesToHex(RLP.encode(vals)).slice(2); // strip 0x
}

function membersRlpEncode(members) {
  return web3.utils.bytesToHex(RLP.encode(members)).slice(2); // strip 0x
}

function generateExtradata(validators, turnLength) {
  const extraVanity    = Buffer.alloc(32);
  const validatorBytes = extraDataSerialize(validators);
  const turnLengthByte = Buffer.from([turnLength]);
  const extraSeal      = Buffer.alloc(65);
  return Buffer.concat([extraVanity, validatorBytes, turnLengthByte, extraSeal]);
}

function extraDataSerialize(validators) {
  const arr = [Buffer.from([validators.length])];
  for (const v of validators) {
    arr.push(Buffer.from(web3.utils.hexToBytes(v.consensusAddr)));
    arr.push(Buffer.from(web3.utils.hexToBytes(v.voteAddr)));
  }
  return Buffer.concat(arr);
}

// ─── Config loading ────────────────────────────────────────────────────────

function buildPatches(raw) {
  const validators = normalizeValidators(raw.validators || []);
  const masp = raw.masp || {};
  const initWhitelistedTokens = masp.whitelistedTokens || [];
  const initASPs              = masp.asps || [];

  // RLP-encode initial whitelist as list of [tokenType (1B), tokenAddress (20B), tokenSubID (32B)]
  const tokenItems = initWhitelistedTokens.map(t => [
    Buffer.from([t.tokenType & 0xff]),
    Buffer.from(web3.utils.hexToBytes(t.address)),
    Buffer.from(web3.utils.padLeft(web3.utils.numberToHex(t.subId || 0), 64).slice(2), 'hex'),
  ]);
  const aspItems = initASPs.map(a => Buffer.from(web3.utils.hexToBytes(a)));

  return {
    'ZcashLightClient.INIT_CONSENSUS_STATE_BYTES': { hex: raw.zcash.initConsensusStateBytes },
    'ZcashLightClient.INIT_CHAIN_HEIGHT':          raw.zcash.initChainHeight,
    'ValidatorSet.INIT_VALIDATORSET_BYTES':        { hex: validatorSetRlpEncode(validators) },
    'GovHub.VOTING_PERIOD':                        raw.gov.votingPeriod,
    'GovHub.EXECUTING_PERIOD':                     raw.gov.executingPeriod,
    'GovHub.INIT_MEMBERS':                         { hex: membersRlpEncode(raw.members || []) },
    'SatoshiPlusHelper.ROUND_INTERVAL':            raw.cycle.roundInterval,
    'SatoshiPlusHelper.CHAINID':                   raw.chainId,
    'MASP.INIT_PROTOCOL_FEE_BPS':                  masp.protocolFeeBps   || 0,
    'MASP.INIT_TREASURY':                          masp.treasury         || '0x0000000000000000000000000000000000000000',
    'MASP.INIT_UNSHIELD_DELAY':                    masp.unshieldDelay    || 0,
    'MASP.INIT_ASP_STALENESS':                     masp.aspStalenessSec  || 86400,
    'MASP.INIT_WHITELIST_TOKENS':                  { hex: web3.utils.bytesToHex(RLP.encode(tokenItems)).slice(2) },
    'MASP.INIT_ASP_LIST':                          { hex: web3.utils.bytesToHex(RLP.encode(aspItems)).slice(2) },
  };
}

function loadConfig(network) {
  if (!KNOWN_NETWORKS.includes(network)) {
    throw new Error(`Unknown network '${network}'. Known: ${KNOWN_NETWORKS.join(', ')}`);
  }
  const configPath = path.join(__dirname, 'configs', `${network}.json`);
  if (!fs.existsSync(configPath)) {
    throw new Error(`Config not found: ${configPath}`);
  }
  const raw = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  for (const key of ['chainId', 'validators', 'members', 'cycle', 'zcash', 'gov']) {
    if (raw[key] == null) throw new Error(`Config '${network}.json' missing required field: '${key}'`);
  }
  const patches = buildPatches(raw);
  return { raw, patches };
}

module.exports = {
  normalizeValidators,
  generateExtradata,
  validatorSetRlpEncode,
  membersRlpEncode,
  buildPatches,
  loadConfig,
};

// ─── CLI (inspect patches without generating genesis) ──────────────────────

if (require.main === module) {
  const program = require('commander');
  program.option('--network <network>', `network: ${KNOWN_NETWORKS.join(' / ')}`, 'mainnet');
  program.parse(process.argv);
  try {
    const { raw, patches } = loadConfig(program.network);
    const validators = normalizeValidators(raw.validators || []);
    const extraData  = generateExtradata(validators, raw.cycle.turnLength);
    console.log(`Network   : ${program.network} (chainId: ${raw.chainId})`);
    console.log(`Validators: ${validators.length}, extraData: ${extraData.length} bytes`);
    console.log(JSON.stringify(patches, null, 2));
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
}
