const web3 = require("web3")
const init_holders = [
    {
        address: "0x1ef01E76f1aad50144A32680f16Aa97a10f8aF95",
        balance: web3.utils.toBN("100000000000000000000000000").toString("hex")
    },
    {
        address: "0x140A939b5a10952f958A08244D93185F6a0bC91e",
        balance: web3.utils.toBN("100000000000000000000000000").toString("hex")
    },
    {
        address: "0xB129986cAB3b865A6267415eE4Ca2d86a5704fdE",
        balance: web3.utils.toBN("100000000000000000000000000").toString("hex")
    },
    {
        address: "0xF2802AEDc647BFAd2b31373f9FDE308A8c69305a",
        balance: web3.utils.toBN("100000000000000000000000000").toString("hex")
    }
];


exports = module.exports = init_holders
