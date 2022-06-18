pragma solidity =0.8.13;

import "forge-std/Test.sol";

import "test/__fixtures/MintableERC20.sol";

import "src/UniswapV2Factory.sol";
import "src/curve/constant-product/UniswapV2Pair.sol";

contract FactoryTest is Test
{
    address private mOwner = address(1);
    address private mSwapUser = address(2);
    address private mRecoverer = address(3);

    MintableERC20 private mTokenA = new MintableERC20("TokenA", "TA");
    MintableERC20 private mTokenB = new MintableERC20("TokenB", "TB");
    MintableERC20 private mTokenC = new MintableERC20("TokenC", "TC");

    UniswapV2Factory private mFactory;
    UniswapV2Pair private mPair;

    function setUp() public
    {
        mFactory = new UniswapV2Factory(30, 0, mOwner, mRecoverer);
        mPair = _createPair(mTokenA, mTokenB);
    }

    function _createPair(MintableERC20 aTokenA, MintableERC20 aTokenB) private returns (UniswapV2Pair rPair)
    {
        rPair = UniswapV2Pair(mFactory.createPair(address(aTokenA), address(aTokenB)));
    }

    function testCreatePair() public
    {
        // act
        UniswapV2Pair pair = _createPair(mTokenA, mTokenC);

        // assert
        assertEq(mFactory.allPairs(1), address(pair));
    }
}
