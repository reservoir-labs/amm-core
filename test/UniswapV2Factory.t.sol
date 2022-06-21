pragma solidity =0.8.13;

import "forge-std/Test.sol";

import "test/__fixtures/MintableERC20.sol";

import "src/UniswapV2Factory.sol";
import "src/curve/constant-product/UniswapV2Pair.sol";

contract UniswapV2FactoryTest is Test
{
    address private _owner = address(1);
    address private _recoverer = address(3);

    MintableERC20 private _tokenA = new MintableERC20("TokenA", "TA");
    MintableERC20 private _tokenB = new MintableERC20("TokenB", "TB");
    MintableERC20 private _tokenC = new MintableERC20("TokenC", "TC");

    UniswapV2Factory private _factory;
    UniswapV2Pair private _pair;

    function setUp() public
    {
        _factory = new UniswapV2Factory(30, 0, _owner, _recoverer);
        _pair = _createPair(_tokenA, _tokenB);
    }

    function _createPair(MintableERC20 aTokenA, MintableERC20 aTokenB) private returns (UniswapV2Pair rPair)
    {
        rPair = UniswapV2Pair(_factory.createPair(address(aTokenA), address(aTokenB)));
    }

    function testCreatePair() public
    {
        // act
        UniswapV2Pair pair = _createPair(_tokenA, _tokenC);

        // assert
        assertEq(_factory.allPairs(1), address(pair));
    }
}
