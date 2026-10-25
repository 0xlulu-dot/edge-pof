// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base.t.sol";

contract ForecastTest is Base {
    address whale = makeAddr("whale");
    address goodF = makeAddr("goodF");
    address badF = makeAddr("badF");

    function setUp() public override {
        super.setUp();
        engine.setForecastEnabled(true);
        address[3] memory fs = [whale, goodF, badF];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(liquidity);
            token.transfer(fs[i], 100_000e18);
            vm.prank(fs[i]);
            token.approve(address(fm), type(uint256).max);
        }
        vm.prank(whale);
        fm.stake(90_000e18);
        vm.prank(goodF);
        fm.stake(1_000e18);
        vm.prank(badF);
        fm.stake(1_000e18);
    }

    /// rung0 -> bucket1 (one solver, n_eff<2); rungs 1..4 -> bucket0
    function _perfect() internal pure returns (uint256[] memory p) {
        p = new uint256[](20);
        p[1] = 1e18;
        for (uint256 r = 1; r < 5; r++) {
            p[r * 4] = 1e18;
        }
    }

    function _decent() internal pure returns (uint256[] memory p) {
        p = new uint256[](20);
        p[0] = 0.2e18;
        p[1] = 0.6e18;
        p[2] = 0.1e18;
        p[3] = 0.1e18;
        for (uint256 r = 1; r < 5; r++) {
            p[r * 4] = 0.7e18;
            p[r * 4 + 1] = 0.1e18;
            p[r * 4 + 2] = 0.1e18;
            p[r * 4 + 3] = 0.1e18;
        }
    }

    function _awful() internal pure returns (uint256[] memory p) {
        p = new uint256[](20);
        for (uint256 r = 0; r < 5; r++) {
            p[r * 4 + 3] = 1e18;
        }
    }

    function test_forecastFullCycle() public {
        uint256 id = engine.startRound();
        vm.prank(whale);
        fm.submitForecast(id, _perfect());
        vm.prank(goodF);
        fm.submitForecast(id, _decent());
        vm.prank(badF);
        fm.submitForecast(id, _awful());

        // puzzles post after forecast window
        bytes32[] memory h = new bytes32[](5);
        address[] memory v = new address[](5);
        string[] memory u = new string[](5);
        for (uint8 i = 0; i < 5; i++) {
            h[i] = keccak256(abi.encode(subsetParams(), keccak256(abi.encode(PSALT, i))));
            v[i] = address(ss);
        }
        vm.warp(engine.forecastEndOf(id));
        vm.prank(generator);
        engine.postPuzzles(id, h, v, u);
        // late forecast rejected
        vm.prank(alice);
        fm.stake(200e18);
        vm.prank(alice);
        vm.expectRevert(ForecastMarket.BadPhase.selector);
        fm.submitForecast(id, _perfect());

        commitAs(alice, id, 0, ans(4), bytes32(uint256(1)));
        revealPuzzles(id);
        revealAs(alice, id, 0, ans(4), bytes32(uint256(1)));
        endAndSettle(id);

        uint256 budget = engine.forecastBudget(id);
        assertEq(budget, roundPool(id) - roundPool(id) * 8000 / 10000);

        uint256 supply0 = token.totalSupply();
        fm.score(id, whale);
        fm.score(id, goodF);
        fm.score(id, badF);
        assertEq(fm.brierOf(id, whale), 0);
        assertEq(fm.brierOf(id, badF), 2e18);
        assertEq(token.totalSupply(), supply0 - 100e18); // 10% of badF stake burned
        assertEq(fm.staked(badF), 900e18);

        vm.warp(block.timestamp + 2 days);
        vm.prank(whale);
        uint256 wGot = fm.claim(id);
        vm.prank(goodF);
        uint256 gGot = fm.claim(id);
        // 2% per-address weight cap: whale cannot take more than 2% of the pool
        assertLe(wGot, budget * 2 / 100 + 1);
        assertLe(gGot, budget * 2 / 100 + 1);
        vm.prank(badF);
        vm.expectRevert(ForecastMarket.BadPhase.selector);
        fm.claim(id);

        // sweep the rest after the claim window: 50% burned / 50% rolled over
        vm.warp(block.timestamp + 5 days);
        uint256 roll0 = engine.rolloverPool();
        uint256 burn0 = engine.totalBurnedUnminted();
        fm.sweep(id);
        uint256 unused = budget - wGot - gGot;
        assertEq(engine.rolloverPool() - roll0 + engine.totalBurnedUnminted() - burn0, unused);
    }

    function test_disabledByDefault() public {
        engine.setForecastEnabled(false);
        uint256 id = engine.startRound();
        vm.prank(whale);
        vm.expectRevert(ForecastMarket.BadPhase.selector);
        fm.submitForecast(id, _perfect());
    }

    function test_rowsMustSumToOne() public {
        uint256 id = engine.startRound();
        uint256[] memory p = _perfect();
        p[0] = 1;
        vm.prank(whale);
        vm.expectRevert(ForecastMarket.BadParam.selector);
        fm.submitForecast(id, p);
    }

    function test_unbonding7Days() public {
        vm.prank(goodF);
        fm.requestUnbond(1_000e18);
        vm.warp(block.timestamp + 7 days - 1);
        vm.prank(goodF);
        vm.expectRevert(ForecastMarket.BadPhase.selector);
        fm.withdraw();
        vm.warp(block.timestamp + 1);
        vm.prank(goodF);
        fm.withdraw();
        assertEq(token.balanceOf(goodF), 100_000e18);
    }

    function test_onlyMarketCanCredit() public {
        vm.expectRevert(PoFEngine.NotAllowed.selector);
        engine.creditForecast(1, alice, 1);
    }
}
