// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVerifier} from "../interfaces/IVerifier.sol";

/// @title ProgramIOVerifier — "write a program" family.
/// answer = raw EVM *runtime* bytecode written by the agent.
/// params = abi.encode(bytes[] inputs, bytes[] expectedOutputs, uint256 gasPerCall)
/// The verifier wraps the runtime in a fixed 12-byte constructor, deploys it with CREATE and
/// STATICCALLs it once per test vector with a hard gas cap. Output must match byte-for-byte.
/// Safety: STATICCALL forbids state changes (no SELFDESTRUCT/SSTORE/LOG/CREATE); gas is capped
/// per call; code > 24,576 bytes or starting with 0xEF (EIP-3541) fails deployment -> false.
contract ProgramIOVerifier is IVerifier {
    uint256 public constant MAX_GAS_PER_CALL = 1_000_000;
    uint256 public constant MAX_VECTORS = 16;
    uint256 public constant MAX_CODE = 24_576;

    function verify(bytes calldata params, bytes calldata answer) external returns (bool) {
        (bytes[] memory ins, bytes[] memory outs, uint256 gasPerCall) = abi.decode(params, (bytes[], bytes[], uint256));
        if (ins.length != outs.length || ins.length == 0 || ins.length > MAX_VECTORS) return false;
        if (answer.length == 0 || answer.length > MAX_CODE) return false;
        if (gasPerCall > MAX_GAS_PER_CALL) gasPerCall = MAX_GAS_PER_CALL;

        address prog = _deploy(answer);
        if (prog == address(0)) return false;

        for (uint256 i = 0; i < ins.length; i++) {
            (bool ok, bytes memory ret) = prog.staticcall{gas: gasPerCall}(ins[i]);
            if (!ok || keccak256(ret) != keccak256(outs[i])) return false;
        }
        return true;
    }

    /// @dev init code: PUSH2 len, DUP1, PUSH1 0x0c, PUSH1 0, CODECOPY, PUSH1 0, RETURN, <runtime>
    function _deploy(bytes calldata runtime) internal returns (address prog) {
        bytes memory init = abi.encodePacked(
            hex"61", uint16(runtime.length), hex"80600c6000396000f3", runtime
        );
        assembly {
            prog := create(0, add(init, 0x20), mload(init))
        }
    }
}
