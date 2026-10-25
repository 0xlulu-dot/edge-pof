"""Reference solver agent (a baseline, NOT an AI): shows the full agent loop an SDK user implements.

  read puzzle URIs -> solve what it can (time-boxed) -> self-verify -> commit with 10 EDGE bond
  -> after the generator reveals, reveal answers -> claim rewards after settlement

It solves subset_sum (meet-in-the-middle) and schedule (backtracking). For program_io it only
handles rungs whose statement carries a plain-language hint (a stand-in for an LLM reading the
spec); hint-free program synthesis is left to real AI agents - that is the frontier.
"""
from __future__ import annotations

import json
import os
import random
import re
import sys
import time

from eth_abi import encode
from eth_utils import keccak

from . import chain
from .evm import compile_ops, run_ops
from .families import verify_schedule, verify_subset
from .gen import from_uri


# ------------------------------------------------------------------ solvers
def solve_subset(pub, rng, budget):
    vals = [int(x) for x in pub["set"]]
    target = int(pub["target"])
    n = len(vals)
    if n > 44:
        return None
    order = list(range(n))
    rng.shuffle(order)  # different agents tend to find different valid answers
    A, B = order[: n // 2], order[n // 2:]
    t0 = time.time()

    def sums(ix):
        out = {0: 0}
        for j, i in enumerate(ix):
            if time.time() - t0 > budget:
                raise TimeoutError
            v = vals[i]
            out.update({s + v: m | (1 << j) for s, m in list(out.items())})
        return out
    try:
        left, right = sums(A), sums(B)
    except TimeoutError:
        return None
    for s, m in left.items():
        mr = right.get(target - s)
        if mr is not None and (m or mr):
            idx = sorted([A[j] for j in range(len(A)) if m >> j & 1] + [B[j] for j in range(len(B)) if mr >> j & 1])
            if verify_subset(vals, target, idx):
                return encode(["uint256[]"], [idx])
    return None


def solve_schedule(pub, rng, budget):
    nT, nS, cs = pub["numTasks"], pub["numSlots"], pub["constraints"]
    fixed = {a: b for k, a, b in cs if k == 2}
    cap = {a: b for k, a, b in cs if k == 3}
    nbr = [set() for _ in range(nT)]
    before, after = [[] for _ in range(nT)], [[] for _ in range(nT)]
    for k, a, b in cs:
        if k == 0:
            nbr[a].add(b), nbr[b].add(a)
        elif k == 1:
            after[a].append(b), before[b].append(a)
    slot = [-1] * nT
    load = [0] * nS
    t0 = time.time()

    def options(t):
        if t in fixed:
            cand = [fixed[t]]
        else:
            cand = list(range(nS))
        res = []
        for s in cand:
            if load[s] >= cap.get(s, nT):
                continue
            if any(slot[u] == s for u in nbr[t]):
                continue
            if any(slot[u] != -1 and slot[u] >= s for u in before[t]):
                continue
            if any(slot[u] != -1 and slot[u] <= s for u in after[t]):
                continue
            res.append(s)
        return res

    def bt(depth):
        if time.time() - t0 > budget:
            raise TimeoutError
        if depth == nT:
            return True
        free = [t for t in range(nT) if slot[t] == -1]
        t = min(free, key=lambda x: (len(options(x)), -len(nbr[x])))
        opts = options(t)
        rng.shuffle(opts)
        for s in opts:
            slot[t] = s
            load[s] += 1
            if bt(depth + 1):
                return True
            slot[t] = -1
            load[s] -= 1
        return False
    try:
        if bt(0) and verify_schedule(nT, nS, cs, slot):
            return encode(["uint256[]"], [slot])
    except TimeoutError:
        pass
    return None


_HINT_RE = [(r"^add the original input$", "ADDX", None), (r"^multiply by the original input$", "MULX", None),
            (r"^xor with the original input$", "XORX", None), (r"^add (\d+)$", "ADD", 1),
            (r"^multiply by (\d+)$", "MUL", 1), (r"^xor with (\d+)$", "XOR", 1), (r"^bitwise-and with (\d+)$", "AND", 1),
            (r"^shift right by (\d+) bits$", "SHR", 1), (r"^shift left by (\d+) bits$", "SHL", 1),
            (r"^take modulo (\d+)$", "MOD", 1), (r"^subtract (\d+) \(mod 2\^256\)$", "SUB", 1)]


def solve_program(pub, rng, budget):
    hint = pub.get("hint")
    if not hint:
        return None  # frontier: needs a real program-synthesis agent
    body = hint.removeprefix("f(x): start with x, then ").rstrip(".")
    ops = []
    for step in body.split(", then "):
        for pat, op, g in _HINT_RE:
            m = re.match(pat, step)
            if m:
                ops.append((op, int(m.group(g)) if g else 0))
                break
        else:
            return None
    for ex in pub["examples"]:
        if run_ops(ops, int(ex["x"], 16)) != int(ex["fx"], 16):
            return None
    return compile_ops(ops)


SOLVERS = {"subset_sum": solve_subset, "schedule": solve_schedule, "program_io": solve_program}


# ------------------------------------------------------------------ agent loop
class Agent:
    def __init__(self, eng: chain.Engine, addr: str, pk: str, state_file: str, seed: int, budget: float):
        self.eng, self.addr, self.pk, self.f = eng, addr, pk, state_file
        self.rng = random.Random(seed)
        self.budget = budget
        self.st = json.load(open(state_file)) if os.path.exists(state_file) else {}

    def save(self):
        json.dump(self.st, open(self.f, "w"))
        os.chmod(self.f, 0o600)

    def commit_round(self, rid: int, rungs: int):
        done = self.st.setdefault(str(rid), {})
        for k in range(rungs):
            if str(k) in done:
                continue
            pub = from_uri(self.eng.uri(rid, k))
            ans = SOLVERS[pub["family"]](pub, self.rng, self.budget)
            if ans is None:
                done[str(k)] = {"skip": pub["family"]}
                continue
            salt = os.urandom(32)
            c = keccak(encode(["bytes", "bytes32", "address"], [ans, salt, self.addr]))
            chain.send(self.pk, self.eng.a, "commit(uint256,uint8,bytes32)", rid, k, "0x" + c.hex())
            done[str(k)] = {"family": pub["family"], "answer": ans.hex(), "salt": salt.hex()}
            self.save()
        self.save()

    def reveal_round(self, rid: int):
        for k, d in self.st.get(str(rid), {}).items():
            if "answer" not in d or d.get("revealed") or not self.eng.rung(rid, int(k))["revealed"]:
                continue
            chain.send(self.pk, self.eng.a, "revealAnswer(uint256,uint8,bytes,bytes32)", rid, int(k),
                       "0x" + d["answer"], "0x" + d["salt"], gas_limit=5_000_000)
            d["revealed"] = True
            self.save()

    def claim_round(self, rid: int):
        for k, d in self.st.get(str(rid), {}).items():
            if "answer" in d and not d.get("revealed") and not d.get("refunded") and not self.eng.rung(rid, int(k))["revealed"]:
                # generator never revealed this puzzle: not the agent's fault, bond comes back in full
                chain.send(self.pk, self.eng.a, "refundBond(uint256,uint8)", rid, int(k))
                d["refunded"] = True
                continue
            if d.get("revealed") and not d.get("accrued"):
                amt = chain.i(chain.call(self.eng.a, "claimable(uint256,uint8,address)(uint256)", rid, int(k), self.addr)[0])
                if amt:
                    chain.send(self.pk, self.eng.a, "accrueSolver(uint256,uint8,address)", rid, int(k), self.addr)
                d["accrued"] = True
        if chain.i(chain.call(self.eng.a, "pendingRewards(address)(uint256)", self.addr)[0]):
            chain.send(self.pk, self.eng.a, "claim()")
        self.save()


if __name__ == "__main__":
    # quick offline benchmark: python3 -m edge_gen.solver bench
    from .families import FAMILIES
    if sys.argv[1:] == ["bench"]:
        for L in (10, 12, 14, 16, 18):
            row = []
            for fam, fn in FAMILIES.items():
                ok = 0
                t0 = time.time()
                for s in range(5):
                    p = fn(bytes([s, L]) * 16, L)
                    ok += SOLVERS[fam](p.public, random.Random(s), 5.0) is not None
                row.append(f"{fam}={ok}/5 ({time.time() - t0:.1f}s)")
            print(f"L={L}: " + "  ".join(row))
