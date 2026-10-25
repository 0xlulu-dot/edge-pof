"""Generator / keeper: one idempotent `tick()` moves the protocol forward.

    settle finished round -> start next round -> generate + self-check + post puzzles
    -> (after commit window) reveal puzzles

Env: ENGINE, GEN_PK (GENERATOR_ROLE key), GEN_SECRET_FILE (32-byte hex secret).
Run `python3 -m edge_gen.keeper loop` under a process supervisor; every action is safe to retry.
"""
from __future__ import annotations

import json
import os
import sys
import time

from . import chain
from .gen import make, puzzle_hash, to_uri


def _secret() -> bytes:
    path = os.environ["GEN_SECRET_FILE"]
    if not os.path.exists(path):
        with open(path, "w") as f:
            f.write(os.urandom(32).hex())
        os.chmod(path, 0o600)
    return bytes.fromhex(open(path).read().strip())


def log(**kw):
    print(json.dumps(kw), flush=True)


def build(eng: chain.Engine, rid: int, rd: dict, seed: int, secret: bytes, verifiers: dict):
    out = []
    for k in range(rd["numRungs"]):
        diff = eng.rung(rid, k)["difficulty"]
        p, salt = make(secret, seed, rid, k, diff, rd["numRungs"])
        v = verifiers[p.family]
        # self-check against the real on-chain verifier BEFORE committing to the puzzle
        ok = chain.call(v, "verify(bytes,bytes)(bool)", "0x" + p.params.hex(), "0x" + p.planted_answer.hex())[0]
        if ok != "true":
            raise RuntimeError(f"self-check failed rung {k} {p.family}")
        out.append((k, p, salt, v))
    return out


def tick(eng: chain.Engine, pk: str, verifiers: dict) -> str:
    secret = _secret()
    t = chain.now()
    rid = eng.round_count()
    if rid > 0:
        rd = eng.round(rid)
        tm = eng.times(rid)
        if t >= tm["roundEnd"]:
            if not rd["settled"]:
                chain.send(pk, eng.a, "settle(uint256)", rid)
                log(action="settle", round=rid)
                return "settled"
        else:
            if not rd["puzzlesPosted"] and t < tm["commitEnd"]:
                ready, seed = eng.seed(rid)
                if not ready:
                    return "waiting-seed"
                ps = build(eng, rid, rd, seed, secret, verifiers)
                hashes = "[" + ",".join("0x" + puzzle_hash(p.params, s).hex() for _, p, s, _ in ps) + "]"
                vers = "[" + ",".join(v for *_, v in ps) + "]"
                uris = "[" + ",".join(json.dumps(to_uri(p, rid, k)) for k, p, _, _ in ps) + "]"
                chain.send(pk, eng.a, "postPuzzles(uint256,bytes32[],address[],string[])", rid, hashes, vers, uris,
                           gas_limit=15_000_000)
                log(action="post", round=rid, families=[p.family for _, p, _, _ in ps],
                    levels=[p.level for _, p, _, _ in ps])
                return "posted"
            if rd["puzzlesPosted"] and tm["commitEnd"] <= t < tm["genRevealEnd"]:
                did = 0
                for k in range(rd["numRungs"]):
                    if eng.rung(rid, k)["revealed"]:
                        continue
                    p, salt = make(secret, rd["seed"], rid, k, eng.rung(rid, k)["difficulty"], rd["numRungs"])
                    chain.send(pk, eng.a, "revealPuzzle(uint256,uint8,bytes,bytes32)", rid, k,
                               "0x" + p.params.hex(), "0x" + salt.hex())  # let the node estimate (schedule params are large)
                    did += 1
                if did:
                    log(action="reveal", round=rid, rungs=did)
                    return "revealed"
            return "idle"
    chain.send(pk, eng.a, "startRound()")
    log(action="start", round=eng.round_count())
    return "started"


def main():
    eng = chain.Engine(os.environ["ENGINE"])
    pk = os.environ["GEN_PK"]
    verifiers = json.loads(os.environ["VERIFIERS"])
    if sys.argv[1:] == ["loop"]:
        stop_after = int(os.environ.get("STOP_AFTER_ROUND", "0"))
        while True:
            try:
                r = tick(eng, pk, verifiers)
            except Exception as e:  # keep the loop alive; every step is idempotent
                log(error=str(e)[:300])
                r = "error"
            if stop_after and r == "settled" and eng.round_count() >= stop_after:
                return
            time.sleep(10 if r != "idle" else 15)
    else:
        print(tick(eng, pk, verifiers))


if __name__ == "__main__":
    main()
