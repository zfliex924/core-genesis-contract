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
    "0000002006226e46111a0b59caaf126043eb5bbf28c34f3a5e332a1fc7b2b73cf188910f7c878e0bd00e7c302328e8d22e26d7f519f26329e6c0462ae89059fb7fd732811728f763ffff7f2001000000");

program.option("--initChainHeight <initChainHeight>",
    "init btc chain height",
    1);

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
