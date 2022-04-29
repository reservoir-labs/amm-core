pragma solidity =0.8.13;

import "ds-test/test.sol";
import "forge-std/Vm.sol";

import "src/UniswapV2Factory.sol";
import "src/UniswapV2Pair.sol";
import "src/test/__fixtures/MintableERC20.sol";

contract PairTest is DSTest {

    address private mOwner = address(1);
    address private mRecoverer = address(3);

    MintableERC20 private mTokenA = new MintableERC20("TokenA", "TA");
    MintableERC20 private mTokenB = new MintableERC20("TokenB", "TB");

    UniswapV2Factory private mFactory;

    function setUp() public
    {
        mFactory = new UniswapV2Factory(30, 0, mOwner, mRecoverer);
    }

    function createPair() private returns (address rPairAddress)
    {
        rPairAddress = mFactory.createPair(address(mTokenA), address(mTokenB));
    }

    function testSetCustomFee() public
    {
        // arrange
        address pairAddress = createPair();

        // act
        mFactory.setSwapFeeForPair(pairAddress, 100);

        // assert
        assertTrue(UniswapV2Pair(pairAddress).customFee());
        assertEq(UniswapV2Pair(pairAddress).swapFee(), 100);
    }

    function testUpdateFeeGlobal() public
    {
        // arrange
        address pairAddress = createPair();
        mFactory.setSwapFeeForPair(pairAddress, 100);

        // act
        mFactory.turnOffCustomFeeForPair(pairAddress);
        UniswapV2Pair(pairAddress).updateFeeToGlobal();

        // assert
        assertTrue(!UniswapV2Pair(pairAddress).customFee());
        assertEq(UniswapV2Pair(pairAddress).swapFee(), 30);
    }
}
