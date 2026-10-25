// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base.t.sol";

contract BountyTest is Base {
    function _post(address tok, uint256 reward) internal returns (uint256 id) {
        if (tok == address(usdt)) {
            usdt.mint(publisher, reward);
            vm.prank(publisher);
            usdt.approve(address(bb), reward);
        }
        vm.prank(publisher);
        id = bb.postBounty(tok, reward, address(ss), subsetParams(), uint64(block.timestamp + 3 days));
    }

    function _solve(uint256 id, address who) internal {
        vm.prank(who);
        bb.commit(id, keccak256(abi.encode(ans(4), bytes32(uint256(5)), who)));
        vm.roll(block.number + 1);
        vm.prank(who);
        bb.reveal(id, ans(4), bytes32(uint256(5)));
    }

    function test_bountyHappyPath_feeSplit_noSubsidyBelowRep() public {
        uint256 pubEdge0 = token.balanceOf(publisher);
        uint256 id = _post(address(usdt), 1_000e18);
        assertEq(token.balanceOf(publisher), pubEdge0 - 50e18); // publisher stake
        _solve(id, alice);
        vm.expectRevert(BountyBoard.BadPhase.selector);
        bb.finalize(id); // dispute window still open
        vm.warp(block.timestamp + 48 hours);
        bb.finalize(id);
        assertEq(usdt.balanceOf(alice), 950e18);
        assertEq(usdt.balanceOf(address(fc)), 50e18);
        assertEq(fc.buyback(address(usdt)), 25e18);
        assertEq(fc.treasury(address(usdt)), 20e18);
        assertEq(fc.dev(address(usdt)), 5e18);
        assertEq(token.balanceOf(publisher), pubEdge0); // stake back
        assertEq(engine.pendingRewards(alice), 0); // R = 0.1 < 0.5 -> no subsidy
    }

    function test_bountySubsidyWhenReputable() public {
        for (uint256 i = 0; i < 9; i++) { // 9 solves: 8 would land at 0.497 after one day of decay
            solveOneRound(alice);
        }
        assertGe(engine.reputationOf(alice), 0.5e18);
        uint256 pending0 = engine.pendingRewards(alice);
        uint256 alloc0 = engine.emissionAllocated();
        uint256 id = _post(address(usdt), 1_000e18);
        _solve(id, alice);
        vm.warp(block.timestamp + 48 hours);
        bb.finalize(id);
        // 4% of 1000 USDT * 2 EDGE/USDT = 80 EDGE  < fee 50 USDT * 2 = 100 EDGE
        assertEq(engine.pendingRewards(alice) - pending0, 80e18);
        assertEq(engine.emissionAllocated() - alloc0, 80e18); // counts against mining cap
    }

    function test_subsidyCapApplies() public {
        bb.setFees(500, 400, 10e18);
        assertEq(bb.computeSubsidy(address(usdt), 1_000e18, 1e18), 10e18);
    }

    function test_setFeesRejectsSubsidyGeFee() public {
        vm.expectRevert(BountyBoard.BadParam.selector);
        bb.setFees(500, 500, 1e30);
        vm.expectRevert(BountyBoard.BadParam.selector);
        bb.setFees(300, 400, 1e30);
    }

    /// @notice invariant: for any reward / price / fee config, subsidy < protocol fee (in EDGE)
    function testFuzz_subsidyAlwaysBelowFee(uint256 reward, uint256 price, uint256 feeBps, uint256 subBps, uint256 cap, uint256 rep)
        public
    {
        reward = bound(reward, 0, 1e30);
        price = bound(price, 1, 1e24);
        feeBps = bound(feeBps, 1, 1_000);
        subBps = bound(subBps, 0, feeBps - 1);
        cap = bound(cap, 0, 1e30);
        rep = bound(rep, 0.1e18, 1e18);
        bb.setFees(feeBps, subBps, cap);
        bb.setToken(address(usdt), true, price);
        uint256 sub = bb.computeSubsidy(address(usdt), reward, rep);
        uint256 feeEdge = (reward * feeBps / 10_000) * price / 1e18;
        if (sub > 0) assertLt(sub, feeEdge);
        if (rep < 0.5e18) assertEq(sub, 0);
    }

    function test_washMiningUnprofitable() public {
        // self-dealing publisher==solver with max reputation, EDGE-denominated bounty
        for (uint256 i = 0; i < 18; i++) {
            solveOneRound(alice);
        }
        gate.setAgent(publisher, true);
        // move publisher's reputation by making it the solver too: use alice as both roles
        vm.prank(alice);
        token.approve(address(bb), type(uint256).max);
        uint256 before = token.balanceOf(alice) + engine.pendingRewards(alice);
        vm.prank(alice);
        uint256 id = bb.postBounty(address(token), 1_000e18, address(ss), subsetParams(), uint64(block.timestamp + 1 days));
        _solve(id, alice);
        vm.warp(block.timestamp + 48 hours);
        bb.finalize(id);
        uint256 afterBal = token.balanceOf(alice) + engine.pendingRewards(alice);
        assertLt(afterBal, before); // lost fee (50) - subsidy (40) = 10 EDGE
        assertEq(before - afterBal, 10e18);
    }

    function test_firstValidRevealWins_andSameBlockRevealBlocked() public {
        uint256 id = _post(address(token), 100e18);
        vm.prank(bob);
        bb.commit(id, keccak256(abi.encode(ans(4), bytes32(uint256(5)), bob)));
        vm.prank(bob);
        vm.expectRevert(BountyBoard.BadPhase.selector); // same block
        bb.reveal(id, ans(4), bytes32(uint256(5)));
        _solve(id, alice);
        vm.roll(block.number + 1);
        vm.prank(bob);
        vm.expectRevert(BountyBoard.BadPhase.selector); // already solved
        bb.reveal(id, ans(4), bytes32(uint256(5)));
    }

    function test_invalidRevealReverts() public {
        uint256 id = _post(address(token), 100e18);
        vm.prank(alice);
        bb.commit(id, keccak256(abi.encode(ans(3), bytes32(uint256(5)), alice)));
        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert(BountyBoard.BadParam.selector);
        bb.reveal(id, ans(3), bytes32(uint256(5)));
    }

    function test_disputeUpheld_refundsPublisher() public {
        uint256 id = _post(address(usdt), 1_000e18);
        _solve(id, alice);
        vm.prank(alice);
        vm.expectRevert(BountyBoard.BadPhase.selector);
        bb.dispute(id); // only publisher
        vm.prank(publisher);
        bb.dispute(id);
        vm.prank(arbiter);
        bb.resolveDispute(id, true);
        assertEq(usdt.balanceOf(publisher), 1_000e18);
        assertEq(usdt.balanceOf(alice), 0);
    }

    function test_disputeRejected_paysSolver_slashesStake() public {
        uint256 id = _post(address(usdt), 1_000e18);
        _solve(id, alice);
        vm.prank(publisher);
        bb.dispute(id);
        vm.prank(arbiter);
        bb.resolveDispute(id, false);
        assertEq(usdt.balanceOf(alice), 950e18);
        assertEq(fc.treasury(address(token)), 50e18); // publisher stake to treasury
    }

    function test_disputeAfterWindowFails() public {
        uint256 id = _post(address(usdt), 1_000e18);
        _solve(id, alice);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(publisher);
        vm.expectRevert(BountyBoard.BadPhase.selector);
        bb.dispute(id);
    }

    function test_cancelAfterDeadline() public {
        uint256 id = _post(address(usdt), 1_000e18);
        vm.prank(publisher);
        vm.expectRevert(BountyBoard.BadPhase.selector);
        bb.cancel(id);
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(publisher);
        bb.cancel(id);
        assertEq(usdt.balanceOf(publisher), 1_000e18);
    }

    function test_unlistedVerifierRejected() public {
        vm.prank(publisher);
        vm.expectRevert(BountyBoard.BadParam.selector);
        bb.postBounty(address(token), 1e18, address(cs), "", uint64(block.timestamp + 1 days));
    }
}
