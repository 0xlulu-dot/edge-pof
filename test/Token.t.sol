// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base.t.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";

contract TokenTest is Base {
    using stdStorage for StdStorage;

    function test_initialAllocations() public view {
        assertEq(token.name(), "Edge");
        assertEq(token.symbol(), "EDGE");
        assertEq(token.decimals(), 18);
        assertEq(token.totalMinted(), 8_000_000e18);
        assertEq(token.balanceOf(address(airdrop)), 3_000_000e18);
        assertEq(token.miningMinted(), 0);
        assertEq(token.minter(), address(engine));
    }

    function test_onlyMinterCanMint() public {
        vm.expectRevert(EDGEToken.NotMinter.selector);
        token.mintMining(alice, 1);
    }

    function test_minterIsOneShot() public {
        vm.expectRevert(EDGEToken.MinterAlreadySet.selector);
        token.setMinter(alice);
    }

    function test_miningCapEnforcedOnToken() public {
        vm.startPrank(address(engine));
        token.mintMining(alice, 92_000_000e18);
        vm.expectRevert(EDGEToken.MiningCapExceeded.selector);
        token.mintMining(alice, 1);
        vm.stopPrank();
        assertEq(token.totalMinted(), token.MAX_SUPPLY());
    }

    /// @notice fuzz: whatever sequence of mint attempts, cumulative mint never exceeds the caps.
    function testFuzz_capInvariant(uint256[8] memory amounts, uint256 burnSeed) public {
        vm.startPrank(address(engine));
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 a = bound(amounts[i], 0, 40_000_000e18);
            if (token.miningMinted() + a > token.MINING_CAP()) {
                vm.expectRevert(EDGEToken.MiningCapExceeded.selector);
                token.mintMining(alice, a);
            } else {
                token.mintMining(alice, a);
            }
            assertLe(token.miningMinted(), token.MINING_CAP());
            assertLe(token.totalMinted(), token.MAX_SUPPLY());
            assertLe(token.totalSupply(), token.MAX_SUPPLY());
        }
        vm.stopPrank();
        // burning never re-opens headroom (cap is on cumulative mint)
        uint256 b = bound(burnSeed, 0, token.balanceOf(alice));
        vm.prank(alice);
        token.burn(b);
        uint256 left = token.MINING_CAP() - token.miningMinted();
        vm.prank(address(engine));
        if (left > 0) token.mintMining(bob, left);
        vm.prank(address(engine));
        vm.expectRevert(EDGEToken.MiningCapExceeded.selector);
        token.mintMining(bob, 1);
    }

    /// @notice fuzz at engine level: fresh emission allocation clamps to the 92M mining cap.
    function testFuzz_engineEmissionNeverExceedsCap(uint256 preAllocated, uint8 rounds_) public {
        uint256 cap = engine.miningCap();
        preAllocated = bound(preAllocated, cap - 50_000e18, cap);
        stdstore.target(address(engine)).sig("emissionAllocated()").checked_write(preAllocated);
        uint256 n = bound(rounds_, 1, 12);
        for (uint256 i = 0; i < n; i++) {
            uint256 id = engine.startRound();
            assertLe(engine.emissionAllocated(), cap);
            vm.warp(engine.roundEndOf(id));
            engine.settle(id);
        }
        assertEq(engine.roundEmissionNow(4 hours) + engine.emissionAllocated() <= cap, true);
    }

    function test_airdropBurnRemainder() public {
        vm.warp(block.timestamp + 91 days);
        airdrop.burnRemainder();
        assertEq(token.balanceOf(address(airdrop)), 0);
        assertEq(token.totalMinted(), 8_000_000e18); // burned supply is not re-mintable
    }
}
