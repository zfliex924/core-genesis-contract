const web3 = require("web3")
const RLP = require('rlp');
const init_cycle = require("./init_cycle")

// Configure
const validators = [
  
  {
    "consensusAddr": "0x01Bca3615D24d3c638836691517b2B9b49b054B1",
    "feeAddr": "0x01Bca3615D24d3c638836691517b2B9b49b054B1",
  }/*,
  {
    "consensusAddr": "0xa458499604A85E90225a14946f36368Ae24df16D",
    "feeAddr": "0xa458499604A85E90225a14946f36368Ae24df16D",
  },
  {
    "consensusAddr": "0x5E00C0D5C4C10d4c805aba878D51129A89d513e0",
    "feeAddr": "0x5E00C0D5C4C10d4c805aba878D51129A89d513e0",
  },
  {
    "consensusAddr": "0x1Cd652bC64Af3f09B490dAae27f46e53726ce230",
    "feeAddr": "0x1Cd652bC64Af3f09B490dAae27f46e53726ce230",
  },
  {
    "consensusAddr": "0xDA37ccECBB2D7C83aE27eE2BeBFE8EBCe162c600",
    "feeAddr": "0xDA37ccECBB2D7C83aE27eE2BeBFE8EBCe162c600",
  },
  {
   "consensusAddr": "0x37d129288af5A561472D09F1174f4f86CF13E92F",
   "feeAddr": "0x37d129288af5A561472D09F1174f4f86CF13E92F",
 },
 {
   "consensusAddr": "0x8073CF54f45fe63F7F3Cd64c22447aaA528B198E",
   "feeAddr": "0x8073CF54f45fe63F7F3Cd64c22447aaA528B198E",
 }*/
];

// ===============  Do not edit below ====
function generateExtradata(validators) {
  let extraVanity = Buffer.alloc(32);
  let validatorsBytes = extraDataSerialize(validators);
  let turnLengthByte = Buffer.from([init_cycle.turnLength]); // Initial turnLength from init_cycle.js
  let extraSeal = Buffer.alloc(65);
  return Buffer.concat([extraVanity,validatorsBytes,turnLengthByte,extraSeal]);
}

function extraDataSerialize(validators) {
  let n = validators.length;
  let arr = [];
  const defaultVoteAddr = "0x" + "00".repeat(48); // 48 bytes of zeros
  
  arr.push(Buffer.from([n]));
  for (let i = 0;i<n;i++) {
    let validator = validators[i];
    const voteAddr = validator.voteAddr || defaultVoteAddr;
    
    arr.push(Buffer.from(web3.utils.hexToBytes(validator.consensusAddr)));
    arr.push(Buffer.from(web3.utils.hexToBytes(voteAddr)));
  }
  return Buffer.concat(arr);
}

function validatorUpdateRlpEncode(validators) {
  let n = validators.length;
  let vals = [];
  const defaultVoteAddr = "0x" + "00".repeat(48); // 48 bytes of zeros
  
  for (let i = 0;i<n;i++) {
    const voteAddr = validators[i].voteAddr || defaultVoteAddr;
    vals.push([
      validators[i].consensusAddr,
      validators[i].feeAddr,
      voteAddr,
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