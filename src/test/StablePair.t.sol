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

    MintableERC20 private mTokenA = new MintableERC20("TokenA", "TA");
    MintableERC20 private mTokenB = new MintableERC20("TokenB", "TB");

    UniswapV2Factory private mFactory;

    function setUp() public
    {
        mFactory = new UniswapV2Factory(30, 2500, mOwner, mRecoverer);
    }

    function createStablePair() private returns (address rPairAddress)
    {
        rPairAddress = mFactory.createPair(address(mTokenA), address(mTokenB), true);
    }

    function testCreatePair() public
    {
        createStablePair();
    }
}
