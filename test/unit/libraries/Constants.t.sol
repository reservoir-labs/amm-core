pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { StableMintBurn } from "src/curve/stable/StableMintBurn.sol";
import { ConstantsLib } from "src/libraries/Constants.sol";
import { Create2Lib } from "src/libraries/Create2Lib.sol";

contract ConstantsLibTest is Test {
    function testMintBurnKey() external {
        // assert
        assertEq(
            ConstantsLib.MINT_BURN_ADDRESS, Create2Lib.computeAddress(msg.sender, type(StableMintBurn).creationCode, 0)
        );
    }
}
