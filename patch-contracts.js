#!/usr/bin/env node
// patch-contracts.js
// Patches constants in .sol files.
//
// Usage as library:
//   const { patchNetwork, patchContracts } = require('./patch-contracts');
//   patchNetwork('mainnet');                                           // load patches from genesis-config
//   patchContracts({ 'ZcashLightClient.INIT_CHAIN_HEIGHT': 1, ... }); // explicit patches
//
// Usage as CLI:
//   node patch-contracts.js --network mainnet
//   node patch-contracts.js ZcashLightClient.INIT_CHAIN_HEIGHT=1
//   node patch-contracts.js ZcashLightClient.INIT_CONSENSUS_STATE_BYTES=hex:0000....

const fs = require('fs');
const path = require('path');

function findContractFile(contractName) {
  const contractsDir = path.join(__dirname, 'contracts');
  const results = [];
  function scan(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) scan(full);
      else if (entry.isFile() && entry.name === `${contractName}.sol`) results.push(full);
    }
  }
  scan(contractsDir);
  if (results.length === 0) throw new Error(`No contract file found for '${contractName}'`);
  if (results.length > 1) throw new Error(`Multiple contract files found for '${contractName}': ${results.map(p => path.relative(__dirname, p)).join(', ')}`);
  return path.relative(__dirname, results[0]);
}

function patchSolConstant(filePath, name, value) {
  const content = fs.readFileSync(filePath, 'utf8');
  const updated = applyPatch(content, filePath, name, value);
  fs.writeFileSync(filePath, updated, 'utf8');
}

function patchContracts(patches) {
  // Group patches by contract file to batch reads/writes
  const byFile = {};
  for (const [key, value] of Object.entries(patches)) {
    const dot = key.indexOf('.');
    if (dot === -1) throw new Error(`Invalid patch key '${key}', expected 'ContractName.CONSTANT_NAME'`);
    const contractName = key.slice(0, dot);
    const fieldName = key.slice(dot + 1);
    const filePath = findContractFile(contractName);
    if (!byFile[filePath]) byFile[filePath] = [];
    byFile[filePath].push({ fieldName, value });
  }

  for (const [filePath, fields] of Object.entries(byFile)) {
    let content = fs.readFileSync(filePath, 'utf8');
    for (const { fieldName, value } of fields) {
      content = applyPatch(content, filePath, fieldName, value);
      console.log(`  patched ${filePath}: ${fieldName} = ${value && typeof value === 'object' ? `hex"${value.hex.slice(0, 16)}..."` : value}`);
    }
    fs.writeFileSync(filePath, content, 'utf8');
  }
}

function applyPatch(content, filePath, name, value) {
  if (value && typeof value === 'object' && 'hex' in value) {
    const re = new RegExp(`(constant\\s+${name}\\s*=\\s*hex")([0-9a-fA-F]*)("\\s*;)`, 'g');
    const matches = content.match(re);
    if (!matches) throw new Error(`Could not find hex constant '${name}' in ${filePath}`);
    if (matches.length > 1) throw new Error(`Multiple matches for hex constant '${name}' in ${filePath}`);
    return content.replace(re, `$1${value.hex}$3`);
  } else {
    const re = new RegExp(`(constant\\s+${name}\\s*=\\s*)([^;\\n]+)(;)`, 'g');
    const matches = content.match(re);
    if (!matches) throw new Error(`Could not find constant '${name}' in ${filePath}`);
    if (matches.length > 1) throw new Error(`Multiple matches for constant '${name}' in ${filePath}`);
    return content.replace(re, `$1${value}$3`);
  }
}

function patchNetwork(network) {
  const { loadConfig } = require('./genesis-config');
  const { raw, patches } = loadConfig(network);
  patchContracts(patches);
  return raw;
}

// CLI mode
if (require.main === module) {
  const args = process.argv.slice(2);
  if (args.length === 0) {
    console.error('Usage:');
    console.error('  node patch-contracts.js --network <mainnet|testnet|devnet>');
    console.error('  node patch-contracts.js ContractName.FIELD=value ...');
    process.exit(1);
  }

  try {
    if (args[0] === '--network' || args[0].startsWith('--network=')) {
      const program = require('commander');
      program.option('--network <network>', 'network: mainnet / testnet / devnet');
      program.parse(process.argv);
      if (!program.network) { console.error('--network value required'); process.exit(1); }
      patchNetwork(program.network);
    } else {
      const patches = {};
      for (const arg of args) {
        const eq = arg.indexOf('=');
        if (eq === -1) { console.error(`Invalid argument: ${arg}`); process.exit(1); }
        const key = arg.slice(0, eq);
        const val = arg.slice(eq + 1);
        patches[key] = val.startsWith('hex:') ? { hex: val.slice(4) } : val;
      }
      patchContracts(patches);
    }
    console.log('Done.');
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
}

module.exports = { patchNetwork, patchContracts, patchSolConstant, findContractFile };
