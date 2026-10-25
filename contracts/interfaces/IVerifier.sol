// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice A puzzle-family verifier. NOT view: ProgramIOVerifier deploys candidate bytecode.
/// Callers always invoke it with a gas cap inside try/catch; a revert counts as "false".
interface IVerifier {
    function verify(bytes calldata params, bytes calldata answer) external returns (bool);
}
