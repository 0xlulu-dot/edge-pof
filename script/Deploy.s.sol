// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {EDGEToken} from "../contracts/EDGEToken.sol";
import {PoFEngine} from "../contracts/PoFEngine.sol";
import {ForecastMarket} from "../contracts/ForecastMarket.sol";
import {BountyBoard} from "../contracts/BountyBoard.sol";
import {FeeCollector} from "../contracts/FeeCollector.sol";
import {AirdropDistributor} from "../contracts/AirdropDistributor.sol";
import {MockAgentGate} from "../contracts/identity/MockAgentGate.sol";
import {AgentIdNftGate} from "../contracts/identity/AgentIdNftGate.sol";
import {SpaceIdAgentGate} from "../contracts/identity/SpaceIdAgentGate.sol";
import {MockRandomness} from "../contracts/randomness/MockRandomness.sol";
import {SubsetSumVerifier} from "../contracts/verifiers/SubsetSumVerifier.sol";
import {ConstraintScheduleVerifier} from "../contracts/verifiers/ConstraintScheduleVerifier.sol";
import {ProgramIOVerifier} from "../contracts/verifiers/ProgramIOVerifier.sol";
import {IPoFEngine} from "../contracts/interfaces/IPoFEngine.sol";
import {IAgentIdentity} from "../contracts/interfaces/IAgentIdentity.sol";
import {IRandomness} from "../contracts/interfaces/IRandomness.sol";

/// @notice BSC TESTNET (chainId 97) deployment. NOT EXECUTED by the build — review first.
///
///   export PRIVATE_KEY=0x...            # testnet-only throwaway key, never a funded mainnet key
///   export BSC_TESTNET_RPC=https://...
///   export MULTISIG=0x...               # timelock proposer/executor (defaults to deployer)
///   export GENERATOR=0x... GUARDIAN=0x... LIQUIDITY=0x...
///   export AIRDROP_ROOT=0x...           # merkle root of the calibration airdrop
///   export AGENT_ID_REGISTRY=0x...      # optional; soulbound Agent ID ERC721 (mainnet: 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F)
///   export SID_LOOKUP=0x...             # legacy; both unset -> MockAgentGate (testnet only)
///   export USDT=0x... USDT_EDGE_PRICE=2000000000000000000   # optional
///   forge script script/Deploy.s.sol --rpc-url $BSC_TESTNET_RPC --broadcast
contract Deploy is Script {
    function run() external {
        require(block.chainid == 97, "BSC testnet only");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address multisig = vm.envOr("MULTISIG", deployer);
        address generator = vm.envOr("GENERATOR", deployer);
        address guardian = vm.envOr("GUARDIAN", deployer);
        address liquidity = vm.envOr("LIQUIDITY", deployer);
        bytes32 root = vm.envOr("AIRDROP_ROOT", bytes32(0));
        address agentReg = vm.envOr("AGENT_ID_REGISTRY", address(0));
        address sidLookup = vm.envOr("SID_LOOKUP", address(0));
        address usdt = vm.envOr("USDT", address(0));
        uint256 usdtPrice = vm.envOr("USDT_EDGE_PRICE", uint256(0));

        vm.startBroadcast(pk);

        address[] memory ops = new address[](1);
        ops[0] = multisig;
        TimelockController timelock = new TimelockController(7 days, ops, ops, address(0));

        AirdropDistributor airdrop = new AirdropDistributor(root, block.timestamp + 180 days);
        EDGEToken token = new EDGEToken(liquidity, address(airdrop));
        airdrop.initToken(token);

        IAgentIdentity gate;
        if (agentReg != address(0)) {
            gate = new AgentIdNftGate(agentReg, address(timelock));
        } else if (sidLookup != address(0)) {
            gate = new SpaceIdAgentGate(sidLookup, address(timelock));
        } else {
            gate = new MockAgentGate(); // TODO(SPACE ID): testnet only
        }
        IRandomness rnd = new MockRandomness(); // TODO(Chainlink VRF): swap via setRandomness

        PoFEngine engine = new PoFEngine(token, gate, rnd, deployer, generator, guardian);
        token.setMinter(address(engine));

        SubsetSumVerifier ss = new SubsetSumVerifier();
        ConstraintScheduleVerifier cs = new ConstraintScheduleVerifier();
        ProgramIOVerifier pio = new ProgramIOVerifier();
        engine.setVerifier(address(ss), true);
        engine.setVerifier(address(cs), true);
        engine.setVerifier(address(pio), true);

        FeeCollector fc = new FeeCollector(deployer);
        BountyBoard bb = new BountyBoard(token, IPoFEngine(address(engine)), fc, gate, deployer, address(timelock), guardian);
        fc.grantRole(fc.FEE_SOURCE_ROLE(), address(bb));
        engine.setBountyBoard(address(bb));
        ForecastMarket fm = new ForecastMarket(token, IPoFEngine(address(engine)), deployer);
        engine.setForecastMarket(address(fm)); // forecastEnabled stays false

        bb.setVerifier(address(ss), true);
        bb.setVerifier(address(cs), true);
        bb.setVerifier(address(pio), true);
        bb.setToken(address(token), true, 1e18);
        if (usdt != address(0)) bb.setToken(usdt, true, usdtPrice);

        // ---- hand every admin/governance role to the 7-day timelock, then renounce ----
        engine.grantRole(engine.DEFAULT_ADMIN_ROLE(), address(timelock));
        engine.grantRole(engine.GOVERNANCE_ROLE(), address(timelock));
        engine.grantRole(engine.ORACLE_ROLE(), address(timelock));
        engine.renounceRole(engine.ORACLE_ROLE(), deployer);
        engine.renounceRole(engine.GOVERNANCE_ROLE(), deployer);
        engine.renounceRole(engine.DEFAULT_ADMIN_ROLE(), deployer);

        bb.grantRole(bb.DEFAULT_ADMIN_ROLE(), address(timelock));
        bb.grantRole(bb.GOVERNANCE_ROLE(), address(timelock));
        bb.renounceRole(bb.GOVERNANCE_ROLE(), deployer);
        bb.renounceRole(bb.DEFAULT_ADMIN_ROLE(), deployer);

        fm.grantRole(fm.DEFAULT_ADMIN_ROLE(), address(timelock));
        fm.grantRole(fm.GOVERNANCE_ROLE(), address(timelock));
        fm.renounceRole(fm.GOVERNANCE_ROLE(), deployer);
        fm.renounceRole(fm.DEFAULT_ADMIN_ROLE(), deployer);

        fc.grantRole(fc.DEFAULT_ADMIN_ROLE(), address(timelock));
        fc.grantRole(fc.GOVERNANCE_ROLE(), address(timelock));
        fc.renounceRole(fc.GOVERNANCE_ROLE(), deployer);
        fc.renounceRole(fc.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();

        console2.log("Timelock      ", address(timelock));
        console2.log("EDGEToken     ", address(token));
        console2.log("Airdrop       ", address(airdrop));
        console2.log("IdentityGate  ", address(gate));
        console2.log("PoFEngine     ", address(engine));
        console2.log("BountyBoard   ", address(bb));
        console2.log("ForecastMarket", address(fm));
        console2.log("FeeCollector  ", address(fc));
    }
}
