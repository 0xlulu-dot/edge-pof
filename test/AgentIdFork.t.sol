// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base.t.sol";
import {AgentIdNftGate, IERC721Balance} from "../contracts/identity/AgentIdNftGate.sol";

interface IAgentIdNft is IERC721Balance {
    function ownerOf(uint256 id) external view returns (address);
    function name() external view returns (string memory);
    function transferFrom(address from, address to, uint256 id) external;
}

/// @notice Runs against a BSC mainnet fork. Skipped unless BSC_RPC is set:
///   BSC_RPC=https://bsc.rpc.blxrbdn.com forge test --match-contract AgentIdFork -vv
contract AgentIdForkTest is Base {
    address constant REG = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    // real Agent ID holder (minted on BSC mainnet, block 0x7bb04d1)
    address constant HOLDER = 0xAf8091A64f9C85Dd272805a9aad2ED4660a79Ce4;
    uint256 constant HOLDER_ID = 0x1f1abcfa6b5e5ba6fdd92d3636a14d401db62e20b075812b98a8dc6b876e26bf;

    AgentIdNftGate g;
    bool forked;

    function setUp() public override {
        string memory rpc = vm.envOr("BSC_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        super.setUp();
        g = new AgentIdNftGate(REG, admin);
        engine.setIdentityGate(address(g));
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
        }
        _;
    }

    function test_fork_registryIsRealAgentId() public onlyFork {
        assertEq(IAgentIdNft(REG).name(), "SPACE ID Agent ID");
        assertEq(IAgentIdNft(REG).ownerOf(HOLDER_ID), HOLDER);
        assertEq(g.BSC_MAINNET_AGENT_ID(), REG);
    }

    function test_fork_holderPassesNonHolderFails() public onlyFork {
        assertTrue(g.isAgent(HOLDER));
        assertFalse(g.isAgent(mallory));
        assertFalse(g.isAgent(address(0)));
    }

    function test_fork_soulboundCannotLendId() public onlyFork {
        vm.prank(HOLDER);
        vm.expectRevert(bytes4(keccak256("Soulbound()")));
        IAgentIdNft(REG).transferFrom(HOLDER, mallory, HOLDER_ID);
        assertFalse(g.isAgent(mallory));
    }

    function test_fork_engineCommitGated() public onlyFork {
        uint256 id = startAndPost();
        vm.prank(mallory);
        vm.expectRevert(PoFEngine.NotAgent.selector);
        engine.commit(id, 0, keccak256("x"));

        deal(address(token), HOLDER, 1_000e18);
        vm.prank(HOLDER);
        token.approve(address(engine), type(uint256).max);
        commitAs(HOLDER, id, 0, ans(4), bytes32(uint256(7))); // real Agent ID passes
    }

    function test_fork_noCodeRegistryRejected() public onlyFork {
        vm.expectRevert(AgentIdNftGate.NotContract.selector);
        new AgentIdNftGate(address(0xBEEF), admin);
        vm.prank(admin);
        vm.expectRevert(AgentIdNftGate.NotContract.selector);
        g.setRegistry(address(0));
    }

    function test_fork_onlyOwnerSetsRegistry() public onlyFork {
        vm.prank(mallory);
        vm.expectRevert();
        g.setRegistry(REG);
    }
}
