pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { StableMintBurn } from "src/curve/stable/StableMintBurn.sol";
import { ConstantsLib } from "src/libraries/Constants.sol";

contract ConstantsLibTest is BaseTest {
    function testMintBurnKey() external {
        // assert
        assertEq(
            ConstantsLib.MINT_BURN_ADDRESS,
            computeCreate2Address(0, keccak256(type(StableMintBurn).creationCode), address(_factory))
        );
    }
}
