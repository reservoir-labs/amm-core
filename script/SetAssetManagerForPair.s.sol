// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import { ReservoirDeployer, GenericFactory } from "src/ReservoirDeployer.sol";
import { AaveManager, IAssetManagedPair} from "src/asset-management/AaveManager.sol";

contract SetAssetManagerForPair is Script {

    ReservoirDeployer internal _deployer = ReservoirDeployer(0xe5f6124f51D61C3b7C4D689768B1c55975b1c0F4);
    AaveManager internal _assetManager = AaveManager(0x55231617f7E260358022534DB5114F671A3254B1);

    function run() external {
        _setManagerForPair(IAssetManagedPair(0x55231617f7E260358022534DB5114F671A3254B1));
    }

    function _setManagerForPair(IAssetManagedPair aPair) internal {
        vm.startBroadcast();
        GenericFactory lFactory = _deployer.factory();

        bytes memory lCalldataForFactory = abi.encodeCall(IAssetManagedPair.setManager, (_assetManager));
        bytes memory lCalldataForDeployer = abi.encodeCall(lFactory.rawCall, (address(aPair) , lCalldataForFactory, 0));
        _deployer.rawCall(address(lFactory), lCalldataForDeployer, 0);

        vm.stopBroadcast();

        require(aPair.assetManager() == _assetManager, "MANAGER_NOT_SET_CORRECTLY");
    }
}
