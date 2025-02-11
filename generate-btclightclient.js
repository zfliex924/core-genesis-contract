const program = require("commander");
const fs = require("fs");
const nunjucks = require("nunjucks");

const init_cycle = require("./init_cycle")

program.version("0.0.1");
program.option(
    "-t, --template <template>",
    "BtcLightClient template file",
    "./contracts/BtcLightClient.template"
);

program.option(
    "-o, --output <output-file>",
    "BtcLightClient.sol",
    "./contracts/BtcLightClient.sol"
)

program.option("--rewardForValidatorSetChange <rewardForValidatorSetChange>",
    "rewardForValidatorSetChange",
    "1e16"); //1e16

program.option("--initConsensusStateBytes <initConsensusStateBytes>",
    "init consensusState bytes, hex encoding, no prefix with 0x",
    "00805629400be5c2b190764772a2d65184b55687f8ef12c1ea5173230000000000000000833444ba5744737d9318db1cca7c49307a2f43a10048dbed4a31f472387eaee7300ea467c0ff3f1990e40d40");
    
program.option("--initChainHeight <initChainHeight>",
    "init btc chain height",
    3771936
);

program.option("--mock <mock>",
    "if use mock",
    false);

program.parse(process.argv);

const data = {
  initConsensusStateBytes: program.initConsensusStateBytes,
  initChainHeight: program.initChainHeight,
  rewardForValidatorSetChange: program.rewardForValidatorSetChange,
  mock: program.mock,
};
const templateString = fs.readFileSync(program.template).toString();
const resultString = nunjucks.renderString(templateString, data);
fs.writeFileSync(program.output, resultString);
console.log("BtcLightClient file updated.");
