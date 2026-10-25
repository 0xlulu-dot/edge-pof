#!/usr/bin/env python3
"""
$EDGE / PoF agent-based simulation (180 days).

Mirrors the on-chain rules in contracts/PoFEngine.sol + ForecastMarket.sol:
  * daily emission 92,000 * 0.999^day, 4h rounds (6/day), round pool = emission + rollover
  * 5 rungs, weight 2^r, difficulty doubles per rung, top rung = last sweet spot (v3.1)
  * 80% solvers / 20% forecasters; g(n) on distinct headcount n (v3.1): 0 | 0.7 | 1 | k/n ; k = clamp(sqrt(active)/10, 3, 30)
  * within rung split by reputation R; R in [0.1, 1], +0.05 distinct correct, -0.1 wrong,
    excess over 0.1 decays 1%/day when inactive
  * duplicate answers: only the first revealer counts; bond 10 EDGE burned on wrong answers
  * unpaid: 50% burned (never minted), 50% rolled into the next round
  * forecasters: Brier vs uniform baseline 0.75, weight sqrt(stake)*(baseline-brier),
    per-address cap 2% of total weight, worse-than-baseline -> 10% stake slashed

Populations
  * honest:  60 independent agents, skill ~ N(10, 1.5) (log2 difficulty units)
  * sybil:   one operator (skill 11) running 400 cheap IDs. It can solve a puzzle once and
             re-submit DISTINCT valid answers from different IDs, limited by how many distinct
             solutions a puzzle has (many on easy rungs, ~1 on frontier rungs).
  * forecasters: 30 small (1k-10k EDGE stake) + 1 whale (1,000,000 EDGE, very accurate)

Assumptions that are NOT on-chain facts are marked ASSUMPTION.
"""
import math
import os
import numpy as np

rng = np.random.default_rng(42)

DAYS = 180
ROUNDS_PER_DAY = 6
N_RUNGS = 5
BOND = 10.0
R_MIN, R_MAX, R_UP, R_DOWN, R_KEEP = 0.1, 1.0, 0.05, 0.1, 0.99
BASELINE = 0.75

# ASSUMPTION: distinct valid solutions per rung (subset-sum style: easy puzzles have many)
DISTINCT_SOLUTIONS = [64, 16, 4, 1, 1]

N_HONEST = 60
N_SYBIL = 400
honest_skill = rng.normal(10.0, 1.5, N_HONEST)
SYBIL_SKILL = 11.0
N_AGENTS = N_HONEST + N_SYBIL
is_sybil = np.array([False] * N_HONEST + [True] * N_SYBIL)
R = np.full(N_AGENTS, R_MIN)
active_today = np.zeros(N_AGENTS, bool)

# forecasters
N_SMALL_F = 30
f_stake = np.concatenate([rng.uniform(1_000, 10_000, N_SMALL_F), [1_000_000.0]])
f_skill = np.concatenate([rng.uniform(0.0, 0.6, N_SMALL_F), [0.9]])  # ASSUMPTION: accuracy
WHALE = N_SMALL_F


def p_solve(skill, level):
    """ASSUMPTION: logistic success curve in log2-difficulty units."""
    return 1.0 / (1.0 + np.exp(-2.0 * (skill - level)))


def k_for(active):
    return min(30, max(3, int(math.isqrt(active)) // 10))


def g(n_eff, k):
    if n_eff == 0:
        return 0.0
    if n_eff < 2:
        return 0.7
    if n_eff <= k:
        return 1.0
    return k / n_eff


def bucket(n_eff, k):
    if n_eff == 0:
        return 0
    if n_eff < 2:
        return 1
    if n_eff <= k:
        return 2
    return 3


rollover = 0.0
sweet = 10.0  # log2 difficulty of the middle rung
rows = []
tot = dict(fresh=0, honest=0, sybil=0, fc_whale=0, fc_small=0, burned=0, bonds=0, slashed=0)

for day in range(DAYS):
    daily = 92_000 * 0.999 ** day
    d = dict(day=day + 1, fresh=0.0, honest=0.0, sybil=0.0, fc_whale=0.0, fc_small=0.0,
             burned=0.0, bonds=0.0, slashed=0.0)
    active_today[:] = False
    for rnd in range(ROUNDS_PER_DAY):
        fresh = daily / ROUNDS_PER_DAY
        pool = fresh + rollover
        rollover = 0.0
        d["fresh"] += fresh
        solver_pool, f_pool = pool * 0.8, pool * 0.2
        levels = sweet + np.arange(N_RUNGS) - (N_RUNGS - 1)  # v3.1: top rung = sweet spot

        committed = np.zeros(N_AGENTS, bool)
        rung_payout = np.zeros(N_RUNGS)
        rung_neff = np.zeros(N_RUNGS)
        distinct_solvers = [[] for _ in range(N_RUNGS)]

        # --- sybil operator: solve once per rung, fan out distinct answers over IDs ---
        sybil_ids = np.where(is_sybil)[0]
        sybil_plan = {}
        cursor = 0
        for r in range(N_RUNGS):
            if rng.random() < p_solve(SYBIL_SKILL, levels[r]):
                n_ids = min(DISTINCT_SOLUTIONS[r], len(sybil_ids) - cursor)
                sybil_plan[r] = sybil_ids[cursor:cursor + n_ids]
                cursor += n_ids

        # --- honest agents attempt rungs where they expect >= 50% success ---
        attempts = []  # (agent, rung, correct, answer_id)
        for i in range(N_HONEST):
            for r in range(N_RUNGS):
                p = p_solve(honest_skill[i], levels[r])
                if p >= 0.5:
                    ok = rng.random() < p
                    attempts.append((i, r, ok, int(rng.integers(DISTINCT_SOLUTIONS[r])) if ok else -1))
        for r, ids in sybil_plan.items():
            # operator uses the distinct answers; honest agents may already hold some of them
            for j, a in enumerate(ids):
                attempts.append((int(a), r, True, j))

        for a, r, ok, ans in attempts:
            committed[a] = True
        active_ids = int(committed.sum())
        k = k_for(active_ids)

        order = rng.permutation(len(attempts))  # random reveal order
        seen = [set() for _ in range(N_RUNGS)]
        for idx in order:
            a, r, ok, ans = attempts[idx]
            active_today[a] = True
            if not ok:
                R[a] = max(R_MIN, R[a] - R_DOWN)
                d["bonds"] += BOND
                continue
            if ans in seen[r]:
                continue  # duplicate: bond back, nothing else
            seen[r].add(ans)
            distinct_solvers[r].append((a, R[a]))
            rung_neff[r] += R[a]
            R[a] = min(R_MAX, R[a] + R_UP)

        sumw = 2 ** N_RUNGS - 1
        paid = 0.0
        for r in range(N_RUNGS):
            share = solver_pool * (2 ** r) / sumw * g(len(distinct_solvers[r]), k)  # v3.1 headcount
            paid += share
            for a, ra in distinct_solvers[r]:
                amt = share * ra / rung_neff[r]
                if is_sybil[a]:
                    d["sybil"] += amt
                else:
                    d["honest"] += amt

        # --- forecasters ---
        outcome = [bucket(len(distinct_solvers[r]), k) for r in range(N_RUNGS)]
        weights = np.zeros(len(f_stake))
        for f in range(len(f_stake)):
            brier = 0.0
            for r in range(N_RUNGS):
                # ASSUMPTION: forecaster puts `skill` mass on the true bucket, rest uniform
                p = np.full(4, (1 - f_skill[f]) / 4)
                p[outcome[r]] += f_skill[f]
                p = np.clip(p + rng.normal(0, 0.05, 4), 0, None)
                p /= p.sum()
                o = np.zeros(4)
                o[outcome[r]] = 1
                brier += ((p - o) ** 2).sum()
            brier /= N_RUNGS
            if brier < BASELINE:
                weights[f] = math.sqrt(f_stake[f]) * (BASELINE - brier)
            elif brier > BASELINE:
                s = f_stake[f] * 0.10
                f_stake[f] -= s
                d["slashed"] += s
        tw = weights.sum()
        f_paid = 0.0
        if tw > 0:
            capped = np.minimum(weights, tw * 0.02)
            pay = f_pool * capped / tw
            f_paid = pay.sum()
            d["fc_whale"] += pay[WHALE]
            d["fc_small"] += pay[:WHALE].sum()

        unpaid = (solver_pool - paid) + (f_pool - f_paid)
        d["burned"] += unpaid / 2
        rollover += unpaid / 2

        # --- sweet spot update (mirrors _updateSweetSpot) ---
        top = N_RUNGS - 1
        if outcome[top] == 3:
            sweet = levels[top] + 1
        else:
            b2 = [r for r in range(N_RUNGS) if outcome[r] == 2]
            b1 = [r for r in range(N_RUNGS) if outcome[r] >= 1]
            if b2:
                sweet = levels[max(b2)]
            elif b1:
                sweet = levels[max(b1)]
            else:
                sweet -= 1

    # daily lazy decay for inactive IDs
    idle = ~active_today
    R[idle] = R_MIN + (R[idle] - R_MIN) * R_KEEP
    d["rollover_eod"] = rollover
    rows.append(d)
    for key in tot:
        tot[key] += d[key]

# ---------------------------------------------------------------- output
here = os.path.dirname(os.path.abspath(__file__))
paid_all = tot["honest"] + tot["sybil"] + tot["fc_whale"] + tot["fc_small"]


def fmt(x):
    return f"{x:,.0f}"


lines = ["# PoF 180-day simulation results", "",
         f"Populations: {N_HONEST} honest agents, 1 sybil operator x {N_SYBIL} IDs, "
         f"{N_SMALL_F} small forecasters + 1 whale (1M EDGE stake). Seed 42.", "",
         "| Day | Fresh emission | Honest solvers | Sybil IDs | Forecasters (whale / others) | Burned (unminted) | Rollover (EOD) | Bonds burned | Sybil share | Honest share |",
         "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
for d in rows:
    if d["day"] in (1, 7, 30, 60, 90, 120, 150, 180):
        p = d["honest"] + d["sybil"] + d["fc_whale"] + d["fc_small"]
        lines.append(f"| {d['day']} | {fmt(d['fresh'])} | {fmt(d['honest'])} | {fmt(d['sybil'])} | "
                     f"{fmt(d['fc_whale'])} / {fmt(d['fc_small'])} | {fmt(d['burned'])} | {fmt(d['rollover_eod'])} | "
                     f"{fmt(d['bonds'])} | {d['sybil'] / p:.1%} | {d['honest'] / p:.1%} |")
lines += ["", "**180-day totals**", "",
          "| Metric | EDGE | Share of rewards paid |", "|---|---:|---:|",
          f"| Fresh emission | {fmt(tot['fresh'])} | |",
          f"| Paid to honest solvers | {fmt(tot['honest'])} | {tot['honest'] / paid_all:.1%} |",
          f"| Paid to sybil IDs (400) | {fmt(tot['sybil'])} | {tot['sybil'] / paid_all:.1%} |",
          f"| Paid to whale forecaster | {fmt(tot['fc_whale'])} | {tot['fc_whale'] / paid_all:.1%} |",
          f"| Paid to 30 small forecasters | {fmt(tot['fc_small'])} | {tot['fc_small'] / paid_all:.1%} |",
          f"| Burned (never minted) | {fmt(tot['burned'])} | |",
          f"| Rollover left at day 180 | {fmt(rows[-1]['rollover_eod'])} | |",
          f"| Solver bonds burned | {fmt(tot['bonds'])} | |",
          f"| Forecaster stake slashed | {fmt(tot['slashed'])} | |",
          f"| Final sweet spot (log2 difficulty) | {sweet:.0f} | |",
          f"| Mean R honest / sybil | {R[~is_sybil].mean():.2f} / {R[is_sybil].mean():.2f} | |",
          ""]
open(os.path.join(here, "results.md"), "w").write("\n".join(lines))
print("\n".join(lines))

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

days = [d["day"] for d in rows]
fig, axes = plt.subplots(1, 2, figsize=(13, 4.8))
ax = axes[0]
ax.plot(days, [d["fresh"] for d in rows], label="fresh emission", color="black", lw=2)
ax.plot(days, [d["honest"] for d in rows], label="honest solvers")
ax.plot(days, [d["sybil"] for d in rows], label="sybil IDs (400)")
ax.plot(days, [d["fc_whale"] + d["fc_small"] for d in rows], label="forecasters")
ax.plot(days, [d["burned"] for d in rows], label="burned (unminted)", ls="--")
ax.plot(days, [d["rollover_eod"] for d in rows], label="rollover (end of day)", ls=":")
ax.set_title("Daily EDGE flows")
ax.set_xlabel("day")
ax.set_ylabel("EDGE / day")
ax.legend(fontsize=8, loc="center right")
ax.grid(alpha=0.3)

ax = axes[1]
def share(key):
    out = []
    for d in rows:
        p = d["honest"] + d["sybil"] + d["fc_whale"] + d["fc_small"]
        out.append(d[key] / p if p else 0)
    return out
ax.stackplot(days, share("honest"), share("sybil"), share("fc_small"), share("fc_whale"),
             labels=["honest", "sybil", "small forecasters", "whale forecaster"], alpha=0.85)
ax.set_ylim(0, 1)
ax.set_title("Share of rewards paid")
ax.set_xlabel("day")
ax.legend(fontsize=8, loc="lower right")
ax.grid(alpha=0.3)
fig.tight_layout()
fig.savefig(os.path.join(here, "results.png"), dpi=120)
print("wrote sim/results.md and sim/results.png")
