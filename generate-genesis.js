const { spawn }  = require('child_process');
const program    = require('commander');
const nunjucks   = require('nunjucks');
const fs         = require('fs');
const web3       = require('web3');
const { normalizeValidators, generateExtradata } = require('./genesis-config');
const { patchNetwork } = require('./patch-contracts');

program.option('--network <network>', 'network: mainnet / testnet / devnet', 'mainnet');
program.option('-o, --output <output-file>', 'Genesis json file', './genesis.json');
program.option('-t, --template <template>', 'Genesis template json', './genesis-template.json');
program.version('0.0.1');
program.parse(process.argv);

// compile contract
function compileContract(key, contractFile, contractName) {
  return new Promise((resolve, reject) => {
    const ls = spawn('solc', [
      '@openzeppelin/=./node_modules/@openzeppelin/',
      '--bin-runtime',
      '/=/',
      '--optimize',
      '--optimize-runs',
      '10000',
      contractFile,
    ]);

    const result = [];
    const errors = [];
    ls.stdout.on('data', data => result.push(data.toString()));
    ls.stderr.on('data', data => errors.push(data.toString()));
    ls.on('close', code => {
      if (code !== 0) {
        reject(new Error(`solc failed for ${contractFile} (exit ${code}):\n${errors.join('')}`));
        return;
      }
      resolve(result.join(''));
    });
  }).then(compiledData => {
    console.log(`${contractFile}:${contractName}`);
    compiledData = compiledData.replace(
      `======= ${contractFile}:${contractName} =======\nBinary of the runtime part:`,
      '@@@@'
    );
    const matched = compiledData.match(/@@@@\n([a-f0-9]+)/);
    if (!matched) throw new Error(`No bytecode found in solc output for ${contractFile}:${contractName}`);
    return { key, compiledData: matched[1], contractName, contractFile };
  });
}

async function main() {
  const network = program.network;

  let raw;
  try {
    raw = patchNetwork(network);
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }

  console.log(`Generating genesis for network: ${network} (chainId: ${raw.chainId})`);

  const validators = normalizeValidators(raw.validators || []);
  const extraData  = generateExtradata(validators, raw.cycle.turnLength);

  const result = await Promise.all([
    compileContract('validatorContract',    'contracts/ValidatorSet.sol',    'ValidatorSet'),
    compileContract('systemRewardContract', 'contracts/SystemReward.sol',    'SystemReward'),
    compileContract('slashContract',        'contracts/SlashIndicator.sol',  'SlashIndicator'),
    compileContract('relayerHub',           'contracts/RelayerHub.sol',      'RelayerHub'),
    compileContract('candidateHub',         'contracts/CandidateHub.sol',    'CandidateHub'),
    compileContract('govHub',               'contracts/GovHub.sol',          'GovHub'),
    compileContract('foundation',           'contracts/Foundation.sol',      'Foundation'),
    compileContract('stakehub',             'contracts/StakeHub.sol',        'StakeHub'),
    compileContract('nativeagent',          'contracts/NativeAgent.sol',     'NativeAgent'),
    compileContract('hashpoweragent',       'contracts/HashPowerAgent.sol',  'HashPowerAgent'),
    compileContract('configuration',        'contracts/Configuration.sol',   'Configuration'),
    compileContract('channel',              'contracts/Channel.sol',         'Channel'),
    compileContract('zeclightclient',       'contracts/ZcashLightClient.sol','ZcashLightClient'),
    compileContract('zecagent',             'contracts/ZecAgent.sol',        'ZecAgent'),
    compileContract('grademanager',         'contracts/GradeManager.sol',    'GradeManager'),
  ]);

  const data = {
    chainId:     raw.chainId,
    initHolders: raw.holders || [],
    initCycle:   raw.cycle,
    extraData:   web3.utils.bytesToHex(extraData),
  };
  result.forEach(r => { data[r.key] = r.compiledData; });

  const templateString = fs.readFileSync(program.template).toString();
  const resultString   = nunjucks.renderString(templateString, data);
  fs.writeFileSync(program.output, resultString);
  console.log(`Genesis written to ${program.output}`);
}

main().catch(e => { console.error(e); process.exit(1); });
