pragma solidity 0.8.13;

import "forge-std/Test.sol";

import "test/__fixtures/MintableERC20.sol";

import "src/curve/stable/MasterDeployer.sol";
import "src/curve/stable/HybridPoolFactory.sol";
import "src/curve/stable/HybridPool.sol";

contract HybridPoolTest is Test
{
    address private mPlatformFeeTo = address(1);
    address private mBentoPlaceholder = address(2);
    MasterDeployer private mMasterDeployer = new MasterDeployer(2500, mPlatformFeeTo, mBentoPlaceholder);
    HybridPoolFactory private mPoolFactory = new HybridPoolFactory(address(mMasterDeployer));
    MintableERC20 private mTokenA = new MintableERC20("TokenA", "TA");
    MintableERC20 private mTokenB = new MintableERC20("TokenB", "TB");
    address private mPool;

    function setUp() public
    {
        _createPair();
    }

    function _createPair() private
    {
        mMasterDeployer.addToWhitelist(address(mPoolFactory));
        bytes memory deployData = abi.encode(address(mTokenA), address(mTokenB), 25, 1000);
        mPool = mMasterDeployer.deployPool(address(mPoolFactory), deployData);
    }

    function testMint() public
    {
        // arrange
        mTokenA.mint(mPool, 100e18);
        mTokenB.mint(mPool, 100e18);

        // act
        uint256 liquidity = HybridPool(mPool).mint(abi.encode(address(this)));

        // assert
        assertEq(HybridPool(mPool).balanceOf(address(this)), liquidity);
    }

    function testMint_OnlyTransferOneToken() public
    {
        // arrange
        mTokenA.mint(mPool, 100e18);

        // act & assert
        vm.expectRevert(stdError.divisionError);
        HybridPool(mPool).mint(abi.encode(address(this)));
    }

    function testSwap() public
    {
        // arrange
        mTokenA.mint(mPool, 100e18);
        mTokenB.mint(mPool, 100e18);
        HybridPool(mPool).mint(abi.encode(address(this)));

        // act
        mTokenA.mint(address(mPool), 5e18);
        uint256 amountOut = HybridPool(mPool).swap(abi.encode(address(mTokenA), address(this)));

        // assert
        assertEq(amountOut, mTokenB.balanceOf(address(this)));
    }

    function testSwap_NoTransferTokens() public
    {
        // arrange
        mTokenA.mint(mPool, 100e18);
        mTokenB.mint(mPool, 100e18);
        HybridPool(mPool).mint(abi.encode(address(this)));

        // act & assert
        vm.expectRevert("UniswapV2: TRANSFER_FAILED");
        HybridPool(mPool).swap(abi.encode(address(mTokenA), address(this)));
    }

    function testBurn() public
    {
        // arrange
        mTokenA.mint(mPool, 100e18);
        mTokenB.mint(mPool, 100e18);
        HybridPool(mPool).mint(abi.encode(address(this)));

        // act
        HybridPool(mPool).transfer(mPool, HybridPool(mPool).balanceOf(address(this)));
        HybridPool(mPool).burn(abi.encode(address(this)));

        // assert
        assertEq(HybridPool(mPool).balanceOf(address(this)), 0);
        assertEq(mTokenA.balanceOf(address(this)), 99999999999999999500);
        assertEq(mTokenB.balanceOf(address(this)), 99999999999999999500);
    }
}
