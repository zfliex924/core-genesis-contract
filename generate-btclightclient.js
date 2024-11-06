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
    "00c06125b955dbe506163eb531337338977990294ceed6a687d9e3365f6d2801000000009a8eaf7144975fe0eb160f344ebb619195738de9d7d55365abb8ac6c831e1cfa401f2b67c0ff3f1c7a7d8183");
    
program.option("--initChainHeight <initChainHeight>",
    "init btc chain height",
    3348576);

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
