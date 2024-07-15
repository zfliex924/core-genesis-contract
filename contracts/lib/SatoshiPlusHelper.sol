// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

library SatoshiPlusHelper {
  // Protocol MAGIC `SAT+`, represents the short name for Satoshi plus protocol.
  uint256 public constant BTC_STAKE_MAGIC = 0x5341542b;
  uint256 public constant BTC_DECIMAL = 1e8;
  uint256 public constant CORE_DECIMAL = 1e18;
  uint256 public constant ROUND_INTERVAL = 86400;
  uint256 public constant CHAINID = 1112;

  // Bech32 encoded segwit addresses start with a human-readable part
  // (hrp) followed by '1'. For Bitcoin mainnet the hrp is "bc"(0x6263), and for
  // testnet it is "tb"(0x7462).
  uint256 public constant BECH32_HRP_SEGWIT = 0x6263;
}
