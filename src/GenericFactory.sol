// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { SSTORE2 } from "solmate/utils/SSTORE2.sol";
import { Owned } from "solmate/auth/Owned.sol";
import { Address } from "@openzeppelin/utils/Address.sol";

import { IGenericFactory } from "src/interfaces/IGenericFactory.sol";
import { Math } from "src/libraries/Math.sol";

uint256 constant MAX_SSTORE_SIZE = 0x6000 - 1;

contract GenericFactory is IGenericFactory, Owned {
    constructor(address aOwner) Owned(aOwner) { }

    /*//////////////////////////////////////////////////////////////////////////
                                    CONFIG
    //////////////////////////////////////////////////////////////////////////*/

    mapping(bytes32 => bytes32) public get;

    function set(bytes32 aKey, bytes32 aValue) external onlyOwner {
        get[aKey] = aValue;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    CURVES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice 2D array storing each curve's initCode chunks.
    address[][] private _getByteCode;

    function addCurve(bytes calldata aInitCode) external onlyOwner returns (uint256 rCurveId) {
        rCurveId = _getByteCode.length;
        _getByteCode.push();

        uint256 lChunk = 0;
        uint256 lInitCodePointer = 0;
        while (lInitCodePointer < aInitCode.length) {
            // Cut the initCode into chunks at most 24kb (EIP-170). The stored
            // data is prefixed with STOP, so we must store 1 less than max.
            uint256 lChunkEnd = Math.min(aInitCode.length, lInitCodePointer + MAX_SSTORE_SIZE);

            _getByteCode[rCurveId].push(SSTORE2.write(aInitCode[lInitCodePointer:lChunkEnd]));

            lChunk += 1;
            lInitCodePointer = lChunkEnd;
        }
    }

    function _loadCurve(uint256 aCurveId, address aToken0, address aToken1) private view returns (bytes memory) {
        address[] storage lByteCode = _getByteCode[aCurveId];

        bytes memory lInitCode;
        uint256 lFreeMem;
        assembly {
            lInitCode := mload(0x40)
            lFreeMem := add(lInitCode, 0x20)
        }

        uint256 lByteCodeLength = 0;
        for (uint256 i = 0; i < lByteCode.length; ++i) {
            address lPointer = lByteCode[i];
            uint256 lSize = lPointer.code.length - 0x01;

            // TODO: Go check/annotate all asm for memory safety.
            assembly {
                // Copy the entire chunk to memory.
                extcodecopy(lPointer, lFreeMem, 0x01, lSize)
            }

            lFreeMem += lSize;
            // TODO: Do we need to pad to 32 bytes?
            lByteCodeLength += lSize;
        }

        // TODO: Releasing back to solidity after the loop is not memory safe.
        // Write the copied size & update free_mem.
        assembly {
            // Store the two tokens as cstr args.
            mstore(lFreeMem, aToken0)
            mstore(add(lFreeMem, 0x20), aToken1)

            // Write initCode length and update free mem.
            mstore(lInitCode, add(lByteCodeLength, 0x40))
            mstore(0x40, add(lFreeMem, 0x40))
        }

        return lInitCode;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    PAIRS
    //////////////////////////////////////////////////////////////////////////*/

    event PairCreated(address indexed token0, address indexed token1, uint256 curveId, address pair);

    mapping(address => mapping(address => mapping(uint256 => address))) public getPair;
    address[] private _allPairs;

    function allPairs() external view returns (address[] memory) {
        return _allPairs;
    }

    function _sortAddresses(address a, address b) private pure returns (address r0, address r1) {
        (r0, r1) = a < b ? (a, b) : (b, a);
    }

    function createPair(address aTokenA, address aTokenB, uint256 aCurveId) external returns (address rPair) {
        require(aTokenA != aTokenB, "FACTORY: IDENTICAL_ADDRESSES");
        require(aTokenA != address(0), "FACTORY: ZERO_ADDRESS");
        require(getPair[aTokenA][aTokenB][aCurveId] == address(0), "FACTORY: PAIR_EXISTS");

        (address lToken0, address lToken1) = _sortAddresses(aTokenA, aTokenB);

        // TODO: Test that _loadCurve errors for invalid indexes.
        bytes memory lInitCode = _loadCurve(aCurveId, lToken0, lToken1);

        assembly {
            // create2 the pair, uniqueness guaranteed by args
            rPair :=
                create2(
                    // 0 value is sent at deployment
                    0,
                    // skip the first word of lByteCode (which is length)
                    add(lInitCode, 0x20),
                    // load the length of lBytecode (which is stored in the first
                    // word)
                    mload(lInitCode),
                    // do not use any salt, our bytecode is unique due to
                    // (token0,token1) constructor arguments
                    0
                )
        }
        require(rPair != address(0), "FACTORY: DEPLOY_FAILED");

        // double-map the newly created pair for reverse lookup
        getPair[lToken0][lToken1][aCurveId] = rPair;
        getPair[lToken1][lToken0][aCurveId] = rPair;
        _allPairs.push(rPair);

        emit PairCreated(lToken0, lToken1, aCurveId, rPair);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    EXECUTE
    //////////////////////////////////////////////////////////////////////////*/

    function rawCall(address aTarget, bytes calldata aCalldata, uint256 aValue)
        external
        onlyOwner
        returns (bytes memory)
    {
        return Address.functionCallWithValue(aTarget, aCalldata, aValue, "FACTORY: RAW_CALL_REVERTED");
    }
}
