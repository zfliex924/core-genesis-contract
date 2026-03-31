const program = require("commander");
const fs = require("fs");
const nunjucks = require("nunjucks");

program.version("0.0.1");
program.option(
    "-t, --template <template>",
    "ZcashLightClient template file",
    "./contracts/ZcashLightClient.template"
);

program.option(
    "-o, --output <output-file>",
    "ZcashLightClient.sol",
    "./contracts/ZcashLightClient.sol"
)

program.option("--initConsensusStateBytes <initConsensusStateBytes>",
    "init Zcash consensusState bytes, hex encoding, no prefix with 0x",
    "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");

program.option("--initChainHeight <initChainHeight>",
    "init Zcash chain height",
    1);

program.option("--mock <mock>",
    "if use mock",
    false);

program.parse(process.argv);

const data = {
  initConsensusStateBytes: program.initConsensusStateBytes,
  initChainHeight: program.initChainHeight,
  mock: program.mock,
};
const templateString = fs.readFileSync(program.template).toString();
const resultString = nunjucks.renderString(templateString, data);
fs.writeFileSync(program.output, resultString);
console.log("ZcashLightClient file updated.");
