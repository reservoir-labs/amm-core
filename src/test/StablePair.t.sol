pragma solidity ^0.8.0;

import "ds-test/test.sol";
import "forge-std/Vm.sol";

import "src/UniswapV2Factory.sol";
import "src/curve/stable/UniswapV2StablePair.sol";
import "src/test/__fixtures/MintableERC20.sol";

contract StablePairTest is DSTest {
    Vm private vm = Vm(HEVM_ADDRESS);

    address private mOwner = address(1);
    address private mRecoverer = address(3);

    MintableERC20 private mTokenA = new MintableERC20("StableA", "TA", 18);
    MintableERC20 private mTokenB = new MintableERC20("StableB", "TB", 6);

    UniswapV2Factory private mFactory;

    function setUp() public
    {
        mFactory = new UniswapV2Factory(30, 2500, mOwner, mRecoverer);
    }

    function createStablePair() private returns (address rPairAddress)
    {
        rPairAddress = mFactory.createPair(address(mTokenA), address(mTokenB), 1);
    }

    function testCreatePair() public
    {
        // arrange
        address pairAddress = createStablePair();
        (uint ampParam, ,) = UniswapV2StablePair(pairAddress).getAmplificationParameter();

        // assert
        assertEq(ampParam, 50000);
        assertEq(UniswapV2StablePair(pairAddress)._getScalingFactor0(), 1e30);
        assertEq(UniswapV2StablePair(pairAddress)._getScalingFactor1(), 1e18);
    }

    function testAddLiquidity() public
    {

    }

    function testBasicSwap() public
    {

    }

    function testRemoveLiquidity() public
    {

    }
}
