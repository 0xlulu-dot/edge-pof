"""Tiny straight-line EVM codegen + reference interpreter for the program_io family."""
MASK = (1 << 256) - 1


def run_ops(ops, x: int) -> int:
    v, x0 = x, x
    for op, c in ops:
        if op == "ADD":
            v = (v + c) & MASK
        elif op == "MUL":
            v = (v * c) & MASK
        elif op == "XOR":
            v ^= c
        elif op == "AND":
            v &= c
        elif op == "SHR":
            v = v >> c if c < 256 else 0
        elif op == "SHL":
            v = (v << c) & MASK if c < 256 else 0
        elif op == "MOD":
            v = v % c if c else 0
        elif op == "SUB":
            v = (v - c) & MASK
        elif op == "ADDX":
            v = (v + x0) & MASK
        elif op == "MULX":
            v = (v * x0) & MASK
        elif op == "XORX":
            v ^= x0
        else:
            raise ValueError(op)
    return v


def _push(c: int) -> bytes:
    if c == 0:
        return bytes([0x60, 0])
    b = c.to_bytes((c.bit_length() + 7) // 8, "big")
    return bytes([0x5F + len(b)]) + b  # PUSH1..PUSH32


def compile_ops(ops) -> bytes:
    """calldata x -> RETURN 32 bytes f(x). Stack layout: [x0, v] (v on top)."""
    code = bytes([0x60, 0x00, 0x35, 0x80])  # PUSH1 0 CALLDATALOAD DUP1
    for op, c in ops:
        if op == "ADD":
            code += _push(c) + b"\x01"
        elif op == "MUL":
            code += _push(c) + b"\x02"
        elif op == "XOR":
            code += _push(c) + b"\x18"
        elif op == "AND":
            code += _push(c) + b"\x16"
        elif op == "SHR":  # SHR(shift=top, value)
            code += _push(c) + b"\x1c"
        elif op == "SHL":
            code += _push(c) + b"\x1b"
        elif op == "MOD":  # a % b with a on top -> need v on top
            code += _push(c) + b"\x90\x06"  # SWAP1 MOD
        elif op == "SUB":
            code += _push(c) + b"\x90\x03"  # SWAP1 SUB -> v - c
        elif op == "ADDX":
            code += b"\x81\x01"  # DUP2 ADD
        elif op == "MULX":
            code += b"\x81\x02"
        elif op == "XORX":
            code += b"\x81\x18"
        else:
            raise ValueError(op)
    code += bytes([0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xF3])  # MSTORE(0,v) RETURN(0,32)
    if code[0] == 0xEF:
        raise ValueError("EIP-3541")
    return code
