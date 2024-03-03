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
    "00400231e9ee1956222a741e5d79f8aaa8c35b0d8a666dc8b0e6b768b422000000000000c0370935585f7670f952ed06816afdd34958012c626cab08d9b446672decaffe9214e46518fe271908327127");

program.option("--initChainHeight <initChainHeight>",
    "init btc chain height",
    2580310);

program.option("--mock <mock>",
    "if use mock",
    false);

program.parse(process.argv);

const data = {
  initRoundInterval: init_cycle.roundInterval,
  initConsensusStateBytes: program.initConsensusStateBytes,
  initChainHeight: program.initChainHeight,
  rewardForValidatorSetChange: program.rewardForValidatorSetChange,
  mock: program.mock,
};
const templateString = fs.readFileSync(program.template).toString();
const resultString = nunjucks.renderString(templateString, data);
fs.writeFileSync(program.output, resultString);
console.log("BtcLightClient file updated.");
