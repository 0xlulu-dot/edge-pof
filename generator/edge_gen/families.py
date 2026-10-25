"""Puzzle families for the $EDGE PoF generator.

Every family:
  * is deterministic from a 32-byte `rnd` (derived from generator secret + VRF seed + rung),
  * scales with L = log2(on-chain rung difficulty),
  * plants a known solution so the generator can prove solvability before posting,
  * splits content into `public` (published in the puzzle URI before the commit window)
    and `params` (the ABI bytes bound by puzzleHash and revealed on-chain after commits).

Families
  subset_sum  (NP)                 public == params. n = 2L items, 2L-bit numbers (density ~1),
                                   meet-in-the-middle ~ 2^L work.
  schedule    (constraint model)   planted k-colouring + precedence + capacity + a few fixed slots;
                                   public == params.
  program_io  (program synthesis)  hidden straight-line function f(x) over uint256 with ~L-10 ops.
                                   public = 6 example I/O pairs + a natural-language hint at lower
                                   levels; params add 6 HIDDEN test vectors only revealed after the
                                   commit window, so agents must infer the rule, not memorise outputs.
                                   Answer = EVM runtime bytecode.
"""
from __future__ import annotations

import hashlib
import random
from dataclasses import dataclass, field

from eth_abi import encode

from .evm import compile_ops, run_ops

MASK = (1 << 256) - 1


@dataclass
class Puzzle:
    family: str
    level: int  # L = log2(difficulty)
    params: bytes  # exact ABI params for the on-chain verifier
    public: dict  # what solvers see during the commit window (goes into the URI)
    planted_answer: bytes  # ABI answer proving solvability (never published before reveal)
    meta: dict = field(default_factory=dict)


def _rng(rnd: bytes, tag: str) -> random.Random:
    return random.Random(hashlib.sha256(rnd + tag.encode()).digest())


# ------------------------------------------------------------------ subset sum
def subset_sum(rnd: bytes, L: int) -> Puzzle:
    r = _rng(rnd, "subset")
    n = max(8, min(64, 2 * L))  # verifier MAX_SET=256; keep gas sane
    bits = max(8, min(250, 2 * L))
    items = [r.randrange(1, 1 << bits) for _ in range(n)]
    k = n // 2
    idx = sorted(r.sample(range(n), k))
    target = sum(items[i] for i in idx)
    params = encode(["uint256[]", "uint256"], [items, target])
    ans = encode(["uint256[]"], [idx])
    pub = {"family": "subset_sum", "level": L,
           "task": "Pick a non-empty set of indices (strictly increasing) whose values sum exactly to target.",
           "set": [str(x) for x in items], "target": str(target),
           "answer_abi": "uint256[] indices"}
    return Puzzle("subset_sum", L, params, pub, ans, {"n": n, "bits": bits})


def verify_subset(params_set, target, idx) -> bool:
    if not idx or any(b <= a for a, b in zip(idx, idx[1:])) or idx[-1] >= len(params_set):
        return False
    return sum(params_set[i] for i in idx) == target


# ------------------------------------------------------------------ scheduling
def schedule(rnd: bytes, L: int) -> Puzzle:
    r = _rng(rnd, "schedule")
    nT = max(8, min(64, 3 * L))
    nS = 3 if L < 14 else 4
    slot = [r.randrange(nS) for _ in range(nT)]
    cs = []
    # conflicts near the hard colouring threshold (~2.3 n edges for k=3), only between different slots
    want_edges = int(nT * (2.2 if nS == 3 else 4.0))
    tries = 0
    edges = set()
    while len(edges) < want_edges and tries < want_edges * 20:
        tries += 1
        a, b = r.randrange(nT), r.randrange(nT)
        if a != b and slot[a] != slot[b] and (b, a) not in edges:
            edges.add((a, b))
    cs += [[0, a, b] for a, b in sorted(edges)]
    # precedences consistent with the plan
    for _ in range(nT // 4):
        a, b = r.randrange(nT), r.randrange(nT)
        if slot[a] < slot[b]:
            cs.append([1, a, b])
    # capacity: each slot at most its planted load (+0)
    for s in range(nS):
        cs.append([3, s, sum(1 for x in slot if x == s)])
    # a couple of fixed slots break symmetry
    for t in r.sample(range(nT), 2):
        cs.append([2, t, slot[t]])
    r.shuffle(cs)
    params = encode(["uint256", "uint256", "uint256[3][]"], [nT, nS, cs])
    ans = encode(["uint256[]"], [slot])
    pub = {"family": "schedule", "level": L,
           "task": ("Assign each task 0..numTasks-1 a slot 0..numSlots-1. Constraints [kind,a,b]: "
                    "0 CONFLICT slot[a]!=slot[b]; 1 PRECEDENCE slot[a]<slot[b]; 2 FIXED slot[a]==b; "
                    "3 CAPACITY at most b tasks in slot a."),
           "numTasks": nT, "numSlots": nS, "constraints": cs,
           "answer_abi": "uint256[] slotOfTask"}
    return Puzzle("schedule", L, params, pub, ans, {"constraints": len(cs)})


def verify_schedule(nT, nS, cs, slot) -> bool:
    if len(slot) != nT or any(s >= nS for s in slot):
        return False
    for k, a, b in cs:
        if k == 0 and slot[a] == slot[b]:
            return False
        if k == 1 and slot[a] >= slot[b]:
            return False
        if k == 2 and slot[a] != b:
            return False
        if k == 3 and sum(1 for s in slot if s == a) > b:
            return False
    return True


# ------------------------------------------------------------------ program synthesis
_OPS = ["ADD", "MUL", "XOR", "AND", "SHR", "SHL", "MOD", "SUB", "ADDX", "MULX", "XORX"]
_HINT = {"ADD": "add {c}", "MUL": "multiply by {c}", "XOR": "xor with {c}", "AND": "bitwise-and with {c}",
         "SHR": "shift right by {c} bits", "SHL": "shift left by {c} bits", "MOD": "take modulo {c}",
         "SUB": "subtract {c} (mod 2^256)", "ADDX": "add the original input", "MULX": "multiply by the original input",
         "XORX": "xor with the original input"}


def program_io(rnd: bytes, L: int, hint: bool | None = None) -> Puzzle:
    r = _rng(rnd, "program")
    n_ops = max(2, min(12, L - 10))
    ops = []
    for _ in range(n_ops):
        op = r.choice(_OPS)
        if op in ("SHR", "SHL"):
            c = r.randrange(1, 64)
        elif op == "MOD":
            c = r.randrange(2, 1 << r.choice([16, 32, 64]))
        elif op in ("ADDX", "MULX", "XORX"):
            c = 0
        else:
            c = r.randrange(1, 1 << r.choice([8, 16, 32, 64]))
        ops.append((op, c))
    xs = [r.randrange(0, 1 << r.choice([8, 32, 64, 128, 255])) for _ in range(12)]
    ys = [run_ops(ops, x) for x in xs]
    ins = [x.to_bytes(32, "big") for x in xs]
    outs = [y.to_bytes(32, "big") for y in ys]
    gas = 100_000
    params = encode(["bytes[]", "bytes[]", "uint256"], [ins, outs, gas])
    code = compile_ops(ops)
    # the verifier answer is the raw runtime bytecode itself (not ABI-wrapped)
    if hint is None:
        hint = L <= 13
    if hint:  # lower rungs: plain-language recipe given, the agent only has to write correct EVM code
        hint = "f(x): start with x, then " + ", then ".join(_HINT[o].format(c=c) for o, c in ops) + "."
    else:
        hint = None
    pub = {"family": "program_io", "level": L,
           "task": ("Write EVM runtime bytecode. It is STATICCALLed with calldata = 32-byte big-endian uint256 x and "
                    "must RETURN exactly 32 bytes = f(x) (all arithmetic mod 2^256). Infer f from the examples. "
                    f"6 more hidden vectors are revealed after the commit window. Gas cap per call {gas}."),
           "examples": [{"x": hex(x), "fx": hex(y)} for x, y in zip(xs[:6], ys[:6])],
           "hint": hint, "answer_abi": "raw bytes: EVM runtime code"}
    return Puzzle("program_io", L, params, pub, code, {"ops": ops})


FAMILIES = {"subset_sum": subset_sum, "schedule": schedule, "program_io": program_io}
