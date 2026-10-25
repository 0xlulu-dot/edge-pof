// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base.t.sol";
import {SpaceIdAgentGate, ISidReverseLookup} from "../contracts/identity/SpaceIdAgentGate.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract MockLookup is ISidReverseLookup {
    mapping(address => string) public names;
    bool public broken;

    function set(address a, string calldata n) external {
        names[a] = n;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function getName(address a) external view returns (string memory) {
        require(!broken, "down");
        return names[a];
    }
}

contract GateTest is Base {
    function test_nonAgentCommitRejected() public {
        uint256 id = startAndPost();
        vm.prank(mallory);
        vm.expectRevert(PoFEngine.NotAgent.selector);
        engine.commit(id, 0, keccak256("x"));
    }

    function test_nonAgentBountyCommitRejected() public {
        vm.prank(publisher);
        uint256 id = bb.postBounty(address(token), 100e18, address(ss), subsetParams(), uint64(block.timestamp + 1 days));
        vm.prank(mallory);
        vm.expectRevert(BountyBoard.NotAgent.selector);
        bb.commit(id, keccak256("x"));
    }

    function test_spaceIdGateSuffix() public {
        MockLookup lk = new MockLookup();
        SpaceIdAgentGate g = new SpaceIdAgentGate(address(lk), admin);
        lk.set(alice, "alice.ai");
        lk.set(bob, "bob.bnb");
        lk.set(carol, ".ai");
        assertTrue(g.isAgent(alice));
        assertFalse(g.isAgent(bob));
        assertFalse(g.isAgent(carol)); // empty label
        assertFalse(g.isAgent(mallory)); // no name
        lk.setBroken(true);
        assertFalse(g.isAgent(alice)); // lookup failure fails closed
    }

    function test_spaceIdGatePluggedIntoEngine() public {
        MockLookup lk = new MockLookup();
        SpaceIdAgentGate g = new SpaceIdAgentGate(address(lk), admin);
        lk.set(mallory, "mallory.ai");
        engine.setIdentityGate(address(g));
        uint256 id = startAndPost();
        commitAs(mallory, id, 0, ans(4), bytes32(uint256(1))); // now passes
        vm.prank(alice); // alice has no .ai name under the new gate
        vm.expectRevert(PoFEngine.NotAgent.selector);
        engine.commit(id, 0, keccak256("y"));
    }

    /// @notice gate swap is only possible through the 7-day TimelockController
    function test_gateSwapRequiresTimelock() public {
        address[] memory props = new address[](1);
        props[0] = admin;
        TimelockController tl = new TimelockController(7 days, props, props, address(0));
        engine.grantRole(engine.GOVERNANCE_ROLE(), address(tl));
        engine.grantRole(engine.DEFAULT_ADMIN_ROLE(), address(tl));
        engine.renounceRole(engine.GOVERNANCE_ROLE(), admin);
        engine.renounceRole(engine.DEFAULT_ADMIN_ROLE(), admin);

        MockAgentGate g2 = new MockAgentGate();
        vm.expectRevert();
        engine.setIdentityGate(address(g2)); // direct call no longer allowed

        bytes memory data = abi.encodeCall(PoFEngine.setIdentityGate, (address(g2)));
        tl.schedule(address(engine), 0, data, bytes32(0), bytes32(0), 7 days);
        vm.expectRevert();
        tl.execute(address(engine), 0, data, bytes32(0), bytes32(0)); // too early
        vm.warp(block.timestamp + 7 days);
        tl.execute(address(engine), 0, data, bytes32(0), bytes32(0));
        assertEq(address(engine.identityGate()), address(g2));
    }
}
