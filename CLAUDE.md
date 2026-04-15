# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the **Z Protocol genesis contract suite**, implementing the **Satoshi Plus hybrid consensus mechanism** (PoW + DPoS + ZEC staking). These system contracts initialize the blockchain and handle validators, staking, rewards, cross-chain relay, and governance.

## Commands

### Setup

```bash
npm install                                                      # Node dependencies
npm install -g ganache                                           # Required for tests
pip install -r requirements.txt                                  # Python test dependencies
brownie pm install OpenZeppelin/openzeppelin-contracts@4.9.6    # OpenZeppelin for brownie
```

### Testing

```bash
./generate-test-contracts.sh                  # Generate *Mock contracts before first run
brownie test -v --stateful false              # Run all tests
brownie test tests/<filename>.py -v          # Run single test file
brownie test -k <test_method_name> -v        # Run single test case
```

### Genesis Generation Pipeline

The full pipeline for generating `genesis.json`:

```bash
# Step 1: Edit configs/<network>.json (validators, holders, cycle params, zcash state)
# Step 2: Generate genesis (computes patches in memory, compiles contracts, renders template)
npm run generate-mainnet                     # → genesis.json for mainnet (chain ID 1116)
npm run generate-testnet                     # → genesis.json for testnet (chain ID 1115)
node generate-genesis.js --network devnet   # → genesis.json for devnet (chain ID 1112)
```

To inspect computed patches without generating genesis:

```bash
node genesis-config.js --network mainnet
```

### Patching Contract Constants Directly

```bash
node patch-contracts.js ContractName.CONSTANT_NAME=value
node patch-contracts.js ZcashLightClient.INIT_CHAIN_HEIGHT=1000
node patch-contracts.js ZcashLightClient.INIT_CONSENSUS_STATE_BYTES=hex:0000...
```

### ABI Generation

```bash
./generate-abi.sh                            # All contracts
./generate-abi.sh <ContractName>             # Single contract
```

## Architecture

### Contract Generation Pipeline

Contracts are **written directly in Solidity** in `contracts/`. Network-specific constants (chain IDs, validator sets, governance params, Zcash state) are injected at genesis time by `patch-contracts.js`, which does regex-based substitution of `constant NAME = VALUE` declarations in the `.sol` files.

The config source of truth is `configs/<network>.json`. `generate-genesis.js` calls `genesis-config.js` to compute patches in memory, applies them to the contracts, then compiles all contracts with `solc` and renders `genesis-template.json` with the resulting bytecodes.

### Core System Contracts

| Contract | Address | Role |
|---|---|---|
| `ValidatorSet.sol` | `0x1000` | Elected validator set; distributes block rewards each round |
| `SlashIndicator.sol` | `0x1001` | Tracks misbehavior; triggers jailing/slashing |
| `SystemReward.sol` | `0x1002` | Funds pool for relayers and verifiers |
| `RelayerHub.sol` | `0x1004` | Manages cross-chain relayers |
| `CandidateHub.sol` | `0x1005` | Candidate registration; orchestrates `turnRound` (epoch transition) |
| `GovHub.sol` | `0x1006` | On-chain governance votes |
| `Foundation.sol` | `0x1009` | DAO treasury controlled by governance |
| `StakeHub.sol` | `0x1010` | Calculates hybrid scores; manages reward distribution across agents |
| `NativeAgent.sol` | `0x1011` | CORE token staking (per-stake `StakeTx` records) |
| `HashPowerAgent.sol` | `0x1012` | Bitcoin hash power staking |
| `Channel.sol` | `0x1017` | Partner/channel delegator proxy; tracks commission and partner relationships |
| `ZcashLightClient.sol` | `0x1018` | Zcash light client for cross-chain verification |
| `ZecAgent.sol` | `0x1019` | ZEC staking; supports dual staking with CORE multiplier |
| `GradeManager.sol` | `0x101A` | Shared lock-duration and dual-staking ratio grade tables |

### Contract Wiring

All contracts inherit `System.sol`, which defines every peer's hardcoded address as a constant. `onlyCandidate`, `onlyValidator`, `onlyStakeHub`, etc. modifiers enforce caller identity. In tests, `set_system_contract_address` (auto-use fixture in `conftest.py`) wires deployed contracts together.

### Epoch / Turn-Round Flow

`CandidateHub.turnRound()` is called by the consensus engine at each epoch boundary. It calls `StakeHub` to distribute rewards to each agent (CORE, HASHPOWER, ZEC) by fixed hardcap ratios (6000 / 2000 / 3000 basis points), then elects the next validator set.

### Staking Agent Pattern

Each staking asset has an `IAgent`-implementing contract. `StakeHub` holds an `assets[]` list and a `stateMap` (agent → `AssetState{amount, factor}`) used to normalize different asset units for hybrid score calculation. Rewards flow: `ValidatorSet` → `StakeHub` → agent contracts → delegators.

### Channel / Partner System

`Channel.sol` acts as a delegator proxy for partners. Users who stake through a channel have their rewards routed through the channel, which deducts a commission before passing funds to the real delegator. ZEC staking records the `channelId` in the OP_RETURN output to link on-chain Zcash transactions to a partner.

### Genesis Config Structure (`configs/<network>.json`)

```json
{
  "chainId": 1116,
  "validators": [{ "consensusAddr": "0x...", "feeAddr": "0x..." }],
  "members": ["0x..."],      // GovHub initial members
  "holders": [],              // initial CORE token holders
  "cycle": { "blockPeriod": 3, "epochLength": 200, "roundInterval": 86400, "validatorCount": 21, "turnLength": 1 },
  "zcash": { "initConsensusStateBytes": "...", "initChainHeight": 1 },
  "gov": { "votingPeriod": 201600, "executingPeriod": 201600 }
}
```

### Chain IDs

- Mainnet: `1116`
- Testnet: `1115`
- Dev: `1112`

## Test Architecture

**Framework:** [Brownie](https://eth-brownie.readthedocs.io/) (Python, pytest-based), Solc `0.8.4`, ganache on port `8546`.

**Mock contracts:** `generate-test-contracts.sh` creates `*Mock` versions exposing `developmentInit()` so tests can inject initial state without a full genesis.

**Fixtures (`conftest.py`):**
- Session-scoped: library deployments (`BytesLib`, `Memory`, `RLPDecode`, etc.)
- Module-scoped: individual contract deployments (always deploy `*Mock` variants)
- `isolation` (auto-use): `fn_isolation` per test; `module_isolation` per module

**Test utilities:**
- `tests/common.py` — shared helpers (e.g. `register_candidate`)
- `tests/calc_reward.py` — off-chain reward calculation for assertions
- `tests/delegate.py` — delegation helpers
- `tests/constant.py` — shared constants
- `tests/scenario/` — complex multi-round scenarios (`chain_handler.py`, `chain_checker.py`, `scenario_generator.py`)
