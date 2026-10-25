// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base.t.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract PauseTest is Base {
    function test_pauseBlocksNewActivityOnly() public {
        // alice earns a reward and has an open commit when the guardian pauses
        uint256 id = startAndPost();
        commitAs(alice, id, 0, ans(4), bytes32(uint256(1)));
        commitAs(bob, id, 1, ans(4), bytes32(uint256(2)));
        revealPuzzles(id);

        vm.prank(pauser);
        engine.pause();

        // new commits blocked
        vm.prank(carol);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        engine.commit(id, 2, keccak256("z"));

        // reveal still works -> bond returned
        uint256 b0 = token.balanceOf(alice);
        revealAs(alice, id, 0, ans(4), bytes32(uint256(1)));
        assertEq(token.balanceOf(alice), b0 + 10e18);

        // settlement (new reward accrual) blocked while paused
        vm.warp(engine.roundEndOf(id));
        vm.expectRevert(Pausable.EnforcedPause.selector);
        engine.settle(id);
        // new rounds blocked
        vm.expectRevert(Pausable.EnforcedPause.selector);
        engine.startRound();

        vm.prank(pauser);
        engine.unpause();
        engine.settle(id);
        engine.accrueSolver(id, 0, alice);

        // pause again: claim of already-accrued rewards still works
        vm.prank(pauser);
        engine.pause();
        vm.prank(alice);
        uint256 got = engine.claim();
        assertGt(got, 0);
        // accrue (settled round) also works while paused
        assertEq(engine.paused(), true);
    }

    function test_refundBondWorksWhilePaused() public {
        uint256 id = startAndPost();
        commitAs(alice, id, 0, ans(4), bytes32(uint256(1)));
        vm.prank(pauser);
        engine.pause();
        vm.warp(engine.genRevealEndOf(id));
        uint256 b0 = token.balanceOf(alice);
        vm.prank(alice);
        engine.refundBond(id, 0);
        assertEq(token.balanceOf(alice), b0 + 10e18);
    }

    function test_onlyPauserCanPause() public {
        vm.prank(alice);
        vm.expectRevert();
        engine.pause();
    }

    function test_bountyEscrowReleasableWhilePaused_subsidyDeferred() public {
        for (uint256 i = 0; i < 9; i++) { // 9 solves: 8 would land at 0.497 after one day of decay
            solveOneRound(alice);
        }
        vm.prank(publisher);
        uint256 id = bb.postBounty(address(token), 1_000e18, address(ss), subsetParams(), uint64(block.timestamp + 1 days));
        vm.prank(alice);
        bb.commit(id, keccak256(abi.encode(ans(4), bytes32(uint256(5)), alice)));
        vm.roll(block.number + 1);
        vm.prank(alice);
        bb.reveal(id, ans(4), bytes32(uint256(5)));

        vm.startPrank(pauser);
        bb.pause();
        engine.pause();
        vm.stopPrank();

        // new bounties blocked
        vm.prank(publisher);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        bb.postBounty(address(token), 1e18, address(ss), subsetParams(), uint64(block.timestamp + 1 days));

        vm.warp(block.timestamp + 48 hours);
        uint256 a0 = token.balanceOf(alice);
        bb.finalize(id); // escrow release works while both are paused
        assertEq(token.balanceOf(alice), a0 + 950e18);
        assertEq(bb.pendingSubsidy(id), 40e18); // minting deferred, not lost

        vm.prank(pauser);
        engine.unpause();
        uint256 p0 = engine.pendingRewards(alice);
        bb.creditPendingSubsidy(id);
        assertEq(engine.pendingRewards(alice) - p0, 40e18);
    }

    function test_forecastWithdrawWhileEnginePaused() public {
        vm.prank(alice);
        fm.stake(500e18);
        vm.prank(alice);
        fm.requestUnbond(500e18);
        vm.prank(pauser);
        engine.pause();
        vm.warp(block.timestamp + 7 days);
        uint256 b0 = token.balanceOf(alice);
        vm.prank(alice);
        fm.withdraw();
        assertEq(token.balanceOf(alice), b0 + 500e18);
    }
}
