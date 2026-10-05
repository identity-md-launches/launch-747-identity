// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IdentityToken} from "../src/IdentityToken.sol";

/// @notice Direct (non-launch) deployment of Identity (ID).
/// @dev Under a launch the factory deploys the token itself from the manifest's constructor
///      arguments; this script is for a stand-alone deployment and for tests of the deployment
///      parameters. `run()` reads the environment and hands a config to `deploy`, which tests call
///      directly with explicit values.
contract DeployIdentityToken is Script {
    struct Config {
        address factory;
        address poolManager;
        uint64 launchNumber;
        address feeRecipient;
    }

    /// @notice Deploys the token with the given configuration. Pure of environment and caller.
    function deploy(Config memory config) public returns (IdentityToken token) {
        token = new IdentityToken(config.factory, config.poolManager, config.launchNumber, config.feeRecipient);
    }

    /// @notice Reads the configuration from the environment and broadcasts the deployment.
    /// @dev Env: ID_FACTORY, ID_POOL_MANAGER, ID_LAUNCH_NUMBER, ID_FEE_RECIPIENT (all optional; zero
    ///      means "none", and a zero fee recipient means the broadcasting deployer).
    function run() external returns (IdentityToken token) {
        Config memory config = Config({
            factory: vm.envOr("ID_FACTORY", address(0)),
            poolManager: vm.envOr("ID_POOL_MANAGER", address(0)),
            launchNumber: uint64(vm.envOr("ID_LAUNCH_NUMBER", uint256(0))),
            feeRecipient: vm.envOr("ID_FEE_RECIPIENT", address(0))
        });
        vm.startBroadcast();
        token = deploy(config);
        vm.stopBroadcast();
    }
}
