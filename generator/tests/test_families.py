"""Offline + on-chain self checks.  python3 -m tests.test_families [--onchain]"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from eth_abi import decode  # noqa: E402

from edge_gen import chain  # noqa: E402
from edge_gen.evm import compile_ops, run_ops  # noqa: E402
from edge_gen.families import FAMILIES, verify_schedule, verify_subset  # noqa: E402
from edge_gen.gen import from_uri, make, puzzle_hash, to_uri  # noqa: E402

VERIFIERS = {  # fast test instance (BSC testnet)
    "subset_sum": "0xff1f2ea0594b379793fc92f0ce8c61381f3a331c",
    "schedule": "0x8e6664685828878bbe00c7c951ad944f4711fdb8",
    "program_io": "0x62ebba433556f6418a38d91eefcdc365c05682f0",
}


def offline(n=60):
    for s in range(n):
        for L in (4, 8, 12, 14, 16, 20):
            for fam, fn in FAMILIES.items():
                p = fn(s.to_bytes(32, "big"), L)
                if fam == "subset_sum":
                    st, t = decode(["uint256[]", "uint256"], p.params)
                    (idx,) = decode(["uint256[]"], p.planted_answer)
                    assert verify_subset(list(st), t, list(idx)), (s, L)
                elif fam == "schedule":
                    nT, nS, cs = decode(["uint256", "uint256", "uint256[3][]"], p.params)
                    (sl,) = decode(["uint256[]"], p.planted_answer)
                    assert verify_schedule(nT, nS, [list(c) for c in cs], list(sl)), (s, L)
                else:
                    ins, outs, _ = decode(["bytes[]", "bytes[]", "uint256"], p.params)
                    ops = p.meta["ops"]
                    for a, b in zip(ins, outs):
                        assert run_ops(ops, int.from_bytes(a, "big")) == int.from_bytes(b, "big")
                    assert p.planted_answer == compile_ops(ops)
                    assert len(p.public["examples"]) == 6 and len(ins) == 12
    # determinism + URI round trip
    a, sa = make(b"k" * 32, 123, 7, 2, 1 << 14, 5)
    b, sb = make(b"k" * 32, 123, 7, 2, 1 << 14, 5)
    assert a.params == b.params and sa == sb and len(puzzle_hash(a.params, sa)) == 32
    assert from_uri(to_uri(a, 7, 2))["family"] == a.family
    top, _ = make(b"k" * 32, 123, 7, 4, 1 << 12, 5)
    assert top.family == "program_io" and top.public["hint"] is None
    print("offline OK")


def onchain():
    for L in (8, 12, 16):
        for fam, fn in FAMILIES.items():
            p = fn(L.to_bytes(32, "big") + b"onchain", L)
            ok = chain.call(VERIFIERS[fam], "verify(bytes,bytes)(bool)", "0x" + p.params.hex(), "0x" + p.planted_answer.hex())[0]
            bad = p.planted_answer[:-1] + bytes([p.planted_answer[-1] ^ 1])
            nok = chain.call(VERIFIERS[fam], "verify(bytes,bytes)(bool)", "0x" + p.params.hex(), "0x" + bad.hex())[0]
            print(f"L={L:2d} {fam:10s} planted={ok} tampered={nok}")
            assert ok == "true" and nok == "false", (fam, L)
    print("onchain OK")


if __name__ == "__main__":
    offline()
    if "--onchain" in sys.argv:
        onchain()
