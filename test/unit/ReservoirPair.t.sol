pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { ReservoirPair, Observation } from "src/ReservoirPair.sol";
import { AssetManager } from "test/__mocks/AssetManager.sol";

contract ReservoirPairTest is BaseTest {
    AssetManager private _manager = new AssetManager();

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
        // we subtract 2 * Constants.INITIAL_MINT_AMOUNT as Constants.INITIAL_MINT_AMOUNT was minted to both pairs
        uint256 lAmountA = bound(aAmountA, 1, type(uint256).max - 2 * Constants.INITIAL_MINT_AMOUNT);
        uint256 lAmountB = bound(aAmountB, 1, type(uint256).max - 2 * Constants.INITIAL_MINT_AMOUNT);

        // arrange
        _tokenA.mint(address(_pair), lAmountA);
        _tokenB.mint(address(_pair), lAmountB);

        // act
        _pair.skim(address(this));

        // assert
        assertEq(_tokenA.balanceOf(address(this)), lAmountA);
        assertEq(_tokenB.balanceOf(address(this)), lAmountB);
        assertEq(_tokenA.balanceOf(address(_pair)), Constants.INITIAL_MINT_AMOUNT);
        assertEq(_tokenB.balanceOf(address(_pair)), Constants.INITIAL_MINT_AMOUNT);
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
        vm.expectEmit(false, false, false, true);
        emit Sync(110e18, 110e18);
        _pair.sync();

        // assert
        (lReserve0, lReserve1,,) = _pair.getReserves();
        assertEq(lReserve0, 110e18);
        assertEq(lReserve1, 110e18);
    }

    function testCheckedTransfer_RevertWhenTransferFail() external allPairs {
        // arrange
        int256 lSwapAmt = 5e18;
        // make any call to tokenB::transfer fail
        vm.mockCall(
            address(_tokenB), abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)"))), abi.encode(false)
        );

        // act & assert
        _tokenA.mint(address(_pair), uint256(lSwapAmt));
        vm.expectRevert("RP: TRANSFER_FAILED");
        _pair.swap(lSwapAmt, true, address(this), "");
    }

    function testCheckedTransfer_RevertWhenTransferReverts() external allPairs {
        // arrange
        int256 lSwapAmt = 5e18;
        // make the tokenB balance in pair 0, so that transfer will fail
        deal(address(_tokenB), address(_pair), 0);

        // act & assert
        _tokenA.mint(address(_pair), uint256(lSwapAmt));
        vm.expectRevert("RP: TRANSFER_FAILED");
        _pair.swap(lSwapAmt, true, address(this), "");
    }

    function testReentrancyGuard_LargeTimestamp() external allPairs {
        // arrange
        vm.warp(2 ** 31); // Has the first bit set.

        // act
        // If we were not cleaning the upper most bit this would lock the pair
        // forever.
        _pair.sync();

        // assert
        // Luckily we are clearing the upper most bit so this is fine.
        _pair.sync();
    }
}
