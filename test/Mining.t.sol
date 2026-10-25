// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base.t.sol";
import {PoFMath} from "../contracts/PoFMath.sol";

contract MathHarness {
    function g(uint256 n, uint256 k) external pure returns (uint256) {
        return PoFMath.g(n, k);
    }

    function kFor(uint256 a) external pure returns (uint256) {
        return PoFMath.kFor(a);
    }
}

contract MiningTest is Base {
    uint256 constant WAD = 1e18;

    // ------------------------------ commit / reveal ------------------------------
    function test_happyPath() public {
        uint256 id = startAndPost();
        uint256 bal0 = token.balanceOf(alice);
        commitAs(alice, id, 2, ans(4), bytes32(uint256(7)));
        assertEq(token.balanceOf(alice), bal0 - 10e18); // bond posted
        revealPuzzles(id);
        revealAs(alice, id, 2, ans(4), bytes32(uint256(7)));
        assertEq(token.balanceOf(alice), bal0); // bond returned
        assertEq(engine.reputationOf(alice), 0.15e18);
        endAndSettle(id);

        uint256 solverPool = roundPool(id) * 8000 / 10000;
        uint256 expected = solverPool * 4 / 31 * 7 / 10; // rung 2 weight 4/31, one solver -> g=0.7
        assertEq(rungPayout(id, 2), expected);
        engine.accrueSolver(id, 2, alice);
        vm.prank(alice);
        uint256 got = engine.claim();
        assertEq(got, expected); // sole solver takes whole rung share
        assertEq(token.balanceOf(alice), bal0 + expected);
        assertEq(token.miningMinted(), expected);
    }

    function test_wrongAnswerBurnsBond() public {
        uint256 id = startAndPost();
        uint256 supply0 = token.totalSupply();
        commitAs(alice, id, 0, ans(3), bytes32(uint256(1))); // 4 != 5
        revealPuzzles(id);
        revealAs(alice, id, 0, ans(3), bytes32(uint256(1)));
        assertEq(token.totalSupply(), supply0 - 10e18);
        assertEq(engine.totalBondsBurned(), 10e18);
        assertEq(engine.reputationOf(alice), 0.1e18); // floored at 0.1
        endAndSettle(id);
        assertEq(rungPayout(id, 0), 0);
    }

    function test_badRevealSaltReverts() public {
        uint256 id = startAndPost();
        commitAs(alice, id, 0, ans(4), bytes32(uint256(1)));
        revealPuzzles(id);
        vm.prank(alice);
        vm.expectRevert(PoFEngine.BadParam.selector);
        engine.revealAnswer(id, 0, ans(4), bytes32(uint256(2)));
        // and someone else cannot reveal alice's commitment (sender is bound)
        vm.prank(bob);
        vm.expectRevert(PoFEngine.AlreadyDone.selector);
        engine.revealAnswer(id, 0, ans(4), bytes32(uint256(1)));
    }

    function test_unrevealedBondBurnedAtSettle() public {
        uint256 id = startAndPost();
        commitAs(alice, id, 1, ans(4), bytes32(uint256(1)));
        revealPuzzles(id);
        uint256 supply0 = token.totalSupply();
        endAndSettle(id);
        assertEq(token.totalSupply(), supply0 - 10e18);
        assertEq(token.balanceOf(address(engine)), 0);
    }

    function test_generatorFailure_bondRefund_fullRollover() public {
        uint256 id = startAndPost();
        commitAs(alice, id, 0, ans(4), bytes32(uint256(1)));
        vm.warp(engine.genRevealEndOf(id));
        vm.expectRevert(PoFEngine.BadPhase.selector);
        engine.revealPuzzle(id, 0, subsetParams(), keccak256(abi.encode(PSALT, uint8(0))));
        uint256 bal = token.balanceOf(alice);
        vm.prank(alice);
        engine.refundBond(id, 0);
        assertEq(token.balanceOf(alice), bal + 10e18);
        endAndSettle(id);
        uint256 pool = roundPool(id);
        uint256 solverPool = pool * 8000 / 10000;
        // no rung revealed: entire solver pool rolls (dust aside); forecast pool split 50/50
        assertApproxEqAbs(engine.rolloverPool(), solverPool + (pool - solverPool) / 2, 10);
    }

    function test_puzzleHashMismatchReverts() public {
        uint256 id = startAndPost();
        vm.warp(engine.commitEndOf(id));
        vm.expectRevert(PoFEngine.BadParam.selector);
        engine.revealPuzzle(id, 0, subsetParams(), bytes32(uint256(123)));
    }

    // ------------------------------ duplicates ------------------------------
    function test_duplicateAnswersCountOnce() public {
        // v3.2: identical answers = one solution; its share is split among everyone who found it
        uint256 id = startAndPost();
        commitAs(alice, id, 0, ans(4), bytes32(uint256(1)));
        commitAs(bob, id, 0, ans(4), bytes32(uint256(2))); // same answer, different salt
        commitAs(carol, id, 0, ans2(0, 3), bytes32(uint256(3))); // distinct valid answer
        revealPuzzles(id);
        uint256 bobBal = token.balanceOf(bob);
        revealAs(alice, id, 0, ans(4), bytes32(uint256(1)));
        revealAs(bob, id, 0, ans(4), bytes32(uint256(2)));
        revealAs(carol, id, 0, ans2(0, 3), bytes32(uint256(3)));
        assertEq(token.balanceOf(bob), bobBal + 10e18); // bond back
        assertEq(engine.reputationOf(bob), 0.15e18); // correct work earns reputation
        assertEq(rungDistinct(id, 0), 2); // crowding counts distinct solutions only
        assertEq(rungSumR(id, 0), 0.2e18); // one weight per solution
        endAndSettle(id);
        engine.accrueSolver(id, 0, alice);
        engine.accrueSolver(id, 0, bob);
        engine.accrueSolver(id, 0, carol);
        uint256 half = rungPayout(id, 0) / 2;
        assertEq(engine.pendingRewards(carol), half);
        assertEq(engine.pendingRewards(alice), engine.pendingRewards(bob));
        assertApproxEqAbs(engine.pendingRewards(alice) + engine.pendingRewards(bob), half, 2);
    }

    function test_sybilSameAnswerGainsNothing() public {
        // one answer from 1 ID vs the same answer from 3 IDs: same total for that solution
        uint256 id = startAndPost();
        commitAs(alice, id, 0, ans(4), bytes32(uint256(1)));
        commitAs(bob, id, 0, ans2(0, 3), bytes32(uint256(2)));
        commitAs(carol, id, 0, ans2(0, 3), bytes32(uint256(3)));
        commitAs(dave, id, 0, ans2(0, 3), bytes32(uint256(4)));
        revealPuzzles(id);
        revealAs(alice, id, 0, ans(4), bytes32(uint256(1)));
        revealAs(bob, id, 0, ans2(0, 3), bytes32(uint256(2)));
        revealAs(carol, id, 0, ans2(0, 3), bytes32(uint256(3)));
        revealAs(dave, id, 0, ans2(0, 3), bytes32(uint256(4)));
        endAndSettle(id);
        uint256 cluster = engine.claimable(id, 0, bob) + engine.claimable(id, 0, carol) + engine.claimable(id, 0, dave);
        assertApproxEqAbs(cluster, engine.claimable(id, 0, alice), 3);
    }

    function test_withinRungSplitByReputation() public {
        for (uint256 i = 0; i < 4; i++) {
            solveOneRound(alice); // alice R -> 0.3
        }
        assertEq(engine.reputationOf(alice), 0.3e18);
        uint256 id = startAndPost();
        commitAs(alice, id, 0, ans(4), bytes32(uint256(1)));
        commitAs(bob, id, 0, ans2(1, 2), bytes32(uint256(2)));
        revealPuzzles(id);
        revealAs(alice, id, 0, ans(4), bytes32(uint256(1)));
        revealAs(bob, id, 0, ans2(1, 2), bytes32(uint256(2)));
        endAndSettle(id);
        uint256 a = engine.claimable(id, 0, alice);
        uint256 b = engine.claimable(id, 0, bob);
        assertApproxEqAbs(a, b * 3, 3); // 0.3 vs 0.1
    }

    // ------------------------------ g(n) math ------------------------------
    function test_gFunction() public {
        MathHarness h = new MathHarness();
        assertEq(h.g(0, 3), 0);
        assertEq(h.g(1, 3), 0.7e18);
        assertEq(h.g(1.99e18, 3), 0.7e18);
        assertEq(h.g(2e18, 3), 1e18);
        assertEq(h.g(3e18, 3), 1e18);
        assertEq(h.g(6e18, 3), 0.5e18);
        assertEq(h.g(60e18, 30), 0.5e18);
        assertEq(h.kFor(0), 3);
        assertEq(h.kFor(100), 3); // sqrt=10 -> 1 -> clamp 3
        assertEq(h.kFor(2500), 5); // sqrt=50 -> 5
        assertEq(h.kFor(10_000), 10);
        assertEq(h.kFor(1_000_000), 30); // sqrt=1000 -> 100 -> clamp 30
    }

    function testFuzz_gBounded(uint256 n, uint256 active) public {
        MathHarness h = new MathHarness();
        n = bound(n, 0, 1e30);
        uint256 k = h.kFor(bound(active, 0, 1e12));
        uint256 gv = h.g(n, k);
        assertLe(gv, 1e18);
        if (n > k * 1e18) assertLe(gv * n / 1e18, k * 1e18); // crowded rung pays at most k "units"
    }

    function test_settlementBucketsAndCrowding() public {
        // 3 distinct solvers on rung 0 (headcount 3, k=3 -> sweet spot, g=1); nobody elsewhere
        uint256 id = startAndPost();
        commitAs(alice, id, 0, ans(4), bytes32(uint256(1)));
        commitAs(bob, id, 0, ans2(0, 3), bytes32(uint256(2)));
        commitAs(carol, id, 0, ans2(1, 2), bytes32(uint256(3)));
        revealPuzzles(id);
        revealAs(alice, id, 0, ans(4), bytes32(uint256(1)));
        revealAs(bob, id, 0, ans2(0, 3), bytes32(uint256(2)));
        revealAs(carol, id, 0, ans2(1, 2), bytes32(uint256(3)));
        endAndSettle(id);
        assertEq(rungBucket(id, 0), 2);
        assertEq(rungBucket(id, 1), 0);
        uint256 solverPool = roundPool(id) * 8000 / 10000;
        assertEq(rungPayout(id, 0), solverPool * 1 / 31);
        assertEq(rungPayout(id, 4), 0);
    }

    // ------------------------------ rollover / burn ------------------------------
    function test_rolloverBurnAccountingExact() public {
        uint256 id = startAndPost();
        commitAs(alice, id, 3, ans(4), bytes32(uint256(1)));
        revealPuzzles(id);
        revealAs(alice, id, 3, ans(4), bytes32(uint256(1)));
        uint256 burned0 = engine.totalBurnedUnminted();
        endAndSettle(id);
        uint256 pool = roundPool(id);
        uint256 paid = rungPayout(id, 3);
        uint256 burned = engine.totalBurnedUnminted() - burned0;
        uint256 rolled = engine.rolloverPool();
        assertEq(paid + burned + rolled, pool); // exact conservation
        uint256 unpaid = pool - paid;
        assertEq(burned, unpaid / 2);
        assertEq(rolled, unpaid - unpaid / 2);

        // next round's pool = its fresh emission + rollover
        vm.warp(engine.roundEndOf(id));
        uint256 id2 = engine.startRound();
        (,,,,,,,, uint256 fresh2,) = engine.rounds(id2);
        assertEq(roundPool(id2), fresh2 + rolled);
        assertEq(engine.rolloverPool(), 0);
    }

    function test_globalSupplyAccounting() public {
        for (uint256 i = 0; i < 6; i++) {
            solveOneRound(alice);
        }
        // allocated == accrued + burned(unminted) + rollover + rounding dust in payouts
        uint256 lhs = engine.emissionAllocated();
        // accrue everything
        for (uint256 i = 1; i <= 6; i++) {
            engine.accrueSolver(i, 0, alice);
        }
        uint256 rhs = engine.totalAccrued() + engine.totalBurnedUnminted() + engine.rolloverPool();
        assertApproxEqAbs(lhs, rhs, 100);
        assertLe(rhs, lhs);
    }

    // ------------------------------ emission ------------------------------
    function test_emissionDecay365Days() public {
        assertEq(engine.dailyEmissionAt(0), 92_000e18);
        assertApproxEqRel(engine.dailyEmissionAt(1), 91_908e18, 1e9);
        assertApproxEqRel(engine.dailyEmissionAt(365), 63_854.429607723667406e18, 1e9);
        uint256 sum;
        for (uint256 d = 0; d < 365; d++) {
            sum += engine.dailyEmissionAt(d);
        }
        assertApproxEqRel(sum, 28_145_570.392276332593e18, 1e9);
        // round emission: 4h = 1/6 of the day
        vm.warp(block.timestamp + 365 days);
        assertEq(engine.roundEmissionNow(4 hours), engine.dailyEmissionAt(365) * 4 hours / 1 days);
    }

    function test_infiniteSeriesEqualsMiningCap() public view {
        // 92,000 / 0.001 = 92,000,000 : the default schedule asymptotically exhausts the 92M cap
        assertEq(engine.INITIAL_DAILY_EMISSION() * 1e18 / engine.BASE_DAILY_DECAY(), engine.miningCap());
    }

    function test_indexMultiplierBoundsAndCheckpoint() public {
        vm.expectRevert(PoFEngine.BadParam.selector);
        engine.setIndexMultiplier(0.69e18);
        vm.expectRevert(PoFEngine.BadParam.selector);
        engine.setIndexMultiplier(1.31e18);
        vm.prank(alice);
        vm.expectRevert();
        engine.setIndexMultiplier(1e18);

        vm.warp(block.timestamp + 100 days);
        uint256 e100 = engine.dailyEmissionAt(100);
        engine.setIndexMultiplier(1.3e18);
        assertEq(engine.dailyEmissionAt(100), e100); // no retroactive jump
        assertApproxEqRel(engine.dailyEmissionAt(101), e100 * 9987 / 10000, 1e9); // 0.13%/day
        engine.setIndexMultiplier(0.7e18);
        assertApproxEqRel(engine.dailyEmissionAt(101), e100 * 9993 / 10000, 1e9); // 0.07%/day
    }

    // ------------------------------ ladder ------------------------------
    function test_ladderTopsAtSweetSpot() public {
        uint256 s0 = engine.sweetSpot();
        uint256 id = startAndPost();
        (,, uint256 d0,,,,,,) = engine.rungs(id, 0);
        (,, uint256 d2,,,,,,) = engine.rungs(id, 2);
        (,, uint256 d4,,,,,,) = engine.rungs(id, 4);
        assertEq(d4, s0);
        assertEq(d2, s0 / 4);
        assertEq(d0, s0 / 16);
        // only rung 1 solved -> new sweet spot = difficulty of rung 1
        commitAs(alice, id, 1, ans(4), bytes32(uint256(1)));
        revealPuzzles(id);
        revealAs(alice, id, 1, ans(4), bytes32(uint256(1)));
        endAndSettle(id);
        assertEq(engine.sweetSpot(), s0 / 8);
    }

    function test_numRungsConfigurable() public {
        engine.setNumRungs(10);
        vm.expectRevert(PoFEngine.BadParam.selector);
        engine.setNumRungs(11);
        uint256 id = startAndPost();
        commitAs(alice, id, 9, ans(4), bytes32(uint256(1)));
        revealPuzzles(id);
        revealAs(alice, id, 9, ans(4), bytes32(uint256(1)));
        endAndSettle(id);
        uint256 solverPool = roundPool(id) * 8000 / 10000;
        assertEq(rungPayout(id, 9), solverPool * 512 / 1023 * 7 / 10);
    }

    // ------------------------------ reputation ------------------------------
    function test_reputationDecayLazy() public {
        solveOneRound(alice);
        assertEq(engine.reputationOf(alice), 0.15e18);
        vm.warp(block.timestamp + 100 days);
        assertApproxEqRel(engine.reputationOf(alice), 0.1183016170636614e18, 1e9);
        for (uint256 i = 0; i < 30; i++) {
            solveOneRound(bob);
        }
        assertEq(engine.reputationOf(bob), 1e18); // capped
    }

    // ------------------------------ verifiers ------------------------------
    function test_programIOVerifier() public {
        bytes[] memory ins = new bytes[](2);
        bytes[] memory outs = new bytes[](2);
        ins[0] = abi.encode(uint256(1), uint256(2));
        outs[0] = abi.encode(uint256(3));
        ins[1] = abi.encode(uint256(40), uint256(2));
        outs[1] = abi.encode(uint256(42));
        bytes memory params = abi.encode(ins, outs, uint256(100_000));
        bytes memory adder = hex"6000356020350160005260206000f3";
        bytes memory const42 = hex"602a60005260206000f3";
        bytes memory loop = hex"5b600056";
        bytes memory ef = hex"ef00";
        assertTrue(pio.verify(params, adder));
        assertFalse(pio.verify(params, const42));
        assertFalse(pio.verify(params, loop)); // out of gas -> false
        assertFalse(pio.verify(params, ef)); // EIP-3541 rejected
        assertFalse(pio.verify(params, ""));
    }

    function test_programIOThroughEngine() public {
        engine.setNumRungs(1);
        bytes[] memory ins = new bytes[](1);
        bytes[] memory outs = new bytes[](1);
        ins[0] = abi.encode(uint256(5), uint256(6));
        outs[0] = abi.encode(uint256(11));
        bytes memory params = abi.encode(ins, outs, uint256(100_000));
        uint256 id = engine.startRound();
        bytes32[] memory h = new bytes32[](1);
        address[] memory v = new address[](1);
        string[] memory u = new string[](1);
        h[0] = keccak256(abi.encode(params, PSALT));
        v[0] = address(pio);
        u[0] = "ipfs://write-an-adder";
        vm.prank(generator);
        engine.postPuzzles(id, h, v, u);
        bytes memory adder = hex"6000356020350160005260206000f3";
        commitAs(alice, id, 0, adder, bytes32(uint256(9)));
        vm.warp(engine.commitEndOf(id));
        engine.revealPuzzle(id, 0, params, PSALT);
        revealAs(alice, id, 0, adder, bytes32(uint256(9)));
        assertEq(rungDistinct(id, 0), 1);
    }

    function test_constraintScheduleVerifier() public view {
        uint256[3][] memory c = new uint256[3][](4);
        c[0] = [uint256(0), 0, 1]; // t0 != t1
        c[1] = [uint256(1), 0, 2]; // t0 < t2
        c[2] = [uint256(2), 1, 0]; // t1 == slot 0
        c[3] = [uint256(3), 2, 1]; // at most 1 task in slot 2
        bytes memory params = abi.encode(uint256(3), uint256(3), c);
        uint256[] memory good = new uint256[](3);
        good[0] = 1;
        good[1] = 0;
        good[2] = 2;
        assertTrue(cs.verify(params, abi.encode(good)));
        uint256[] memory bad = new uint256[](3);
        bad[0] = 0;
        bad[1] = 0;
        bad[2] = 2; // violates t0 != t1
        assertFalse(cs.verify(params, abi.encode(bad)));
        uint256[] memory badPrec = new uint256[](3);
        badPrec[0] = 2;
        badPrec[1] = 0;
        badPrec[2] = 1; // t0 < t2 violated
        assertFalse(cs.verify(params, abi.encode(badPrec)));
    }

    function test_subsetSumVerifierEdgeCases() public view {
        bytes memory p = subsetParams();
        assertTrue(ss.verify(p, ans2(0, 3)));
        assertFalse(ss.verify(p, ans2(3, 0))); // not increasing
        assertFalse(ss.verify(p, ans2(2, 2))); // duplicate index
        assertFalse(ss.verify(p, ans(9))); // out of range
        assertFalse(ss.verify(p, abi.encode(new uint256[](0))));
    }

    function test_forecastWindowBlocksEarlyPosting() public {
        engine.setForecastEnabled(true);
        uint256 id = engine.startRound();
        bytes32[] memory h = new bytes32[](5);
        address[] memory v = new address[](5);
        string[] memory u = new string[](5);
        vm.prank(generator);
        vm.expectRevert(PoFEngine.BadPhase.selector);
        engine.postPuzzles(id, h, v, u);
    }

    function test_cannotStartOverlappingRounds() public {
        engine.startRound();
        vm.expectRevert(PoFEngine.BadPhase.selector);
        engine.startRound();
    }
}
