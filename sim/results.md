# PoF 180-day simulation results

Populations: 60 honest agents, 1 sybil operator x 400 IDs, 30 small forecasters + 1 whale (1M EDGE stake). Seed 42.

| Day | Fresh emission | Honest solvers | Sybil IDs | Forecasters (whale / others) | Burned (unminted) | Rollover (EOD) | Bonds burned | Sybil share | Honest share |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 92,000 | 56,768 | 345 | 438 / 9,681 | 21,105 | 3,664 | 980 | 0.5% | 84.4% |
| 7 | 91,449 | 58,317 | 796 | 453 / 10,088 | 21,810 | 3,626 | 850 | 1.1% | 83.7% |
| 30 | 89,369 | 57,343 | 422 | 443 / 9,804 | 21,340 | 3,565 | 910 | 0.6% | 84.3% |
| 60 | 86,726 | 55,667 | 389 | 430 / 9,610 | 20,661 | 3,435 | 960 | 0.6% | 84.2% |
| 90 | 84,162 | 47,991 | 6,402 | 417 / 9,261 | 20,080 | 3,357 | 860 | 10.0% | 74.9% |
| 120 | 81,673 | 52,397 | 403 | 405 / 8,959 | 19,507 | 3,264 | 1,090 | 0.6% | 84.3% |
| 150 | 79,258 | 47,678 | 3,569 | 393 / 8,687 | 18,937 | 3,158 | 970 | 5.9% | 79.0% |
| 180 | 76,915 | 48,712 | 1,016 | 381 / 8,413 | 18,384 | 3,070 | 990 | 1.7% | 83.2% |

**180-day totals**

| Metric | EDGE | Share of rewards paid |
|---|---:|---:|
| Fresh emission | 15,162,061 | |
| Paid to honest solvers | 9,398,533 | 81.4% |
| Paid to sybil IDs (400) | 399,193 | 3.5% |
| Paid to whale forecaster | 75,099 | 0.7% |
| Paid to 30 small forecasters | 1,670,344 | 14.5% |
| Burned (never minted) | 3,615,821 | |
| Rollover left at day 180 | 3,070 | |
| Solver bonds burned | 170,080 | |
| Forecaster stake slashed | 9,233 | |
| Final sweet spot (log2 difficulty) | 10 | |
| Mean R honest / sybil | 0.70 / 0.29 | |
