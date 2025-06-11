// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import { EulerV2Manager } from "../src/asset-management/EulerV2Manager.sol";

contract DeployScript is Script {
    EulerV2Manager internal _manager;

    function run() external {
        _deployAssetManager();
    }

    function _deployAssetManager() internal {
        vm.startBroadcast(msg.sender);
        _manager = new EulerV2Manager(); // cannot use create2 to deploy it as the create2 contract will be its owner
        vm.stopBroadcast();

        require(_manager.owner() == msg.sender, "WRONG OWNER");
    }
}
