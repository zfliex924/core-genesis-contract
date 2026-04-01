## 产品架构文档

### 一、系统概览

Z-Genesis-Contract 是基于 **Satoshi Plus** 共识机制的创世系统合约集。所有系统合约在创世区块中以固定地址部署，负责验证者选举、质押管理、奖励分配、治理投票和跨链轻客户端等核心功能。

Z Protocol 基于 Core Chain 架构，核心改造：
- **引入 Zcash 链资产质押**（ZecLightClient + ZecAgent）
- **移除 BTC 相关合约**（BtcLightClient、BitcoinAgent、BitcoinStake、PledgeAgent）
- **NativeAgent 重构**为按单笔质押（StakeTx）+ 时间等级倍率
- **StakeHub 简化**为固定 hardcap 比例奖励分配，移除 surplus/floatReward/candidateScoresMap
- **CandidateHub 重构**为 mapping 存储，Candidate 增加唯一 ID
- **Channel 重构**为纯 Delegator 模式
- **GradeManager**统一管理质押时长等级

### 二、合约地址分配

| 地址 | 合约 | 用途 |
|------|------|------|
| 0x1000 | ValidatorSet | 验证者集管理、出块奖励分配 |
| 0x1001 | SlashIndicator | 惩罚/监禁违规验证者 |
| 0x1002 | SystemReward | 系统激励资金池 |
| ~~0x1003~~ | ~~BtcLightClient~~ | ~~已移除~~ |
| 0x1004 | RelayerHub | 中继者注册 + 奖励管理 |
| 0x1005 | CandidateHub | 验证者候选人管理、turnRound 选举 |
| 0x1006 | GovHub | 链上治理投票 |
| ~~0x1007~~ | ~~PledgeAgent~~ | ~~已移除~~ |
| 0x0000 | BURN_ADDR | 代币销毁（零地址） |
| 0x1009 | Foundation | DAO 国库 |
| 0x1010 | StakeHub | 混合评分 & 固定比例奖励分配 |
| 0x1011 | NativeAgent | Native Token 质押（按单笔 StakeTx） |
| 0x1012 | HashPowerAgent | ZEC 算力质押 |
| ~~0x1013~~ | ~~BitcoinAgent~~ | ~~已移除~~ |
| ~~0x1014~~ | ~~BitcoinStake~~ | ~~已移除~~ |
| 0x1016 | Configuration | 事件奖励配置 |
| 0x1017 | Channel | 委托渠道（纯 Delegator 模式） |
| 0x1018 | ZecLightClient | Zcash 轻客户端 |
| 0x1019 | ZecAgent | ZEC 质押（CLTV + Dual Staking） |
| 0x101a | GradeManager | 共享质押时长等级管理 |

### 三、合约分层

```
┌──────────────────────────────────────────────────────────────┐
│                     治理层 (Governance)                       │
│  GovHub: 提案 → 投票 → 执行 → 调用各合约 updateParam()         │
└──────────────────────────────────────────────────────────────┘
                              │
┌──────────────────────────────────────────────────────────────┐
│                   验证者管理层 (Validator)                     │
│  CandidateHub: 候选人注册/退出、turnRound() 选举               │
│  ValidatorSet:  当选验证者集、出块奖励、惩罚执行                │
│  SlashIndicator: 不可用惩罚、双签举报                          │
└──────────────────────────────────────────────────────────────┘
                              │
┌──────────────────────────────────────────────────────────────┐
│                    质押中枢层 (Stake Hub)                      │
│  StakeHub: 管理 3 个 Agent, 混合评分, 固定 hardcap 比例分配    │
│  ┌──────────────┬──────────────────┬───────────────────────┐ │
│  │ NativeAgent  │ HashPowerAgent   │ ZecAgent              │ │
│  │ Native 质押  │ ZEC 算力质押      │ ZEC 质押 + Dual Stake │ │
│  └──────────────┴──────────────────┴───────────────────────┘ │
│  GradeManager: 共享质押时长等级（12 个梯度）                    │
└──────────────────────────────────────────────────────────────┘
                              │
┌──────────────────────────────────────────────────────────────┐
│                    跨链验证层 (Light Client)                   │
│  ZecLightClient: 存储 ZEC 块头、coinbase tx、算力追踪          │
│  (预编译合约 0x68: EquiHash / 0x69: Blake2b)                  │
└──────────────────────────────────────────────────────────────┘
                              │
┌──────────────────────────────────────────────────────────────┐
│                     基础设施层 (Infra)                         │
│  SystemReward: 激励资金池    RelayerHub: 中继者管理+奖励       │
│  Foundation: DAO 国库        Channel: 委托渠道（纯 Delegator） │
│  Configuration: 事件奖励配置                                   │
└──────────────────────────────────────────────────────────────┘
```

### 四、IAgent 接口规范

所有质押 Agent 实现统一的 `IAgent` 接口，由 StakeHub 统一调度：

```solidity
interface IAgent {
    function getStakeAmounts(address[] calldata candidates, uint256 round)
        external returns (uint256[] memory amounts, uint256 totalAmount);

    function setNewRound(address[] calldata validators, uint256 round) external;

    function distributeReward(address[] calldata validators, uint256[] calldata rewardList, uint256 round)
        external returns (uint256 undistributed);

    function claimReward(address delegator) external returns (uint256 reward);
}
```

**与 Core Chain 的关键简化**：
- `distributeReward` 增加 `undistributed` 返回值（未分配的奖励用于销毁）
- `claimReward` 移除 `coreAmount`、`settleRound`、`claim` 参数和 `floatReward` 返回值
- 各 Agent 内部用 `roundTag - 1` 计算结算轮次

### 五、StakeHub — 固定比例奖励分配

StakeHub 管理三类资产 Agent，按 **hardcap 固定比例**分配奖励：

| 资产 | Agent | Hardcap | 奖励占比 |
|------|-------|---------|---------|
| CORE | NativeAgent | 6000 | 6000/11000 ≈ 54.5% |
| Hash | HashPowerAgent | 2000 | 2000/11000 ≈ 18.2% |
| ZEC  | ZecAgent | 3000 | 3000/11000 ≈ 27.3% |

**评分（Hybrid Score）**：仅用于验证者选举，不再用于奖励分配
- 调用各 Agent 的 `getStakeAmounts()` 获取加权质押量
- 用 hardcap 计算转换因子
- 按总分排名选出验证者

**奖励分配**：
```
addRoundReward(validators, rewardList, roundTag):
  totalHardcap = Σ(assets[i].hardcap)
  for each asset:
    rewards[j] = rewardList[j] * hardcap / totalHardcap
    undistributed += agent.distributeReward(validators, rewards, roundTag)
  burn(undistributed)  // 未分配奖励销毁到 address(0)
```

**已移除**：
- `candidateScoresMap` — 不再用于奖励分配
- `surplus` / `floatReward` — 权重模型替代外部补贴
- `onStakeChange` / `calculateReward` / `delegatorMap` — 各 Agent 独立计算
- `claimCommission` — Channel 降为应用层

### 六、NativeAgent — 按单笔质押 + 时间等级

#### 6.1 数据模型

```solidity
struct StakeTx {
    address candidate;       // 质押的验证者
    address delegator;       // 质押人
    uint256 amount;          // 质押量
    uint256 round;           // 质押生效轮次
    uint256 lockUntilRound;  // 锁定到期轮次
    uint256 multiplier;      // 奖励倍率（delegate 时锁定）
    uint256 reward;          // 暂存奖励（transfer 时结算）
}

struct Candidate {
    uint256 stakedAmount;           // 快照
    uint256 realtimeAmount;         // 实时
    uint256 stakedWeightedAmount;   // 快照加权 Σ(amount × multiplier)
    uint256 realtimeWeightedAmount; // 实时加权
    uint256[] rewardEndRounds;
}
```

#### 6.2 接口

```
delegateCoin(candidate, lockRound) payable → bytes32 stakeId
  - lockRound 指定锁定轮数
  - multiplier 从 GradeManager.getMultiplier(lockRound) 获取并锁定
  - stakeId = bytes32(counter++)

requestUndelegate(stakeId)
  - 提交赎回申请，记录 undelegateRequestTime = block.timestamp
  - 每个 stakeId 只能申请一次

undelegateCoin(stakeId)
  - 要求已申请且 block.timestamp >= undelegateRequestTime + 72 hours
  - 锁定期已满（roundTag >= lockUntilRound）：按原始 multiplier 计算全额奖励
  - 提前退出：按最低倍率（DENOMINATOR = 1.0x）计算奖励
  - 发放本金 + 奖励

transferCoin(targetCandidate, stakeId)
  - 结算旧 candidate 奖励存入 stx.reward
  - 迁移到新 candidate

claimReward(delegator) → reward
  - 遍历 delegatorStakeIds，结算各笔奖励
```

#### 6.3 奖励计算

```
distributeReward:
  accruedReward += reward / stakedWeightedAmount

claimReward:
  reward = accruedDiff × amount × multiplier / CORE_STAKE_DECIMAL
```

高锁定等级的质押者在加权池中占更大份额，自然获得更高奖励。

### 七、ZecAgent — ZEC 质押 + Dual Staking

#### 7.1 质押流程

使用 CLTV 锁定交易（与 BitcoinStake 一致），仅允许 Relayer 提交：

```
delegate(zecTx, blockHeight, merkleProof, index, redeemScript):
  ├─ 验证 CLTV redeem script 格式
  ├─ ZecLightClient.checkTxProofAndGetTime() 验证 Merkle proof
  ├─ _parseVout() 提取质押金额、P2SH/P2WSH 匹配
  ├─ _parsePayload() 提取 delegator、candidate、version
  ├─ GradeManager.getMultiplier(lockDays) → 锁定 multiplier
  ├─ if version == SATOSHI_STAKE_CHANNEL_VERSION:
  │     delegator = CHANNEL_ADDR
  │     Channel.onZecStake(realDelegator, txid, candidate)
  ├─ 创建 ZecTx + DepositReceipt
  └─ 更新 CandidateState 加权量
```

#### 7.2 数据结构

```solidity
struct ZecTx {
    uint64 amount;           // ZEC 数量 (zatoshi)
    uint32 outputIndex;      // UTXO 输出索引
    uint64 blockTimestamp;   // 区块时间戳
    uint32 lockTime;         // CLTV locktime（绝对时间）
    uint32 usedHeight;       // UTXO 被花费的高度（0=未花费）
}

struct DepositReceipt {
    address candidate;       // 验证者
    address delegator;       // 质押人 EVM 地址
    uint256 round;           // 质押生效轮次
    uint256 multiplier;      // 时间倍率（delegate 时锁定）
    uint256 dualStakeAmount; // Dual Staking 的 Native Token 数量
    uint256 reward;          // 暂存奖励
}

struct CandidateState {
    uint256 stakedAmount;
    uint256 realtimeAmount;
    uint256 stakedWeightedAmount;   // Σ(amount × multiplier)
    uint256 realtimeWeightedAmount;
    uint256[] rewardEndRounds;
}
```

#### 7.3 Dual Staking

```
dualStake(txid) payable:
  - 锁定 Native Token 配对 ZEC 质押
  - 增加金额前结算历史奖励（旧倍率）
  - dr.dualStakeAmount += msg.value
  - 到期时自动退还 Native Token
```

奖励计算: `reward = base × timeMultiplier × dualMultiplier`

DualStakingGrade 默认配置：
| ratio (Native/ZEC) | multiplier |
|---------------------|-----------|
| 0 (无 dual stake)   | 1.0x      |
| >= 0.1              | 1.1x      |
| >= 0.2              | 1.3x      |
| >= 0.5              | 1.5x      |

### 八、GradeManager — 共享质押时长等级

NativeAgent 和 ZecAgent 共享同一套时长等级配置：

| 分级 | 天数 | 倍率 |
|------|------|------|
| Tier 1 | 1 | 100% |
| Tier 2 | 14 | 200% |
| Tier 3 | 30 | 300% |
| Tier 4 | 60 | 400% |
| Tier 5 | 90 | 500% |
| Tier 6 | 120 | 600% |
| Tier 7 | 150 | 700% |
| Tier 8 | 180 | 800% |
| Tier 9 | 210 | 850% |
| Tier 10 | 270 | 900% |
| Tier 11 | 330 | 950% |
| Tier 12 | 365 | 1000% |

- 治理通过 `updateParam("grades", RLP-encoded)` 更新
- 已有质押不受影响（multiplier 在 delegate 时锁定）

### 九、HashPowerAgent — ZEC 算力质押

从 ZecLightClient 读取矿工算力，按绑定比例分配奖励：

```
getStakeAmounts:
  → ZecLightClient.getRoundPowers() 获取算力
  → 记录 stakedRoundAmount（绑定算力）/ totalRoundAmount（总算力）

distributeReward:
  effectiveReward = reward × stakedRoundAmount / totalRoundAmount
  undistributed = reward - effectiveReward（销毁）
  avgReward = effectiveReward / minerSize（绑定矿工均分）
```

### 十、Channel — 纯 Delegator 模式

Channel 作为特殊 Delegator，用户通过 Channel 质押：

```
Native Token 质押:
  Channel.delegateCoin(candidate, partnerId, lockRound)
    → NativeAgent.delegateCoin(candidate, lockRound)
    → delegator = Channel 地址

  Channel.undelegateCoin(stakeId) → NativeAgent.undelegateCoin(stakeId)
  Channel.transferCoin(target, stakeId) → NativeAgent.transferCoin(target, stakeId)

ZEC 质押 (version == SATOSHI_STAKE_CHANNEL_VERSION):
  ZecAgent.delegate() → delegator = CHANNEL_ADDR
    → Channel.onZecStake(realDelegator, txid, candidate)
    → Channel 记录 zecStakeDelegator[txid] = realDelegator
```

### 十一、CandidateHub 改造

- **mapping 存储**：`mapping(address => Candidate) candidateMap` + `address[] candidateList`
- **合并 CandidateEx**：agent、voteAddr 直接在 Candidate struct 中
- **唯一 ID**：每个 Candidate 注册时分配 `uint32 id`，`idMap[id] → operateAddr`
- **移除**：数组索引管理、1-indexed operateMap/consensusMap

### 十二、ZecLightClient

参考 BtcLightClient，实现 Zcash 链轻客户端：

| 维度 | BtcLightClient（已移除） | ZecLightClient |
|------|------------------------|----------------|
| PoW 算法 | SHA256d | Equihash (预编译 0x68) |
| 哈希函数 | SHA256 | Blake2b (预编译 0x69) |
| 块头大小 | 80 bytes | 1487 bytes |
| 确认数 | 6 | 24 |
| 难度调整 | 每 2016 块 | 每块 |

Relayer 奖励已集中到 RelayerHub 管理（`recordHeaderSubmission`），不再在 LightClient 内部。

### 十三、RelayerHub — 中继者 + 奖励管理

Relayer 奖励逻辑从各 LightClient 集中到 RelayerHub：

- `recordHeaderSubmission(relayer)` — LightClient 调用
- `claimRelayerReward(relayer)` — 从 SystemReward 领取
- 奖励分配、权重计算统一管理
- `onlyLightClient` 修饰符限制调用方为 ZecLightClient
