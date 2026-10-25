# PoF 180-day simulation results

Populations: 60 honest agents, 1 sybil operator x 400 IDs, 30 small forecasters + 1 whale (1M EDGE stake). Seed 42.

| Day | Fresh emission | Honest solvers | Sybil IDs | Forecasters (whale / others) | Burned (unminted) | Rollover (EOD) | Bonds burned | Sybil share | Honest share |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 92,000 | 39,067 | 3,090 | 494 / 11,032 | 34,867 | 3,451 | 740 | 5.8% | 72.8% |
| 7 | 91,449 | 18,874 | 659 | 606 / 13,584 | 58,886 | 8,466 | 440 | 2.0% | 56.0% |
| 30 | 89,369 | 20,415 | 389 | 571 / 12,805 | 54,336 | 9,592 | 330 | 1.1% | 59.7% |
| 60 | 86,726 | 16,970 | 1,964 | 551 / 12,267 | 52,949 | 9,502 | 390 | 6.2% | 53.4% |
| 90 | 84,162 | 23,677 | 296 | 538 / 11,926 | 49,024 | 8,204 | 560 | 0.8% | 65.0% |
| 120 | 81,673 | 24,941 | 476 | 515 / 11,453 | 45,713 | 7,473 | 590 | 1.3% | 66.7% |
| 150 | 79,258 | 15,132 | 4,873 | 505 / 11,240 | 47,278 | 9,443 | 550 | 15.3% | 47.7% |
| 180 | 76,915 | 14,935 | 306 | 499 / 10,983 | 48,995 | 8,184 | 410 | 1.1% | 55.9% |

**180-day totals**

| Metric | EDGE | Share of rewards paid |
|---|---:|---:|
| Fresh emission | 15,162,061 | |
| Paid to honest solvers | 3,382,481 | 57.5% |
| Paid to sybil IDs (400) | 232,837 | 4.0% |
| Paid to whale forecaster | 97,697 | 1.7% |
| Paid to 30 small forecasters | 2,170,534 | 36.9% |
| Burned (never minted) | 9,270,328 | |
| Rollover left at day 180 | 8,184 | |
| Solver bonds burned | 85,840 | |
| Forecaster stake slashed | 9,529 | |
| Final sweet spot (log2 difficulty) | 13 | |
| Mean R honest / sybil | 0.33 / 0.29 | |
