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
    "0060a22616eecf9b5c5205de70a5c0b4608e0dde7c907c6e9201330d1d00000000000000fb2b1bd579afe7e2956d965e5a85bdb65cee51eb04b3dcdbfa86379870446ab6eabf0b6650e2261938b05017");

program.option("--initChainHeight <initChainHeight>",
    "init btc chain height",
    2584914);

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
