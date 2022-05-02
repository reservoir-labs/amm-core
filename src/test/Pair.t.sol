pragma solidity =0.8.13;

import "ds-test/test.sol";
import "forge-std/Vm.sol";

import "src/UniswapV2Factory.sol";
import "src/UniswapV2Pair.sol";
import "src/test/__fixtures/MintableERC20.sol";

contract PairTest is DSTest
{

    Vm private vm = Vm(HEVM_ADDRESS);

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

    function testSetCustomSwapFee() public
    {
        // arrange
        address pairAddress = createPair();

        // act
        mFactory.setCustomSwapFeeForPair(pairAddress, 100);

        // assert
        assertEq(UniswapV2Pair(pairAddress).customSwapFee(), 100);
        assertEq(UniswapV2Pair(pairAddress).swapFee(), 100);
    }

    function testSetCustomSwapFeeOff() public
    {
        // arrange
        address pairAddress = createPair();
        mFactory.setCustomSwapFeeForPair(pairAddress, 100);

        // act
        mFactory.setCustomSwapFeeForPair(pairAddress, 0);

        // assert
        assertEq(UniswapV2Pair(pairAddress).customSwapFee(), 0);
        assertEq(UniswapV2Pair(pairAddress).swapFee(), 30);
    }

    function testSetCustomSwapFeeMoreThanMaxSwapFee() public
    {
        // arrange
        address pairAddress = createPair();

        // act & assert
        vm.expectRevert("UniswapV2: INVALID_SWAP_FEE");
        mFactory.setCustomSwapFeeForPair(pairAddress, 4000);
    }
}
