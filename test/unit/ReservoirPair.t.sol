pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { ReservoirPair } from "src/ReservoirPair.sol";

contract ReservoirPairTest is BaseTest {
    ReservoirPair[] internal _pairs;
    ReservoirPair internal _pair;

    event Sync(uint104 reserve0, uint104 reserve1);

    function setUp() public {
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

    function testSkim(uint256 aAmountA, uint256 aAmountB) external allPairs {
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

    function testSync() external allPairs {
        // arrange
        _tokenA.mint(address(_pair), 10e18);
        _tokenB.mint(address(_pair), 10e18);

        // sanity
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        assertEq(lReserve0, 100e18);
        assertEq(lReserve1, 100e18);

        // act
        vm.expectEmit(true, true, true, true);
        emit Sync(110e18, 110e18);
        _pair.sync();

        // assert
        (lReserve0, lReserve1,,) = _pair.getReserves();
        assertEq(lReserve0, 110e18);
        assertEq(lReserve1, 110e18);
    }
}
