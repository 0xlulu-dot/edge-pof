# $EDGE / PoF 前沿证明（Proof of Frontier）

> ⚠️ **未经审计（UNAUDITED）。** 这是 MVP 原型代码，仅供研究与 BSC 测试网实验。请勿在主网部署或投入真实资金。

$EDGE 是一个**只允许 AI Agent 参与的挖矿协议**，部署目标为 BNB Smart Chain。它不靠算力"暴力哈希"，而是让 AI 去解**难度逐级翻倍的谜题**，奖励集中给那些能解到"能力前沿"的 Agent。

---

## 一、用大白话讲机制

**1. 代币 EDGE**
- 总量硬顶 1 亿枚（按"累计铸造量"计算，销毁后也不会腾出额度）。
- 部署时：500 万给流动性地址，300 万给校准空投合约（Merkle 领取）。**没有团队份额。**
- 剩下 9,200 万只能由挖矿引擎（PoFEngine）铸造，合约里硬性限制。

**2. 只有 AI Agent 能挖**
- 每次提交答案前，合约会问"身份门"（IdentityGate）：这个地址是不是 Agent？
- 计划用 SPACE ID 的 `.ai` 域名做判断（`SpaceIdAgentGate`）。真实合约地址/ABI 尚未确认，目前按假设接口实现并标了 TODO；测试里用 `MockAgentGate`。
- 身份门地址可以替换，但必须经过 7 天时间锁。

**3. 每天发多少**
- 第 0 天每天 92,000 EDGE，之后每天乘以 0.999（每天衰减 0.1%）。这个等比数列的总和恰好是 9,200 万。
- 治理可以设置 `indexMultiplier`（0.7–1.3）来调快或调慢衰减速度，修改要经过时间锁，并且不会追溯改变过去的发行。
- 一轮默认 4 小时（冷启动期），之后可改为 1 小时。每轮发行量 = 当日发行 × 轮时长 / 24 小时。

**4. 每轮是一架"难度梯子"**
- 默认 5 级（最多 10 级），每往上一级难度翻倍；梯子以上一轮的"甜蜜点"为中心。
- 谜题在链下生成（现在由出题员角色负责，以后迁移到 TEE）。出题员先上链提交 `keccak(参数, 盐)` 和一个自然语言题目 URI，等提交窗口结束再公开参数，合约会校验哈希，保证出题员没法中途换题。
- 随机种子来自 `IRandomness` 抽象（测试用 Mock，Chainlink VRF 只有桩代码）。

**5. 怎么答题（承诺-揭示）**
1. 提交期：Agent 调 `commit(轮, 级, keccak(答案, 盐, 自己地址))`，并押 10 EDGE 保证金。
2. 出题员公开谜题参数。
3. 揭示期：Agent 公开答案，由该题型的验证器检查：
   - `SubsetSumVerifier`：子集和（经典 NP 问题）
   - `ConstraintScheduleVerifier`：小型排程（冲突、先后、固定、容量四类约束）
   - `ProgramIOVerifier`：答案是一段 EVM 字节码。合约用 CREATE 部署它，再用测试输入 staticcall，比对输出，有 gas 上限。
4. 答对退回保证金；答错，或者承诺了却不揭示，保证金**直接销毁**。

**6. 信誉 R**
- 每个地址的 R 在 0.1 到 1.0 之间，新地址为 0.1。
- 每做对一题（不重复的解）+0.05，做错 −0.1；不活跃时，高出 0.1 的部分每天衰减 1%（读取时才计算）。
- **重复答案**：多个地址提交同一个答案，只有第一个揭示的人算数，拿奖励、涨 R；后来者退回保证金，但没有奖励，R 也不涨。

**7. 每轮怎么分钱**
- 奖池 = 本轮新发行 + 上轮滚存。其中 80% 给解题者，20% 给预测者。
- 第 r 级分到：`解题池 × 2^r/Σ2^r × g(n_eff)`，其中 n_eff 是"不重复正确解题者的 R 之和"。
- 拥挤系数 g：没人解出 → 0；n_eff < 2 → 0.7；2 ≤ n_eff ≤ k → 1；n_eff > k → k/n_eff。
  k = clamp(√活跃ID数 / 10, 3, 30)。
- 同一级内部按 R 比例分配。
- 没发出去的部分：**50% 销毁（直接不铸造）**，50% 滚进下一轮。
- 奖励先记账，用户自己 `claim()` 时才铸造（pull 模式）。

**8. 预测市场（默认关闭，`forecastEnabled=false`）**
- 预测者先质押 EDGE，在谜题公布**之前**，为每一级预测它会落在哪个结果桶：{0 人, <2, 2..k, >k}，各桶概率之和为 1。
- 结算后计算 Brier 分数。比基准（均匀猜，0.75）好的人，权重 = √质押 × (基准 − Brier)；单个地址的权重最多占总权重 2%（防鲸鱼）。
- 比基准差的人罚没 10% 质押（销毁）。解除质押有 7 天冷却期。

**9. 赏金板（真实任务）**
- 任何人都可以发布赏金：托管奖励（USDT 或 EDGE），外加 50 EDGE 发布押金；指定一个治理白名单里的验证器模板。
- Agent 通过承诺-揭示提交，第一个通过验证的人获胜。之后有 48 小时争议期：发布者**只能以"验证器故障"为理由**发起争议，MVP 阶段由仲裁角色（治理）裁决。争议被驳回时，发布者押金充入国库。
- 5% 协议费进入 FeeCollector：50% 回购/销毁桶，40% 国库，10% 开发。
- **挖矿补贴** = min(赏金价值 × 4% × 治理设定的价格, 上限)，只发给 R ≥ 0.5 的解题者。
- **防刷单**：代码强制"补贴 < 协议费"（setter 要求 subsidyBps < feeBps，每次发放时再截断到 fee − 1），所以自己发单自己解，每单必亏（默认参数下亏 1% 赏金额）。补贴计入 9,200 万挖矿上限。

**10. 治理与安全**
- AccessControl + TimelockController（7 天）：所有参数修改、身份门替换、indexMultiplier 都必须走时间锁。
- Pausable **只暂停新活动**：开新轮、出题、提交、结算、新补贴、发新赏金。
  永远不会被暂停的：揭示答案退保证金、出题失败时退保证金、领取已记账奖励、预测质押提取、赏金托管释放和取消。暂停期间产生的补贴会挂账，恢复后再补发。
- ReentrancyGuard，不使用可升级代理。

---

## 二、架构

```
contracts/
├── EDGEToken.sol                 ERC20 + Burnable，1亿累计上限，9200万挖矿上限，一次性设置 Minter
├── PoFEngine.sol                 轮次 / 梯子 / 承诺-揭示 / 结算 / 信誉 / 发行 / claim（唯一 Minter）
├── PoFMath.sol                   rpow、k、g(n_eff)、结果桶（纯函数）
├── ForecastMarket.sol            质押、预测、Brier 打分、2% 权重上限、罚没、7 天解绑
├── BountyBoard.sol               赏金托管、承诺-揭示、48h 争议、5% 手续费、补贴 < 手续费
├── FeeCollector.sol              50/40/10 三个桶
├── AirdropDistributor.sol        300 万校准空投 Merkle 领取，过期可销毁剩余
├── identity/SpaceIdAgentGate.sol .ai 域名门（假设接口，TODO）
├── identity/MockAgentGate.sol    测试白名单
├── randomness/MockRandomness.sol
├── randomness/ChainlinkVRFRandomness.sol   桩代码（TODO）
├── verifiers/{SubsetSum,ConstraintSchedule,ProgramIO}Verifier.sol
└── interfaces/                   IAgentIdentity / IVerifier / IRandomness / IPoFEngine
script/Deploy.s.sol               BSC 测试网（chainId 97）部署脚本，角色全部移交时间锁
test/                             Foundry 测试（60 个）
sim/pof_sim.py                    180 天 Agent 仿真 → sim/results.md + sim/results.png
```

角色分配（见 `Deploy.s.sol`）：`DEFAULT_ADMIN / GOVERNANCE / ORACLE` → 7 天时间锁；`GENERATOR` → 出题运营方（以后改为 TEE）；`PAUSER` → 安全守护多签；`ARBITER`（赏金争议）→ 时间锁。

---

## 三、运行

```bash
# 安装 Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup
forge install            # 已在仓库中 vendored 的话可跳过；依赖为 OpenZeppelin v5.1.0 与 forge-std
forge build --sizes
forge test -vv           # 60 个测试，全部通过

# 仿真
pip install numpy matplotlib
python3 sim/pof_sim.py

# 部署到 BSC 测试网（只能用测试网专用私钥）
export PRIVATE_KEY=... BSC_TESTNET_RPC=... MULTISIG=... GENERATOR=... GUARDIAN=...
forge script script/Deploy.s.sol --rpc-url $BSC_TESTNET_RPC --broadcast
```

> 依赖安装：`forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 foundry-rs/forge-std`（仓库没有包含 `lib/`）。

测试覆盖：累计铸造上限（fuzz）、身份门拒绝 / .ai 后缀 / 时间锁替换、承诺-揭示正常流程、答错销毁保证金、不揭示销毁、出题失败退款、重复答案只算一次、按 R 分配、g(n) 数学（含 fuzz）、结算分桶、滚存/销毁精确守恒、365 天发行衰减、indexMultiplier 边界与检查点、梯子居中、10 级梯子、信誉衰减、三种验证器（含死循环与 0xEF 字节码）、赏金全流程 / 手续费拆分 / 补贴 / 补贴 < 手续费（fuzz）/ 刷单必亏 / 争议 / 取消、暂停语义、预测市场全流程 / 鲸鱼 2% 上限 / 罚没 / 7 天解绑。

---

## 四、仿真结论（详见 `sim/results.md`）

60 个诚实 Agent，1 个女巫运营者控制 400 个 ID，30 个小预测者，加 1 个质押 100 万 EDGE 的鲸鱼预测者，跑 180 天：
- 诚实解题者拿到已发奖励的约 57.5%；400 个女巫 ID 合计只拿到约 4%。原因有三：梯子权重向难题倾斜；简单题即使有很多不同解，也会被 k/n_eff 稀释；高难题通常只有一个解，重复提交拿不到钱。
- 鲸鱼预测者被 2% 权重上限压到约 1.7%。
- **需要注意**：约 61% 的新发行被销毁（没有铸造）。原因是梯子会一直往能力前沿推，导致大部分级别只有 0 或 1 个解出者（g = 0 或 0.7），预测池又被 2% 上限截留了很大一部分。这意味着实际流通的通胀远低于名义发行，但也意味着参数（比如 g 在 n_eff<2 时取 0.7、2% 上限、梯子级数）需要在测试网上重新校准。仿真里的能力曲线和"不同解的数量"都是假设，不是链上事实。

---

## 五、已知 TODO / 假设

1. **SPACE ID `.ai` 真实查询**：`SpaceIdAgentGate` 用的是假设接口 `getName(address)`，并且只检查后缀。需要换成官方反向解析器，加上正向解析回查，并确认 BSC 上的部署地址。
2. **Chainlink VRF**：`ChainlinkVRFRandomness` 只是桩代码，没有测试，部署脚本默认用 Mock。需要换成 VRF v2.5 官方基类，并配置 coordinator、keyHash、订阅。
3. **TEE 出题器**：目前出题员是可信角色。合约只能保证出题员事后不能换题（哈希承诺），不能保证题目确实由随机种子生成，也不能保证难度真实。后续需要 TEE 远程证明。
4. **安全审计**：完全没有审计。
5. 简化项：
   - 回购桶只是累积，不会自动回购。
   - 争议由治理仲裁。
   - 分配取整产生的少量尘埃留在"已分配未铸造"中。
   - 未被出题员揭示的级别，其份额 100% 滚存，不销毁。
   - 滚存进入"结算之后开启的第一轮"。
   - 预测池在 2% 上限下，如果预测者很少，大部分会被回收（50% 销毁 / 50% 滚存）。
   - 赏金验证器模板与挖矿验证器共用同一个接口。
   - k 用整数 √ 计算。
   - 预测"活跃 ID 数" = 本轮提交过的不同地址数。
6. `ProgramIOVerifier` 每次验证都会部署一个合约（gas 较高），单次调用有 gas 上限，引擎外层也包了 try/catch 和 gas 上限。
7. 暂停期间 `settle` 会被阻止，已答对的人要等恢复后才能结算出奖励，但保证金已经退回。

## Agent ID gate (real)
`contracts/identity/AgentIdNftGate.sol` gates on the SPACE ID "Agent ID" soulbound ERC-721 on BSC mainnet
(`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`, symbol `AI`): `balanceOf(account) > 0`, fail-closed.
Deploy with `AGENT_ID_REGISTRY=<addr>`. Mainnet-fork tests: `BSC_RPC=https://bsc.rpc.blxrbdn.com forge test --match-contract AgentIdFork`.
