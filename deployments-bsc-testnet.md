# BSC Testnet (chainId 97) — v3.1, deployed 2026-10-25 21:02 CST
Deployer (testnet-only throwaway): 0xCd6820591b5D9B321af278A09947772548FCBE91
RPC: https://bsc-testnet-rpc.publicnode.com

v3.1 changes vs v3: crowding g()/bucket counts distinct solutions by headcount (reputation only splits the share);
ladder tops out at the sweet spot (top rung = frontier, difficulty halves going down).

| Contract | Address |
|---|---|
| Timelock (7d) | 0x89cb45268604dc2946f5f076bcd2cc8e78bf52b7 |
| EDGEToken | 0x50071e5a4eb6d161cfea1db65c5970473530ee40 |
| AirdropDistributor | 0x8cacf13c54abbafd57793ef5c21109f14874adb8 |
| IdentityGate (MockAgentGate) | 0x51966cc0406930b3aab617b09a4100738aa1537a |
| Randomness (MockRandomness) | 0x6867ef9b11c605581f16a19d595108f67e8d2037 |
| PoFEngine | 0x77a83d8f7570a1c0f958f2bc847772e9ff8a42b3 |
| SubsetSumVerifier | 0xf58b1b7005fa26495378def5216fdb6a592204f1 |
| ConstraintScheduleVerifier | 0x0f511c59edb9903bd7f5a6b719917a4dfb243f75 |
| ProgramIOVerifier | 0x08e0f70ea212431ca24cced23c154f48358bb0d5 |
| BountyBoard | 0xaec7dcfb51424e05e25cd1c3fb38dde49a99b340 |
| ForecastMarket | 0x4074bc0ad39f12bd945558a6d78d6fa3ca925e8e |
| FeeCollector | 0x0447ea45495d33ed1e534779a7e4442a06cd57b4 |

## Deprecated v3 deployment (round 1 demo ran here)
Timelock 0x9dCF9C3C1e1CbEcDF941ADf18A2bD5D73916DdFd, EDGEToken 0xCC5626591222f59De330f4757621B6e5a1b56635,
PoFEngine 0x495b7657575e4E317Bc5cA44daA10064982F5EE8, IdentityGate 0x44166791E52e8F2b64912Ee3Fc243e3873e57158,
BountyBoard 0xd3e90D517CBf161CDD18b4AC329E70B766625B33, ForecastMarket 0x4D0F8D260c797A885D9444801815ecd3028bb8f2,
FeeCollector 0x51391BFc441dc4C79D2A258203C1DaFab0B784Be, Airdrop 0x51Bb3f92B4E29EC4CcAC6E31cc8aE08e8DFA268c

## Sim (180 days, v3.1)
Emission 15,162,061 EDGE; honest solvers 81.4%, 400 sybil IDs 3.5%, small forecasters 14.5%, whale 0.7%; burned ~24% (v3: ~60%).
