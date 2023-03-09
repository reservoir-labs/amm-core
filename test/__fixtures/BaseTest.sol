// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { MintableERC20 } from "test/__fixtures/MintableERC20.sol";

import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { Create2Lib } from "src/libraries/Create2Lib.sol";
import { OracleCaller } from "src/oracle/OracleCaller.sol";

import { ReservoirDeployer } from "src/ReservoirDeployer.sol";
import { GenericFactory } from "src/GenericFactory.sol";
import { ReservoirPair } from "src/ReservoirPair.sol";
import { ConstantProductPair } from "src/curve/constant-product/ConstantProductPair.sol";
import { StablePair, AmplificationData } from "src/curve/stable/StablePair.sol";
import { StableMintBurn } from "src/curve/stable/StableMintBurn.sol";

abstract contract BaseTest is Test {
    using FactoryStoreLib for GenericFactory;

    GenericFactory internal _factory = _create2Factory();

    address internal _recoverer = address(_deployer);
    address internal _platformFeeTo = address(_deployer);
    address internal _alice = _makeAddress("alice");
    address internal _bob = _makeAddress("bob");
    address internal _cal = _makeAddress("cal");

    MintableERC20 internal _tokenA = new MintableERC20("TokenA", "TA", 18);
    MintableERC20 internal _tokenB = new MintableERC20("TokenB", "TB", 18);
    MintableERC20 internal _tokenC = new MintableERC20("TokenC", "TC", 18);
    MintableERC20 internal _tokenD = new MintableERC20("TokenD", "TD", 6);
    MintableERC20 internal _tokenE = new MintableERC20("TokenF", "TF", 25);

    ConstantProductPair internal _constantProductPair;
    StablePair internal _stablePair;

    OracleCaller internal _oracleCaller;

    constructor() {
        try vm.envString("FOUNDRY_PROFILE") returns (string memory lProfile) {
            if (keccak256(abi.encodePacked(lProfile)) == keccak256(abi.encodePacked("coverage"))) {
                vm.writeJson(
                    _deployerMetadata(),
                    "scripts/unoptimized-deployer-meta"
                );
            }
        } catch {
            vm.writeJson(
                _deployerMetadata(),
                "scripts/optimized-deployer-meta"
            );
        }

        // Execute standard & deterministic Reservoir deployment.
        _factory = _deployer.deployFactory(type(GenericFactory).creationCode);
        _deployer.deployConstantProduct(type(ConstantProductPair).creationCode);
        _deployer.deployStable(type(StablePair).creationCode);
        _oracleCaller = _deployer.deployOracleCaller(type(OracleCaller).creationCode);


        // Claim ownership of all contracts for our test contract.
        vm.prank(address(123));
        _deployer.proposeOwner(address(this));
        _deployer.claimOwnership();
        _deployer.claimFactory();
        _deployer.claimOracleCaller();

        // Whitelist our test contract to call the oracle.
        _oracleCaller.whitelistAddress(address(this), true);

        // Setup default ConstantProductPair.
        _constantProductPair = ConstantProductPair(_createPair(address(_tokenA), address(_tokenB), 0));
        _tokenA.mint(address(_constantProductPair), ConstantsLib.INITIAL_MINT_AMOUNT);
        _tokenB.mint(address(_constantProductPair), ConstantsLib.INITIAL_MINT_AMOUNT);
        _constantProductPair.mint(_alice);

        // Setup default StablePair.
        _stablePair = StablePair(_createPair(address(_tokenA), address(_tokenB), 1));
        _tokenA.mint(address(_stablePair), ConstantsLib.INITIAL_MINT_AMOUNT);
        _tokenB.mint(address(_stablePair), ConstantsLib.INITIAL_MINT_AMOUNT);
        _stablePair.mint(_alice);
    }

    function _deployerMetadata() private returns (string memory rDeployerMetadata) {
        string memory lObjectKey = "qwerty";

        vm.serializeBytes32(lObjectKey, "factory_hash", keccak256(type(GenericFactory).creationCode));
        vm.serializeBytes32(lObjectKey, "constant_product_hash", keccak256(type(ConstantProductPair).creationCode));
        vm.serializeBytes32(lObjectKey, "stable_hash", keccak256(type(StablePair).creationCode));
        rDeployerMetadata = vm.serializeBytes32(lObjectKey, "oracle_caller_hash", keccak256(type(OracleCaller).creationCode));
    }

    function _ensureDeployerExists() internal returns (ReservoirDeployer rDeployer) {
        bytes memory lInitCode = abi.encodePacked(type(ReservoirDeployer).creationCode);

        address lDeployer = Create2Lib.computeAddress(address(this), lInitCode, bytes32(0));
        if (lDeployer.code.length == 0) {
            rDeployer = new ReservoirDeployer{salt: bytes32(0)}();

            require(address(rDeployer) != address(0), "DEPLOY FACTORY FAILED");
        } else {
            rDeployer = ReservoirDeployer(lDeployer);
        }
    }

    function _makeAddress(string memory aName) internal returns (address) {
        address lAddress = address(uint160(uint256(keccak256(abi.encodePacked(aName)))));
        vm.label(lAddress, aName);

        return lAddress;
    }

    function _createPair(address aTokenA, address aTokenB, uint256 aCurveId) internal returns (address rPair) {
        rPair = _factory.createPair(aTokenA, aTokenB, aCurveId);
    }

    function _stepTime(uint256 aTime) internal {
        vm.roll(block.number + 1);
        skip(aTime);
    }

    function _writeObservation(
        ReservoirPair aPair,
        uint256 aIndex,
        int112 aRawPrice,
        int56 aClampedPrice,
        int56 aLiq,
        uint32 aTime
    ) internal {
        require(aTime < 2 ** 31, "TIMESTAMP TOO BIG");
        bytes32 lEncoded = bytes32(
            bytes.concat(
                bytes4(aTime), bytes7(uint56(aLiq)), bytes7(uint56(aClampedPrice)), bytes14(uint112(aRawPrice))
            )
        );

        vm.record();
        _oracleCaller.observation(aPair, aIndex);
        (bytes32[] memory lAccesses,) = vm.accesses(address(aPair));
        require(lAccesses.length == 2, "invalid number of accesses");

        vm.store(address(aPair), lAccesses[1], lEncoded);
    }
}
