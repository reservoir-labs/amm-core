// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { Address } from "@openzeppelin/utils/Address.sol";

import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { ConstantsLib } from "src/libraries/Constants.sol";

import { OracleCaller } from "src/oracle/OracleCaller.sol";
import { GenericFactory } from "src/GenericFactory.sol";

contract ReservoirDeployer {
    using FactoryStoreLib for GenericFactory;

    // Steps.
    uint256 public constant TERMINAL_STEP = 4;
    uint256 public step = 0;

    // Bytecode hashes.
    bytes32 public constant FACTORY_HASH = bytes32(0x535b9118ebcce882ec96a31c34e8e484eec1d29ab4320d4a0ceb3947eeef7d27);
    bytes32 public constant CONSTANT_PRODUCT_HASH =
        bytes32(0xfd51d3f556dfe1107632606b7addb3613794860eaca5d37844f9fb2ce8ddc9d1);
    bytes32 public constant STABLE_HASH = bytes32(0x88ab720bfd59992965d48e10ca2792e8913d9cb7336dbf6c94e31e8fdcd23525);
    bytes32 public constant ORACLE_CALLER_HASH =
        bytes32(0x262458524d9c8928fe7fd7661236b93f6d6a9535182f48fd582a75f18bfbf85f);

    // Deployment addresses.
    GenericFactory public factory;
    OracleCaller public oracleCaller;

    constructor(address aGuardian1, address aGuardian2, address aGuardian3) {
        require(
            aGuardian1 != address(0) && aGuardian2 != address(0) && aGuardian3 != address(0),
            "DEPLOYER: GUARDIAN_ADDRESS_ZERO"
        );
        guardian1 = aGuardian1;
        guardian2 = aGuardian2;
        guardian3 = aGuardian3;
    }

    function isDone() external view returns (bool) {
        return step == TERMINAL_STEP;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            DEPLOYMENT STEPS
    //////////////////////////////////////////////////////////////////////////*/

    function deployFactory(bytes memory aFactoryBytecode) external returns (GenericFactory) {
        require(step == 0, "FAC_STEP: OUT_OF_ORDER");
        require(keccak256(aFactoryBytecode) == FACTORY_HASH, "DEPLOYER: FACTORY_HASH");

        // Manual deployment from validated bytecode.
        address lFactoryAddress;
        assembly ("memory-safe") {
            lFactoryAddress :=
                create(
                    0, // value
                    add(aFactoryBytecode, 0x20), // offset
                    mload(aFactoryBytecode) // size
                )
        }
        require(lFactoryAddress != address(0), "FAC_STEP: DEPLOYMENT_FAILED");

        // Write the factory address so we can start configuring it.
        factory = GenericFactory(lFactoryAddress);

        // Set global parameters.
        factory.write("Shared::platformFee", ConstantsLib.DEFAULT_PLATFORM_FEE);
        factory.write("Shared::platformFeeTo", address(this));
        factory.write("Shared::recoverer", address(this));
        factory.write("Shared::maxChangeRate", ConstantsLib.DEFAULT_MAX_CHANGE_RATE);

        // Step complete.
        step += 1;

        return factory;
    }

    function deployConstantProduct(bytes memory aConstantProductBytecode) external {
        require(step == 1, "CP_STEP: OUT_OF_ORDER");
        require(keccak256(aConstantProductBytecode) == CONSTANT_PRODUCT_HASH, "DEPLOYER: CP_HASH");

        // Add curve & curve specific parameters.
        factory.addCurve(aConstantProductBytecode);
        factory.write("CP::swapFee", ConstantsLib.DEFAULT_SWAP_FEE_CP);

        // Step complete.
        step += 1;
    }

    function deployStable(bytes memory aStableBytecode) external {
        require(step == 2, "SP_STEP: OUT_OF_ORDER");
        require(keccak256(aStableBytecode) == STABLE_HASH, "DEPLOYER: STABLE_HASH");

        // Add curve & curve specific parameters.
        factory.addCurve(aStableBytecode);
        factory.write("SP::swapFee", ConstantsLib.DEFAULT_SWAP_FEE_SP);
        factory.write("SP::amplificationCoefficient", ConstantsLib.DEFAULT_AMP_COEFF);

        // Step complete.
        step += 1;
    }

    function deployOracleCaller(bytes memory aOracleCallerBytecode) external returns (OracleCaller) {
        require(step == 3, "OC_STEP: OUT_OF_ORDER");
        require(keccak256(aOracleCallerBytecode) == ORACLE_CALLER_HASH, "DEPLOYER: OC_HASH");

        // Manual deployment from validated bytecode.
        address lOracleCallerAddress;
        assembly ("memory-safe") {
            lOracleCallerAddress :=
                create(
                    0, // value
                    add(aOracleCallerBytecode, 0x20), // offset
                    mload(aOracleCallerBytecode) // size
                )
        }
        require(lOracleCallerAddress != address(0), "OC_STEP: DEPLOYMENT_FAILED");

        factory.write("Shared::oracleCaller", lOracleCallerAddress);

        // Step complete.
        oracleCaller = OracleCaller(lOracleCallerAddress);
        step += 1;

        return oracleCaller;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            OWNERSHIP CLAIM
    //////////////////////////////////////////////////////////////////////////*/

    uint256 public constant GUARDIAN_THRESHOLD = 2;

    address public immutable guardian1;
    address public immutable guardian2;
    address public immutable guardian3;

    mapping(address => mapping(address => uint256)) public proposals;

    function proposeOwner(address aOwner) external {
        proposals[msg.sender][aOwner] = 1;
    }

    function clearProposedOwner(address aOwner) external {
        proposals[msg.sender][aOwner] = 0;
    }

    function claimOwnership() external {
        uint256 lGuardian1Support = proposals[guardian1][msg.sender];
        uint256 lGuardian2Support = proposals[guardian2][msg.sender];
        uint256 lGuardian3Support = proposals[guardian3][msg.sender];

        uint256 lSupport = lGuardian1Support + lGuardian2Support + lGuardian3Support;
        require(lSupport >= GUARDIAN_THRESHOLD, "DEPLOYER: THRESHOLD");

        owner = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            OWNER ACTIONS
    //////////////////////////////////////////////////////////////////////////*/

    address public owner = address(0);

    modifier onlyOwner() {
        require(msg.sender == owner, "DEPLOYER: NOT_OWNER");
        _;
    }

    function claimFactory() external onlyOwner {
        factory.transferOwnership(msg.sender);
    }

    function claimOracleCaller() external onlyOwner {
        oracleCaller.transferOwnership(msg.sender);
    }

    function rawCall(address aTarget, bytes calldata aCalldata, uint256 aValue)
        external
        onlyOwner
        returns (bytes memory)
    {
        return Address.functionCallWithValue(aTarget, aCalldata, aValue, "DEPLOYER: RAW_CALL_REVERTED");
    }
}
