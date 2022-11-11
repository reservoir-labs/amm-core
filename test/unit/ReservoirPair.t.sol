pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { ReservoirPair } from "src/ReservoirPair.sol";

contract ReservoirPairTest is BaseTest
{
    ReservoirPair[] internal _pairs;
    ReservoirPair   internal _pair;

    function setUp() public
    {
        _pairs.push(_constantProductPair);
        _pairs.push(_stablePair);
    }

    modifier allPairs() {
        for (uint256 i = 0; i < _pairs.length; ++i) {
            uint256 lBefore = vm.snapshot();
            _pair = _pairs[i];
            _;
            vm.revertTo(lBefore);
        }
    }

    function testSkim(uint256 aAmountA, uint256 aAmountB) external allPairs
    {
        // assume - to avoid overflow of the token's total supply
        // we subtract 2 * INITIAL_MINT_AMOUNT as INITIAL_MINT_AMOUNT was minted to both pairs
        uint256 lAmountA = bound(aAmountA, 1, type(uint256).max - 2 * INITIAL_MINT_AMOUNT);
        uint256 lAmountB = bound(aAmountB, 1, type(uint256).max - 2 * INITIAL_MINT_AMOUNT);

        // arrange
        _tokenA.mint(address(_pair), lAmountA);
        _tokenB.mint(address(_pair), lAmountB);

        // act
        _pair.skim(address(this));

        // assert
        assertEq(_tokenA.balanceOf(address(this)), lAmountA);
        assertEq(_tokenB.balanceOf(address(this)), lAmountB);
        assertEq(_tokenA.balanceOf(address(_pair)), INITIAL_MINT_AMOUNT);
        assertEq(_tokenB.balanceOf(address(_pair)), INITIAL_MINT_AMOUNT);
    }
}
