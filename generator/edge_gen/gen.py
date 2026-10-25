"""Round-level puzzle generation: deterministic from (generator secret, VRF seed, round, rung).

Stateless by design: the generator only keeps its 32-byte secret; params and salts are re-derived at
reveal time, so a crashed generator can always reveal (or anyone holding the secret can).
Later the secret lives inside a TEE and the code hash is attested on-chain.
"""
from __future__ import annotations

import base64
import json

from eth_abi import encode
from eth_utils import keccak

from .families import FAMILIES, Puzzle

# family rotation: every round has at least one of each family when numRungs >= 3;
# the VRF seed picks the rotation offset so nobody knows in advance which family sits on which rung.
ORDER = ["subset_sum", "schedule", "program_io"]


def level_of(difficulty: int) -> int:
    return max(1, difficulty.bit_length() - 1)  # floor(log2)


def family_for(seed: int, rung: int, num_rungs: int) -> str:
    # Benchmarked: classical code solves subset_sum/schedule up to L=18 in ~1 s, so they only fill
    # lower rungs. The top (sweet-spot, biggest-weight) rung is always hint-free program synthesis.
    if rung == num_rungs - 1:
        return "program_io"
    return ORDER[(seed + rung) % len(ORDER)]


def derive(secret: bytes, seed: int, rid: int, rung: int, tag: bytes) -> bytes:
    return keccak(secret + seed.to_bytes(32, "big") + rid.to_bytes(32, "big") + bytes([rung]) + tag)


def make(secret: bytes, seed: int, rid: int, rung: int, difficulty: int, num_rungs: int) -> tuple[Puzzle, bytes]:
    fam = family_for(seed, rung, num_rungs)
    rnd = derive(secret, seed, rid, rung, b"puzzle")
    if fam == "program_io":
        p = FAMILIES[fam](rnd, level_of(difficulty), hint=rung < num_rungs - 1)
    else:
        p = FAMILIES[fam](rnd, level_of(difficulty))
    salt = derive(secret, seed, rid, rung, b"salt")
    return p, salt


def puzzle_hash(params: bytes, salt: bytes) -> bytes:
    # must equal keccak256(abi.encode(params, salt)) in PoFEngine.revealPuzzle
    return keccak(encode(["bytes", "bytes32"], [params, salt]))


def to_uri(p: Puzzle, rid: int, rung: int) -> str:
    """Testnet: the public statement is stored on-chain as a data: URI. Mainnet: IPFS CID."""
    body = dict(p.public, round=rid, rung=rung)
    return "data:application/json;base64," + base64.b64encode(json.dumps(body, separators=(",", ":")).encode()).decode()


def from_uri(uri: str) -> dict:
    assert uri.startswith("data:application/json;base64,"), "only data: URIs supported on testnet"
    return json.loads(base64.b64decode(uri.split(",", 1)[1]))
