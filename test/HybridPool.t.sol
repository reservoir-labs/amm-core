pragma solidity 0.8.13;

import "forge-std/Test.sol";

import "test/__fixtures/MintableERC20.sol";

import "src/curve/stable/MasterDeployer.sol";
import "src/curve/stable/HybridPoolFactory.sol";
import "src/curve/stable/HybridPool.sol";
import "src/curve/constant-product/UniswapV2Pair.sol";
import "src/UniswapV2Factory.sol";

contract HybridPoolTest is Test
{
    uint256 public constant INITIAL_MINT_AMOUNT = 100e18;

    address private _platformFeeTo = address(1);
    address private _bentoPlaceholder = address(2);
    address private _alice = address(3);

    MintableERC20 private _tokenA = new MintableERC20("TokenA", "TA");
    MintableERC20 private _tokenB = new MintableERC20("TokenB", "TB");
    MintableERC20 private _tokenC = new MintableERC20("TokenC", "TC");

    MasterDeployer private _masterDeployer = new MasterDeployer(2500, _platformFeeTo, _bentoPlaceholder);
    HybridPoolFactory private _poolFactory = new HybridPoolFactory(address(_masterDeployer));
    HybridPool private _pool = _createPair(_tokenA, _tokenB, 25, 50);

    function setUp() public
    {
        _tokenA.mint(address(_pool), INITIAL_MINT_AMOUNT);
        _tokenB.mint(address(_pool), INITIAL_MINT_AMOUNT);
        _pool.mint(abi.encode(_alice));
    }

    function _createPair(
        MintableERC20 aTokenA,
        MintableERC20 aTokenB,
        uint256 aSwapFee,
        uint256 aAmplificationCoefficient
    ) private returns (HybridPool rPool)
    {
        _masterDeployer.addToWhitelist(address(_poolFactory));
        bytes memory lDeployData = abi.encode(address(aTokenA), address(aTokenB), aSwapFee, aAmplificationCoefficient);

        rPool = HybridPool(_masterDeployer.deployPool(address(_poolFactory), lDeployData));
    }

    function _calculateConstantProductOutput(
        uint256 aReserveIn,
        uint256 aReserveOut,
        uint256 aTokenIn,
        uint256 aFee
    ) private pure returns (uint256 rExpectedOut)
    {
        uint256 lAmountInWithFee = aTokenIn * (10_000 - aFee);
        uint256 lNumerator = lAmountInWithFee * aReserveOut;
        uint256 lDenominator = aReserveIn * 10_000 + lAmountInWithFee;

        rExpectedOut = lNumerator / lDenominator;
    }

    function testMint() public
    {
        // arrange
        uint256 lLpTokenTotalSupply = _pool.totalSupply();
        (uint256 lReserve0, uint256 lReserve1) = _pool.getReserves();
        uint256 lOldLiquidity = lReserve0 + lReserve1;
        uint256 lLiquidityToAdd = 5e18;

        // act
        _tokenA.mint(address(_pool), lLiquidityToAdd);
        _tokenB.mint(address(_pool), lLiquidityToAdd);
        _pool.mint(abi.encode(address(this)));

        // assert
        // this works only because the pools are balanced. When the pool is imbalanced the calculation will differ
        uint256 lAdditionalLpTokens = ((INITIAL_MINT_AMOUNT + lLiquidityToAdd) * 2 - lOldLiquidity) * lLpTokenTotalSupply / lOldLiquidity;
        assertEq(_pool.balanceOf(address(this)), lAdditionalLpTokens);
    }

    function testMint_OnlyTransferOneToken() public
    {
        // arrange
        HybridPool lPair = _createPair(_tokenA, _tokenC, 25, 1000);
        _tokenA.mint(address(lPair), 5e18);

        // act & assert
        vm.expectRevert(stdError.divisionError);
        lPair.mint(abi.encode(address(this)));
    }

    function testSwap() public
    {
        // act
        _tokenA.mint(address(address(_pool)), 5e18);
        uint256 lAmountOut = _pool.swap(abi.encode(address(_tokenA), address(this)));

        // assert
        assertEq(lAmountOut, _tokenB.balanceOf(address(this)));
    }

    function testSwap_ZeroInput() public
    {
        // act & assert
        vm.expectRevert("UniswapV2: TRANSFER_FAILED");
        _pool.swap(abi.encode(address(_tokenA), address(this)));
    }

    function testSwap_BetterPerformanceThanConstantProduct() public
    {
        // arrange
        UniswapV2Factory lFactory = new UniswapV2Factory(25, 2500, _platformFeeTo, address(0));
        UniswapV2Pair lPair = UniswapV2Pair(lFactory.createPair(address(_tokenA), address(_tokenB)));
        _tokenA.mint(address(lPair), INITIAL_MINT_AMOUNT);
        _tokenB.mint(address(lPair), INITIAL_MINT_AMOUNT);
        lPair.mint(_alice);

        // act
        uint256 lSwapAmount = 5e18;
        _tokenA.mint(address(_pool), lSwapAmount);
        _pool.swap(abi.encode(address(_tokenA), address(this)));
        uint256 lHybridPoolOutput = _tokenB.balanceOf(address(this));

        uint256 lExpectedConstantProductOutput = _calculateConstantProductOutput(INITIAL_MINT_AMOUNT, INITIAL_MINT_AMOUNT, lSwapAmount, 25);
        _tokenA.mint(address(lPair), lSwapAmount);
        lPair.swap(lExpectedConstantProductOutput, 0, address(this), "");
        uint256 lConstantProductOutput = _tokenB.balanceOf(address(this)) - lHybridPoolOutput;

        // assert
        assertGt(lHybridPoolOutput, lConstantProductOutput);
    }

    function testBurn() public
    {
        // arrange
        vm.startPrank(_alice);
        uint256 lLpTokenBalance = _pool.balanceOf(_alice);
        uint256 lLpTokenTotalSupply = _pool.totalSupply();
        (uint256 lReserve0, uint256 lReserve1) = _pool.getReserves();
        address[] memory lAssets = _pool.getAssets();
        address lToken0 = lAssets[0];

        // act
        _pool.transfer(address(_pool), _pool.balanceOf(_alice));
        _pool.burn(abi.encode(_alice));

        // assert
        uint256 lExpectedTokenAReceived;
        uint256 lExpectedTokenBReceived;
        if (lToken0 == address(_tokenA)) {
            lExpectedTokenAReceived = lLpTokenBalance * lReserve0 / lLpTokenTotalSupply;
            lExpectedTokenBReceived = lLpTokenBalance * lReserve1 / lLpTokenTotalSupply;
        }
        else {
            lExpectedTokenAReceived = lLpTokenBalance * lReserve1 / lLpTokenTotalSupply;
            lExpectedTokenBReceived = lLpTokenBalance * lReserve0 / lLpTokenTotalSupply;
        }

        assertEq(_pool.balanceOf(_alice), 0);
        assertGt(lExpectedTokenAReceived, 0);
        assertEq(_tokenA.balanceOf(_alice), lExpectedTokenAReceived);
        assertEq(_tokenB.balanceOf(_alice), lExpectedTokenBReceived);
    }
}
