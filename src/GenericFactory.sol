// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "forge-std/Test.sol";

import { SSTORE2 } from "solmate/utils/SSTORE2.sol";
import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Address } from "@openzeppelin/utils/Address.sol";

import { IGenericFactory } from "src/interfaces/IGenericFactory.sol";

contract GenericFactory is IGenericFactory, Ownable
{
    /*//////////////////////////////////////////////////////////////////////////
                                    CONFIG
    //////////////////////////////////////////////////////////////////////////*/

    mapping(bytes32 => bytes32) public get;

    function set(bytes32 aKey, bytes32 aValue) external onlyOwner
    {
        get[aKey] = aValue;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    CURVES
    //////////////////////////////////////////////////////////////////////////*/

    address[] private _getByteCode;

    function addCurve(bytes calldata aInitCode) external onlyOwner returns (uint256 rCurveId)
    {
        rCurveId = _getByteCode.length;

        _getByteCode.push(SSTORE2.write(aInitCode));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    PAIRS
    //////////////////////////////////////////////////////////////////////////*/

    event PairCreated(address indexed token0, address indexed token1, uint256 curveId, address pair);

    mapping(address => mapping(address => mapping(uint256 => address))) public getPair;

    function _sortAddresses(address a, address b) private pure returns (address r0, address r1)
    {
        (r0, r1) = a < b
            ? (a, b)
            : (b, a);
    }

    function createPair(address aTokenA, address aTokenB, uint256 aCurveId) external returns (address rPair)
    {
        require(aTokenA != aTokenB, "SS: IDENTICAL_ADDRESSES");
        require(aTokenA != address(0), "SS: ZERO_ADDRESS");
        require(getPair[aTokenA][aTokenB][aCurveId] == address(0), "SS: PAIR_EXISTS");
        address lCodePointer = _getByteCode[aCurveId];
        require(lCodePointer != address(0), "SS: INVALID_CURVE_ID");

        (address lToken0, address lToken1) = _sortAddresses(aTokenA, aTokenB);

        bytes memory lInitCode = abi.encodePacked(SSTORE2.read(lCodePointer), abi.encode(lToken0, lToken1));

        assembly {
            // create2 the pair, uniqueness guaranteed by args
            rPair := create2(
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

        emit PairCreated(lToken0, lToken1, aCurveId, rPair);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    EXECUTE
    //////////////////////////////////////////////////////////////////////////*/

    function rawCall(
        address aTarget,
        bytes calldata aCalldata,
        uint256 aValue
    ) external onlyOwner returns (bytes memory)
    {
        return Address.functionCallWithValue(
            aTarget,
            aCalldata,
            aValue,
            "FACTORY: RAW_CALL_REVERTED"
        );
    }
}
