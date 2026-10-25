# 链下出题器 + 参考解题 Agent

- `edge_gen/families.py` 三类题：子集和（NP）、排班约束、从例子反推程序（写 EVM 字节码）。难度 L = log2(链上 rung 难度)。
- `edge_gen/gen.py` 题目由 (出题器密钥, VRF 种子, 轮次, 级别) 确定性生成；出题器只需保存 32 字节密钥，揭晓时重新推导。最高级固定为“无提示程序合成”。
- `edge_gen/keeper.py` 自动推进：结算 → 开新轮 → 生成并用链上验证器自检 → 上链题目哈希 → 提交期结束后揭晓。
- `edge_gen/solver.py` 参考解题 Agent（非 AI 基线）：读题、求解、本地自检、提交押金、揭晓、领奖；出题器未揭晓时自动退押金。
- `tests/test_families.py` 离线 + 链上验证器自检：`python3 tests/test_families.py --onchain`
- `run_demo_round.py` 在快速测试实例上跑完整一轮。

依赖：`pip install eth-abi eth-utils`，Foundry `cast`。
测试网把题面以 data: URI 存链上；主网改为 IPFS。
