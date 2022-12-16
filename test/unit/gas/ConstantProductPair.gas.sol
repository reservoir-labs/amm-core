// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

contract ConstantProductPairGas is BaseTest {
    ConstantProductPair private _freshPair;
    ConstantProductPair private _oraclePair;

    function setUp() external {
        _freshPair = ConstantProductPair(_factory.createPair(address(_tokenA), address(_tokenC), 0));
        _tokenA.mint(address(this), 100e18);
        _tokenB.mint(address(this), 100e18);
        _tokenC.mint(address(this), 100e18);

        _oraclePair = ConstantProductPair(_factory.createPair(address(_tokenB), address(_tokenC), 0));
        _tokenB.mint(address(_oraclePair), 100e18);
        _tokenC.mint(address(_oraclePair), 100e18);
        _oraclePair.mint(_bob);
        _tokenB.transfer(address(_oraclePair), 50e18);
        _oraclePair.swap(int256(-50e18), true, address(_bob), bytes(""));
    }

    function testGasMint() external {
        _tokenA.transfer(address(_constantProductPair), 50e18);
        _tokenB.transfer(address(_constantProductPair), 50e18);
        _constantProductPair.mint(address(this));
    }

    function testGasMint_Initial() external {
        _tokenA.transfer(address(_freshPair), 50e18);
        _tokenC.transfer(address(_freshPair), 50e18);
        _freshPair.mint(address(this));
    }

    function testGasSwap() external {
        _tokenA.transfer(address(_constantProductPair), 50e18);
        _constantProductPair.swap(int256(50e18), true, address(this), bytes(""));
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
        _constantProductPair.transfer(address(_constantProductPair), INITIAL_MINT_AMOUNT / 2);
        _constantProductPair.burn(address(this));
    }
}
