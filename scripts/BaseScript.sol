// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import { Create2Lib } from "src/libraries/Create2Lib.sol";
import { ReservoirDeployer } from "src/ReservoirDeployer.sol";

contract BaseScript is Script {
    ReservoirDeployer internal _deployer;

    function _ensureDeployerExists(uint256 aPrivateKey) internal {
        bytes memory lInitCode = abi.encodePacked(type(ReservoirDeployer).creationCode);

        address lDeployer = Create2Lib.computeAddress(address(this), lInitCode, bytes32(0));
        if (lDeployer.code.length == 0) {
            vm.broadcast(aPrivateKey);
            _deployer = new ReservoirDeployer{salt: bytes32(0)}();

            require(address(_deployer) != address(0), "DEPLOY FACTORY FAILED");
        } else {
            _deployer = ReservoirDeployer(lDeployer);
        }
    }
}
