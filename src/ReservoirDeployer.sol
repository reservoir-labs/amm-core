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
    bytes32 public constant factory_hash = bytes32(0x85cd64d099c62f941468c1abef83eb0a7583fd4fa6e637efa5c41848a07fdce4);
    bytes32 public constant constant_product_hash = bytes32(0x28e80e163b3068ae34f85c9d969e376212a8b452e791535c0a1267b5f99f11c1);
    bytes32 public constant stable_hash = bytes32(0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470);
    bytes32 public constant oracle_caller_hash = bytes32(0xca113a2dda43259845682c486c2429d6ee7a85bd13a0d252148fcaab7cd6dac1);

    // Deployment addresses.
    GenericFactory public factory;
    OracleCaller public oracleCaller;

    function isDone() external view returns (bool) {
        return step == TERMINAL_STEP;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            DEPLOYMENT STEPS
    //////////////////////////////////////////////////////////////////////////*/

    function deployFactory(bytes memory aFactoryBytecode) external {
        require(step == 0, "FAC_STEP: OUT_OF_ORDER");
        require(keccak256(aFactoryBytecode) == factory_hash);

        // Manual deployment from validated bytecode.
        address lFactoryAddress;
        assembly ("memory-safe") {
            lFactoryAddress := create(
                0, // value
                add(aFactoryBytecode, 0x20), // offset
                mload(aFactoryBytecode) // size
            )
        }
        require(lFactoryAddress != address(0), "FAC_STEP: DEPLOYMENT_FAILED");

        // Set global parameters.
        factory.write("Shared::platformFee", DEFAULT_PLATFORM_FEE);
        factory.write("Shared::platformFeeTo", address(this));
        // TODO: Is it okay to not set defaultRecoverer?
        // factory.write("Shared::defaultRecoverer", _recoverer);
        factory.write("Shared::maxChangeRate", DEFAULT_MAX_CHANGE_RATE);

        // Step complete.
        factory = GenericFactory(lFactoryAddress);
        step += 1;
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

    function deployConstantProduct(bytes memory aStableBytecode) external {
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
    function deployOracleCaller(bytes memory aOracleCallerBytecode) external {
        require(step == 3, "OC_STEP: OUT_OF_ORDER");
        require(keccak256(aOracleCallerBytecode) == oracle_caller_hash);

        // Manual deployment from validated bytecode.
        address lOracleCallerAddress;
        assembly ("memory-safe") {
            lOracleCallerAddress := create(
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
    }

    /*//////////////////////////////////////////////////////////////////////////
                            OWNERSHIP CLAIM
    //////////////////////////////////////////////////////////////////////////*/

    uint256 public constant GUARDIAN_THRESHOLD = 2;

    address public guardian1;
    address public guardian2;
    address public guardian3;

    mapping(address => mapping(address => uint256)) proposals;

    function proposeOwner(address aOwner) {
        proposals[msg.sender][aOwner] = 1;
    }

    function clearProposedOwner(address aOwner) {
        proposals[msg.sender][aOwner] = 0;
    }

    function claimOwnership() {
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
