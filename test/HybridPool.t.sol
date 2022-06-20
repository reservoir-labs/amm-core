pragma solidity 0.8.13;

import "forge-std/Test.sol";

import "test/__fixtures/MintableERC20.sol";

import "src/curve/stable/MasterDeployer.sol";
import "src/curve/stable/HybridPoolFactory.sol";
import "src/curve/stable/HybridPool.sol";

contract HybridPoolTest is Test
{
    address private _platformFeeTo = address(1);
    address private _bentoPlaceholder = address(2);
    MasterDeployer private _masterDeployer = new MasterDeployer(2500, _platformFeeTo, _bentoPlaceholder);
    HybridPoolFactory private _poolFactory = new HybridPoolFactory(address(_masterDeployer));
    HybridPool private _pool;
    MintableERC20 private _tokenA = new MintableERC20("TokenA", "TA");
    MintableERC20 private _tokenB = new MintableERC20("TokenB", "TB");

    function setUp() public
    {
        _pool = _createPair(_tokenA, _tokenB, 25, 1000);
    }

    function _createPair(MintableERC20 aTokenA,
                         MintableERC20 aTokenB,
                         uint256 aSwapFee,
                         uint256 aAmplificationCoefficient
    ) private returns (HybridPool rPool)
    {
        _masterDeployer.addToWhitelist(address(_poolFactory));
        bytes memory lDeployData = abi.encode(address(aTokenA), address(aTokenB), aSwapFee, aAmplificationCoefficient);
        rPool = HybridPool(_masterDeployer.deployPool(address(_poolFactory), lDeployData));
    }

    function testMint() public
    {
        // arrange
        _tokenA.mint(address(_pool), 100e18);
        _tokenB.mint(address(_pool), 100e18);

        // act
        uint256 lLiquidity = _pool.mint(abi.encode(address(this)));

        // assert
        assertEq(_pool.balanceOf(address(this)), lLiquidity);
    }

    function testMint_OnlyTransferOneToken() public
    {
        // arrange
        _tokenA.mint(address(_pool), 100e18);

        // act & assert
        vm.expectRevert(stdError.divisionError);
        _pool.mint(abi.encode(address(this)));
    }

    function testSwap() public
    {
        // arrange
        _tokenA.mint(address(_pool), 100e18);
        _tokenB.mint(address(_pool), 100e18);
        _pool.mint(abi.encode(address(this)));

        // act
        _tokenA.mint(address(address(_pool)), 5e18);
        uint256 lAmountOut = _pool.swap(abi.encode(address(_tokenA), address(this)));

        // assert
        assertEq(lAmountOut, _tokenB.balanceOf(address(this)));
    }

    function testSwap_NoTransferTokens() public
    {
        // arrange
        _tokenA.mint(address(_pool), 100e18);
        _tokenB.mint(address(_pool), 100e18);
        _pool.mint(abi.encode(address(this)));

        // act & assert
        vm.expectRevert("UniswapV2: TRANSFER_FAILED");
        _pool.swap(abi.encode(address(_tokenA), address(this)));
    }

    function testBurn() public
    {
        // arrange
        _tokenA.mint(address(_pool), 100e18);
        _tokenB.mint(address(_pool), 100e18);
        _pool.mint(abi.encode(address(this)));

        // act
        _pool.transfer(address(_pool), _pool.balanceOf(address(this)));
        _pool.burn(abi.encode(address(this)));

        // assert
        assertEq(_pool.balanceOf(address(this)), 0);
        assertEq(_tokenA.balanceOf(address(this)), 99999999999999999500);
        assertEq(_tokenB.balanceOf(address(this)), 99999999999999999500);
    }
}
