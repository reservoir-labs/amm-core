// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { Address } from "@openzeppelin/utils/Address.sol";

import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";

import { OracleCaller } from "src/oracle/OracleCaller.sol";
import { GenericFactory } from "src/GenericFactory.sol";

// TODO:
// - Enable factory ownership transfer.
// - Enable oracle caller ownership transfer.

contract ReservoirDeployer {
    using FactoryStoreLib for GenericFactory;

    // Default configuration.
    uint256 public constant INITIAL_MINT_AMOUNT = 100e18;
    uint256 public constant DEFAULT_SWAP_FEE_CP = 3000; // 0.3%
    uint256 public constant DEFAULT_SWAP_FEE_SP = 100; // 0.01%
    uint256 public constant DEFAULT_PLATFORM_FEE = 250_000; // 25%
    uint256 public constant DEFAULT_AMP_COEFF = 1000;
    uint256 public constant DEFAULT_MAX_CHANGE_RATE = 0.0005e18;

    // Steps.
    uint256 public constant TERMINAL_STEP = 4;
    uint256 public step = 0;

    // Bytecode hashes.
    bytes32 public constant factory_hash = bytes32(0x67de66ba417a88060e4b7b0cde0d56b01973a4b9f0066385ba661c58d2d6ca50);
    bytes32 public constant constant_product_hash =
        bytes32(0x043551969376243d49aff4ce627e029219c6d90e16c780a7d2ef4f72b6fcf236);
    bytes32 public constant stable_hash = bytes32(0x3239f5ad44712803a6036e7a99f6fdfb9f98f22d8e39ebff8de3c1996ab5dfec);
    bytes32 public constant oracle_caller_hash =
        bytes32(0x262458524d9c8928fe7fd7661236b93f6d6a9535182f48fd582a75f18bfbf85f);

    // Deployment addresses.
    GenericFactory public factory;
    OracleCaller public oracleCaller;

    function isDone() external view returns (bool) {
        return step == TERMINAL_STEP;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            DEPLOYMENT STEPS
    //////////////////////////////////////////////////////////////////////////*/

    function deployFactory(bytes memory aFactoryBytecode) external returns (GenericFactory) {
        require(step == 0, "FAC_STEP: OUT_OF_ORDER");
        require(keccak256(aFactoryBytecode) == factory_hash);

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
        factory.write("Shared::platformFee", DEFAULT_PLATFORM_FEE);
        factory.write("Shared::platformFeeTo", address(this));
        // TODO: Is it okay to not set defaultRecoverer?
        // factory.write("Shared::defaultRecoverer", _recoverer);
        factory.write("Shared::maxChangeRate", DEFAULT_MAX_CHANGE_RATE);

        // Step complete.
        step += 1;

        return factory;
    }

    function deployConstantProduct(bytes memory aConstantProductBytecode) external {
        require(step == 1, "CP_STEP: OUT_OF_ORDER");
        require(keccak256(aConstantProductBytecode) == constant_product_hash);

        // Add curve & curve specific parameters.
        factory.addCurve(aConstantProductBytecode);
        factory.write("CP::swapFee", DEFAULT_SWAP_FEE_CP);

        // Step complete.
        step += 1;
    }

    function deployStable(bytes memory aStableBytecode) external {
        require(step == 2, "CP_STEP: OUT_OF_ORDER");
        require(keccak256(aStableBytecode) == stable_hash);

        // Add curve & curve specific parameters.
        factory.addCurve(aStableBytecode);
        factory.write("SP::swapFee", DEFAULT_SWAP_FEE_SP);
        factory.write("SP::amplificationCoefficient", DEFAULT_AMP_COEFF);

        // Step complete.
        step += 1;
    }

    // TODO: Do we want to deploy an oracleCaller as part of standard deployment?
    function deployOracleCaller(bytes memory aOracleCallerBytecode) external returns (OracleCaller) {
        require(step == 3, "OC_STEP: OUT_OF_ORDER");
        require(keccak256(aOracleCallerBytecode) == oracle_caller_hash);

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

    // TODO: Set these addresses.
    address public constant guardian1 = address(123);
    address public constant guardian2 = address(123);
    address public constant guardian3 = address(123);

    mapping(address => mapping(address => uint256)) proposals;

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
        require(lSupport >= GUARDIAN_THRESHOLD);

        owner = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            OWNER ACTIONS
    //////////////////////////////////////////////////////////////////////////*/

    address public owner = address(0);

    modifier onlyOwner() {
        require(msg.sender == owner);
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
        return Address.functionCallWithValue(aTarget, aCalldata, aValue, "FACTORY: RAW_CALL_REVERTED");
    }
}
