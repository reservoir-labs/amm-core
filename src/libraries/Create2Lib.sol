// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

library Create2Lib {
    /// @notice Computes the address of a theoretical/actual CREATE2 deployed
    ///         contract.
    /// @dev    NOT INTENDED TO BE USED IN DEPLYOED CODE. This helper accepts
    ///         a full copy of the creationCode which has unbounded gas cost.
    /// @param  aDeployer   The address of the contract deploying the target
    ///                     contract.
    /// @param  aInitCode   The creation code of the contract.
    /// @param  aSalt       A user-provided value that can be used to generate
    ///                     varying addresses for the same deploy + init code
    ///                     pair.
    /// @return The address of the contract given the arguments.
    function computeAddress(address aDeployer, bytes memory aInitCode, bytes32 aSalt) internal pure returns (address) {
        bytes32 lAddress = keccak256(abi.encodePacked(bytes1(0xff), aDeployer, aSalt, keccak256(aInitCode)));

        return address(bytes20(lAddress << 96));
    }
}
