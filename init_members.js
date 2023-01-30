const web3 = require("web3")
const RLP = require('rlp');

// Configure
const members = [
  "0x1ef01E76f1aad50144A32680f16Aa97a10f8aF95",
  "0x140A939b5a10952f958A08244D93185F6a0bC91e",
  "0xB129986cAB3b865A6267415eE4Ca2d86a5704fdE",
];

const testnetMembers = [
  "0x91fb7d8a73d2752830ea189737ea0e007f999b94",
  "0x48bfbc530e7c54c332b0fae07312fba7078b8789",
  "0xde60b7d0e6b758ca5dd8c61d377a2c5f1af51ec1"
];

// ===============  Do not edit below ====
function membersRlpEncode(members) {
  return web3.utils.bytesToHex(RLP.encode(members));
}

initMembersBytes = membersRlpEncode(members)
initMembersTestnetBytes = membersRlpEncode(testnetMembers)
exports = module.exports = {
  initMembers: initMembersBytes,
  initMembersTestnet: initMembersTestnetBytes,
}