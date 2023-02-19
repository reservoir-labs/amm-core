pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { StableMintBurn } from "src/curve/stable/StableMintBurn.sol";
import { ConstantsLib } from "src/libraries/Constants.sol";

contract ConstantsLibTest is Test {
    function testMintBurnKey() public {
        // assert
//        assertEq(ConstantsLib.MINT_BURN_KEY, keccak256(type(StableMintBurn).creationCode));
    }
}
