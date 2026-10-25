"""Minimal chain access through Foundry `cast` (no web3 dependency). Keys are passed via env, never printed."""
from __future__ import annotations

import json
import os
import subprocess

CAST = os.environ.get("CAST", os.path.expanduser("~/.foundry/bin/cast"))
RPC = os.environ.get("RPC", "https://bsc-testnet-rpc.publicnode.com")
GAS = ["--legacy", "--gas-price", os.environ.get("GAS_PRICE_WEI", "100000000")]


class ChainError(RuntimeError):
    pass


def _cast(args: list[str]) -> str:
    p = subprocess.run([CAST, *args], capture_output=True, text=True)
    if p.returncode != 0:
        raise ChainError(p.stderr.strip()[-600:])
    return p.stdout.strip()


def call(to: str, sig: str, *a) -> list[str]:
    out = _cast(["call", "--rpc-url", RPC, to, sig, *map(str, a)])
    # cast prints one decoded value per line, with optional " [1e18]" suffix
    return [line.split(" [")[0].strip().strip('"') for line in out.splitlines()]


def call_raw(to: str, data: str) -> str:
    return _cast(["call", "--rpc-url", RPC, to, data])


def send(pk: str, to: str, sig: str, *a, gas_limit: int | None = None) -> str:
    args = ["send", "--rpc-url", RPC, "--private-key", pk, *GAS, "--json", to, sig, *map(str, a)]
    if gas_limit:
        args += ["--gas-limit", str(gas_limit)]
    out = json.loads(_cast(args))
    if out.get("status") not in ("0x1", 1, "1"):
        raise ChainError(f"reverted: {sig} tx {out.get('transactionHash')}")
    return out["transactionHash"]


def now() -> int:
    return int(_cast(["block", "latest", "--rpc-url", RPC, "--field", "timestamp"]))


def i(x: str) -> int:
    return int(x, 0) if x.startswith("0x") else int(x)


class Engine:
    def __init__(self, addr: str):
        self.a = addr

    def round_count(self) -> int:
        return i(call(self.a, "roundCount()(uint256)")[0])

    def round(self, rid: int) -> dict:
        v = call(self.a, "rounds(uint256)(uint64,uint64,uint64,uint8,bool,bool,uint32,uint256,uint256,uint256)", rid)
        return dict(start=i(v[0]), duration=i(v[1]), settledAt=i(v[2]), numRungs=i(v[3]),
                    puzzlesPosted=v[4] == "true", settled=v[5] == "true", activeIDs=i(v[6]),
                    pool=i(v[7]), fresh=i(v[8]), seed=i(v[9]))

    def rung(self, rid: int, k: int) -> dict:
        v = call(self.a, "rungs(uint256,uint8)(bytes32,address,uint256,bool,uint8,uint32,uint256,uint256,uint256)", rid, k)
        return dict(puzzleHash=v[0], verifier=v[1], difficulty=i(v[2]), revealed=v[3] == "true", bucket=i(v[4]),
                    distinct=i(v[5]), sumR=i(v[6]), payout=i(v[7]))

    def times(self, rid: int) -> dict:
        return {k: i(call(self.a, f"{k}Of(uint256)(uint256)", rid)[0])
                for k in ("forecastEnd", "commitEnd", "genRevealEnd", "roundEnd")}

    def seed(self, rid: int) -> tuple[bool, int]:
        rnd = call(self.a, "randomness()(address)")[0]
        v = call(rnd, "seedOf(uint256)(bool,uint256)", rid)
        return v[0] == "true", i(v[1])

    def uri(self, rid: int, k: int) -> str:
        return call(self.a, "puzzleURI(uint256,uint8)(string)", rid, k)[0]

    def params(self, rid: int, k: int) -> str:
        return call(self.a, "puzzleParams(uint256,uint8)(bytes)", rid, k)[0]
