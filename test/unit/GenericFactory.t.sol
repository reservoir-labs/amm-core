pragma solidity =0.8.13;

import "forge-std/Test.sol";

import "test/__fixtures/MintableERC20.sol";

import { UniswapV2Pair } from "src/curve/constant-product/UniswapV2Pair.sol";
import { HybridPool } from "src/curve/stable/HybridPool.sol";
import { GenericFactory } from "src/GenericFactory.sol";

contract GenericFactoryTest is Test
{
    address private _owner = address(1);
    address private _recoverer = address(3);

    MintableERC20 private _tokenA = new MintableERC20("TokenA", "TA");
    MintableERC20 private _tokenB = new MintableERC20("TokenB", "TB");
    MintableERC20 private _tokenC = new MintableERC20("TokenC", "TC");

    GenericFactory private _factory = new GenericFactory();

    function setUp() public
    {
        _factory.addCurve(type(UniswapV2Pair).creationCode);
        _factory.set(keccak256("UniswapV2Pair::swapFee"), bytes32(uint256(30)));
        _factory.set(keccak256("UniswapV2Pair::platformFee"), bytes32(uint256(2500)));
    }

    function testCreatePair_ConstantProduct() public
    {
        // act
        address lPair = _factory.createPair(address(_tokenA), address(_tokenB), 0);

        // assert
        assertEq(_factory.getPair(address(_tokenA), address(_tokenB), 0), address(lPair));
    }

    // todo: test creating the HybridPool
}
