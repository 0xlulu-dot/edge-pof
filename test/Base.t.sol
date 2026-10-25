// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {EDGEToken} from "../contracts/EDGEToken.sol";
import {PoFEngine} from "../contracts/PoFEngine.sol";
import {ForecastMarket} from "../contracts/ForecastMarket.sol";
import {BountyBoard} from "../contracts/BountyBoard.sol";
import {FeeCollector} from "../contracts/FeeCollector.sol";
import {AirdropDistributor} from "../contracts/AirdropDistributor.sol";
import {MockAgentGate} from "../contracts/identity/MockAgentGate.sol";
import {MockRandomness} from "../contracts/randomness/MockRandomness.sol";
import {SubsetSumVerifier} from "../contracts/verifiers/SubsetSumVerifier.sol";
import {ConstraintScheduleVerifier} from "../contracts/verifiers/ConstraintScheduleVerifier.sol";
import {ProgramIOVerifier} from "../contracts/verifiers/ProgramIOVerifier.sol";
import {IPoFEngine} from "../contracts/interfaces/IPoFEngine.sol";
import {IAgentIdentity} from "../contracts/interfaces/IAgentIdentity.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("Tether USD", "USDT") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

abstract contract Base is Test {
    EDGEToken token;
    PoFEngine engine;
    ForecastMarket fm;
    BountyBoard bb;
    FeeCollector fc;
    AirdropDistributor airdrop;
    MockAgentGate gate;
    MockRandomness rnd;
    SubsetSumVerifier ss;
    ConstraintScheduleVerifier cs;
    ProgramIOVerifier pio;
    MockUSDT usdt;

    address admin = address(this);
    address generator = makeAddr("generator");
    address pauser = makeAddr("pauser");
    address arbiter = makeAddr("arbiter");
    address liquidity = makeAddr("liquidity");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address mallory = makeAddr("mallory"); // not an agent
    address publisher = makeAddr("publisher");

    bytes32 constant PSALT = keccak256("puzzle-salt");

    function setUp() public virtual {
        airdrop = new AirdropDistributor(bytes32(0), block.timestamp + 90 days);
        token = new EDGEToken(liquidity, address(airdrop));
        airdrop.initToken(token);
        gate = new MockAgentGate();
        rnd = new MockRandomness();
        engine = new PoFEngine(token, gate, rnd, admin, generator, pauser);
        token.setMinter(address(engine));

        ss = new SubsetSumVerifier();
        cs = new ConstraintScheduleVerifier();
        pio = new ProgramIOVerifier();
        engine.setVerifier(address(ss), true);
        engine.setVerifier(address(cs), true);
        engine.setVerifier(address(pio), true);

        fc = new FeeCollector(admin);
        bb = new BountyBoard(token, IPoFEngine(address(engine)), fc, IAgentIdentity(address(gate)), admin, arbiter, pauser);
        fc.grantRole(fc.FEE_SOURCE_ROLE(), address(bb));
        engine.setBountyBoard(address(bb));
        fm = new ForecastMarket(token, IPoFEngine(address(engine)), admin);
        engine.setForecastMarket(address(fm));

        usdt = new MockUSDT();
        bb.setVerifier(address(ss), true);
        bb.setVerifier(address(pio), true);
        bb.setToken(address(usdt), true, 2e18); // 1 USDT = 2 EDGE
        bb.setToken(address(token), true, 1e18);

        address[5] memory ags = [alice, bob, carol, dave, publisher];
        for (uint256 i = 0; i < ags.length; i++) {
            if (ags[i] != publisher) gate.setAgent(ags[i], true);
            vm.prank(liquidity);
            token.transfer(ags[i], 10_000e18);
            vm.startPrank(ags[i]);
            token.approve(address(engine), type(uint256).max);
            token.approve(address(bb), type(uint256).max);
            token.approve(address(fm), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(liquidity);
        token.transfer(mallory, 1_000e18);
        vm.prank(mallory);
        token.approve(address(engine), type(uint256).max);
    }

    // ----------------------------- puzzle fixtures -----------------------------
    /// set [1,2,3,4,5] target 5 -> distinct answers {4}, {0,3}, {1,2}
    function subsetParams() internal pure returns (bytes memory) {
        uint256[] memory set = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            set[i] = i + 1;
        }
        return abi.encode(set, uint256(5));
    }

    function ans(uint256 a) internal pure returns (bytes memory) {
        uint256[] memory x = new uint256[](1);
        x[0] = a;
        return abi.encode(x);
    }

    function ans2(uint256 a, uint256 b) internal pure returns (bytes memory) {
        uint256[] memory x = new uint256[](2);
        x[0] = a;
        x[1] = b;
        return abi.encode(x);
    }

    function startAndPost() internal returns (uint256 id) {
        id = engine.startRound();
        uint8 n = engine.numRungs();
        bytes32[] memory h = new bytes32[](n);
        address[] memory v = new address[](n);
        string[] memory u = new string[](n);
        bytes memory p = subsetParams();
        for (uint8 i = 0; i < n; i++) {
            h[i] = keccak256(abi.encode(p, keccak256(abi.encode(PSALT, i))));
            v[i] = address(ss);
            u[i] = "ipfs://prompt";
        }
        if (engine.forecastEnabled()) vm.warp(engine.forecastEndOf(id));
        vm.prank(generator);
        engine.postPuzzles(id, h, v, u);
    }

    function commitAs(address who, uint256 id, uint8 rung, bytes memory answer, bytes32 salt) internal {
        vm.prank(who);
        engine.commit(id, rung, keccak256(abi.encode(answer, salt, who)));
    }

    function revealPuzzles(uint256 id) internal {
        vm.warp(engine.commitEndOf(id));
        uint8 n = engine.numRungs();
        for (uint8 i = 0; i < n; i++) {
            engine.revealPuzzle(id, i, subsetParams(), keccak256(abi.encode(PSALT, i)));
        }
    }

    function revealAs(address who, uint256 id, uint8 rung, bytes memory answer, bytes32 salt) internal {
        vm.prank(who);
        engine.revealAnswer(id, rung, answer, salt);
    }

    function endAndSettle(uint256 id) internal {
        vm.warp(engine.roundEndOf(id));
        engine.settle(id);
    }

    function rungPayout(uint256 id, uint8 rung) internal view returns (uint256 p) {
        (,,,,,,, p,) = engine.rungs(id, rung);
    }

    function rungSumR(uint256 id, uint8 rung) internal view returns (uint256 s) {
        (,,,,,, s,,) = engine.rungs(id, rung);
    }

    function rungDistinct(uint256 id, uint8 rung) internal view returns (uint32 d) {
        (,,,,, d,,,) = engine.rungs(id, rung);
    }

    function rungBucket(uint256 id, uint8 rung) internal view returns (uint8 b) {
        (,,,, b,,,,) = engine.rungs(id, rung);
    }

    function roundPool(uint256 id) internal view returns (uint256 p) {
        (,,,,,,, p,,) = engine.rounds(id);
    }

    /// @dev one full round where `who` solves rung 0 correctly (R += 0.05)
    function solveOneRound(address who) internal {
        uint256 id = startAndPost();
        commitAs(who, id, 0, ans(4), bytes32(uint256(1)));
        revealPuzzles(id);
        revealAs(who, id, 0, ans(4), bytes32(uint256(1)));
        endAndSettle(id);
    }
}
