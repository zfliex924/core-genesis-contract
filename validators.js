const web3 = require("web3")
const RLP = require('rlp');

// Configure
const validators = [
  
   {
     "consensusAddr": "0xff19437f7e54c71e06ee852d9331a1de74947a9c",
     "feeAddr": "0xff19437f7e54c71e06ee852d9331a1de74947a9c",
   },
   {
     "consensusAddr": "0xfd6ac9177cb6746d8b1b778593f1b30c36f08d5e",
     "feeAddr": "0xfd6ac9177cb6746d8b1b778593f1b30c36f08d5e",
   },
   {
     "consensusAddr": "0x621bb82013b8fd872e8c6d05464cd178a4022b7f",
     "feeAddr": "0x621bb82013b8fd872e8c6d05464cd178a4022b7f",
   },
   {
     "consensusAddr": "0xed008886add78c088e81301e2bc9dfb44f753e5f",
     "feeAddr": "0xed008886add78c088e81301e2bc9dfb44f753e5f",
   },
   {
     "consensusAddr": "0x961da3b345986135554ab4220481c537cd6a58f5",
     "feeAddr": "0x961da3b345986135554ab4220481c537cd6a58f5",
   },
   {
     "consensusAddr": "0x22e3784299dee116da904fa848eb17df6a7bffd7",
     "feeAddr": "0x22e3784299dee116da904fa848eb17df6a7bffd7",
   },
   {
     "consensusAddr": "0x7beda3dc8979bb04724a4b04f1f21c612a8181b5",
     "feeAddr": "0x7beda3dc8979bb04724a4b04f1f21c612a8181b5",
   },
   {
     "consensusAddr": "0x82eebb342240a4f11b6dce49f071ae5e9137f60a",
     "feeAddr": "0x82eebb342240a4f11b6dce49f071ae5e9137f60a",
   },
   {
     "consensusAddr": "0xba53c770d67f243e7b3765034adfaae7c6e9a019",
     "feeAddr": "0xba53c770d67f243e7b3765034adfaae7c6e9a019",
   },
   {
     "consensusAddr": "0x60cbbb68dfc0546e6fd9a054f805a78c29129eab",
     "feeAddr": "0x60cbbb68dfc0546e6fd9a054f805a78c29129eab",
   },
   {
     "consensusAddr": "0x8306c756a658edc9176c9d429d81d2171ce3eccd",
     "feeAddr": "0x8306c756a658edc9176c9d429d81d2171ce3eccd",
   },
   {
     "consensusAddr": "0xa501e29d26015780dd35960ec7f78ab9b70e304d",
     "feeAddr": "0xa501e29d26015780dd35960ec7f78ab9b70e304d",
   },
   {
     "consensusAddr": "0x8be8aaf62090c6e5aeca06549a0602d83000c8f0",
     "feeAddr": "0x8be8aaf62090c6e5aeca06549a0602d83000c8f0",
   },
   {
     "consensusAddr": "0xdbf84f2b4ea80f39bf38418a0b6aef4b2c61cc49",
     "feeAddr": "0xdbf84f2b4ea80f39bf38418a0b6aef4b2c61cc49",
   },
   {
     "consensusAddr": "0x8a7b6ce9b85a8616e2fdaf7f4b552630764f8ecb",
     "feeAddr": "0x8a7b6ce9b85a8616e2fdaf7f4b552630764f8ecb",
   },{
    "consensusAddr": "0xc36fca8bfb8c8b15f4672b5c6a9af7d605fdfe76",
    "feeAddr": "0xc36fca8bfb8c8b15f4672b5c6a9af7d605fdfe76",
  },{
    "consensusAddr": "0xe06e02d9a83ad029ee89998d8d0756c839904b16",
    "feeAddr": "0xe06e02d9a83ad029ee89998d8d0756c839904b16",
  },{
    "consensusAddr": "0x3dec0c35abf13f8d8558c27cb4fc75d841eaec7b",
    "feeAddr": "0x3dec0c35abf13f8d8558c27cb4fc75d841eaec7b",
  },{
    "consensusAddr": "0xdd58df5584fee7ee2f33a154aebb4069e21da550",
    "feeAddr": "0xdd58df5584fee7ee2f33a154aebb4069e21da550",
  },{
    "consensusAddr": "0x1eef77f61f9d205ab5cb1227d13f291aab5c777f",
    "feeAddr": "0x1eef77f61f9d205ab5cb1227d13f291aab5c777f",
  },{
    "consensusAddr": "0x982289480370a4fffbb7902ba74c31e87f805774",
    "feeAddr": "0x982289480370a4fffbb7902ba74c31e87f805774",
  },{
    "consensusAddr": "0xe852db54ebbe8d9ca950c4bbdd55722aa498ba9a",
    "feeAddr": "0xe852db54ebbe8d9ca950c4bbdd55722aa498ba9a",
  },{
    "consensusAddr": "0x86b92508cd7b49fd33e2b34f8431e560c7c5028b",
    "feeAddr": "0x86b92508cd7b49fd33e2b34f8431e560c7c5028b",
  },{
    "consensusAddr": "0xb381c04eb21d345bbd5efdd1e2b4f31367f24fbf",
    "feeAddr": "0xb381c04eb21d345bbd5efdd1e2b4f31367f24fbf",
  },{
    "consensusAddr": "0xd385dd7b37ffcaa53063bde8d52fee0e1c725b42",
    "feeAddr": "0xd385dd7b37ffcaa53063bde8d52fee0e1c725b42",
  }
];

// ===============  Do not edit below ====
function generateExtradata(validators) {
  let extraVanity =Buffer.alloc(32);
  let validatorsBytes = extraDataSerialize(validators);
  let extraSeal =Buffer.alloc(65);
  return Buffer.concat([extraVanity,validatorsBytes,extraSeal]);
}

function extraDataSerialize(validators) {
  let n = validators.length;
  let arr = [];
  for (let i = 0;i<n;i++) {
    let validator = validators[i];
    arr.push(Buffer.from(web3.utils.hexToBytes(validator.consensusAddr)));
  }
  return Buffer.concat(arr);
}

function validatorUpdateRlpEncode(validators) {
  let n = validators.length;
  let vals = [];
  for (let i = 0;i<n;i++) {
    vals.push([
      validators[i].consensusAddr,
      validators[i].feeAddr,
    ]);
  }
  return web3.utils.bytesToHex(RLP.encode(vals));
}

extraValidatorBytes = generateExtradata(validators);
validatorSetBytes = validatorUpdateRlpEncode(validators);

exports = module.exports = {
  extraValidatorBytes: extraValidatorBytes,
  validatorSetBytes: validatorSetBytes,
}