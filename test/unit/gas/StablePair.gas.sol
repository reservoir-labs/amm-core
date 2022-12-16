// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

contract StablePairGas is BaseTest {
    StablePair private _freshPair;
    StablePair private _oraclePair;

    function setUp() external {
        _freshPair = StablePair(_factory.createPair(address(_tokenA), address(_tokenC), 1));
        _tokenA.mint(address(this), 100e18);
        _tokenB.mint(address(this), 100e18);
        _tokenC.mint(address(this), 100e18);

        _oraclePair = StablePair(_factory.createPair(address(_tokenB), address(_tokenC), 1));
        _tokenB.mint(address(_oraclePair), 100e18);
        _tokenC.mint(address(_oraclePair), 100e18);
        _oraclePair.mint(_bob);
        _tokenB.transfer(address(_oraclePair), 50e18);
        _oraclePair.swap(int256(-50e18), true, address(_bob), bytes(""));
    }

    function testGasMint() external {
        _tokenA.transfer(address(_stablePair), 50e18);
        _tokenB.transfer(address(_stablePair), 50e18);
        _stablePair.mint(address(this));
    }

    function testGasMint_Initial() external {
        _tokenA.transfer(address(_freshPair), 50e18);
        _tokenC.transfer(address(_freshPair), 50e18);
        _freshPair.mint(address(this));
    }

    function testGasSwap() external {
        _tokenA.transfer(address(_stablePair), 50e18);
        _stablePair.swap(int256(50e18), true, address(this), bytes(""));
    }

    function testGasSwap_UpdateOracle() external {
        vm.roll(100);
        skip(10_000);
        _tokenB.transfer(address(_oraclePair), 0.1e18);
        _oraclePair.swap(int256(-0.1e18), true, address(_bob), bytes(""));
    }

    function testGasSwap_UpdateOracleClamped() external {
        vm.roll(100);
        skip(10_000);
        _tokenB.transfer(address(_oraclePair), 50e18);
        _oraclePair.swap(int256(-50e18), true, address(_bob), bytes(""));
    }

    function testGasBurn() external {
        vm.prank(_alice);
        _stablePair.transfer(address(_stablePair), INITIAL_MINT_AMOUNT / 2);
        _stablePair.burn(address(this));
    }
}

