const web3 = require("web3")
const RLP = require('rlp');

// Configure
const validators = [
  
  {
    "consensusAddr": "0x01Bca3615D24d3c638836691517b2B9b49b054B1",
    "feeAddr": "0x01Bca3615D24d3c638836691517b2B9b49b054B1",
  },
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
 },
 {
   "consensusAddr": "0xb05Df22480f0F6EE235C102d3A780269535A2d23",
   "feeAddr": "0xb05Df22480f0F6EE235C102d3A780269535A2d23",
 },
 {
   "consensusAddr": "0x9caC06bb7662054c9825A01DAeF5E87AD3E721f3",
   "feeAddr": "0x9caC06bb7662054c9825A01DAeF5E87AD3E721f3",
 },
 {
   "consensusAddr": "0x6f3e55590D40B9c7EDDA62a72aC57B555e6ac824",
   "feeAddr": "0x6f3e55590D40B9c7EDDA62a72aC57B555e6ac824",
 },
 {
   "consensusAddr": "0x354a13C519b0be550aafCb2c9a992B058F945E82",
   "feeAddr": "0x354a13C519b0be550aafCb2c9a992B058F945E82",
 },
 {
   "consensusAddr": "0x4815E251c723B2B0D11AeD872157676ecAf7659f",
   "feeAddr": "0x4815E251c723B2B0D11AeD872157676ecAf7659f",
 },
 {
   "consensusAddr": "0xfB69605FC4A5b953f5451438FBf82C9Bd73B15ba",
   "feeAddr": "0xfB69605FC4A5b953f5451438FBf82C9Bd73B15ba",
 },
 {
   "consensusAddr": "0xF81b8ec0B5663edA06C11C326A2C8F2cBd6B4b62",
   "feeAddr": "0xF81b8ec0B5663edA06C11C326A2C8F2cBd6B4b62",
 },
 {
   "consensusAddr": "0xc08B5f2942502C7811e643da31906973967b674f",
   "feeAddr": "0xc08B5f2942502C7811e643da31906973967b674f",
 },
 {
   "consensusAddr": "0xc26A4c100ee6f4Bad187590F0Cd0C631C5cd713E",
   "feeAddr": "0xc26A4c100ee6f4Bad187590F0Cd0C631C5cd713E",
 },
 {
   "consensusAddr": "0xC638a422f2e0eB6705A1431577D572427f8e6B50",
   "feeAddr": "0xC638a422f2e0eB6705A1431577D572427f8e6B50",
 },
 {
   "consensusAddr": "0x248DF9f866b91aD5c31fB1bC0837B895176E8C3d",
   "feeAddr": "0x248DF9f866b91aD5c31fB1bC0837B895176E8C3d",
 },
 {
   "consensusAddr": "0x962eC2f3812E997Ae79caf7394A6CcCCe18eDf50",
   "feeAddr": "0x962eC2f3812E997Ae79caf7394A6CcCCe18eDf50",
 },
 {
   "consensusAddr": "0x3aC908b66407789460f45E4896E0165174d18dD9",
   "feeAddr": "0x3aC908b66407789460f45E4896E0165174d18dD9",
 },
 {
   "consensusAddr": "0x41124D7725985BD116A285F640083b515Ea4Fd05",
   "feeAddr": "0x41124D7725985BD116A285F640083b515Ea4Fd05",
 },
 {
   "consensusAddr": "0x37FFB7a65557FA772835b649D768Cd2d1FBE02D8",
   "feeAddr": "0x37FFB7a65557FA772835b649D768Cd2d1FBE02D8",
 },
 {
   "consensusAddr": "0x83e262E94d2f87366172A9842F12c08585c6A632",
   "feeAddr": "0x83e262E94d2f87366172A9842F12c08585c6A632",
 },
 {
   "consensusAddr": "0xFF77BAE4b7B8CF2AED5e25Da498D53FBb580E9C5",
   "feeAddr": "0xFF77BAE4b7B8CF2AED5e25Da498D53FBb580E9C5",
 },
 {
   "consensusAddr": "0x61DC3e72334F0608bea4f91ACa9541a0FdeDb531",
   "feeAddr": "0x61DC3e72334F0608bea4f91ACa9541a0FdeDb531",
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