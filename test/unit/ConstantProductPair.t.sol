pragma solidity 0.8.13;

import "test/__fixtures/BaseTest.sol";

import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

import { MintableERC20 } from "test/__fixtures/MintableERC20.sol";
import { AssetManager } from "test/__mocks/AssetManager.sol";

import { Math } from "src/libraries/Math.sol";
import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { GenericFactory } from "src/GenericFactory.sol";
import { ConstantProductPair } from "src/curve/constant-product/ConstantProductPair.sol";

contract ConstantProductPairTest is BaseTest
{
    AssetManager private _manager = new AssetManager();

    function _calculateOutput(
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

    function _getToken0Token1(address aTokenA, address aTokenB) private pure returns (address rToken0, address rToken1)
    {
        (rToken0, rToken1) = aTokenA < aTokenB ? (aTokenA, aTokenB) : (aTokenB, aTokenA);
    }

    function testCustomSwapFee_OffByDefault() public
    {
        // assert
        assertEq(_constantProductPair.customSwapFee(), type(uint).max);
        assertEq(_constantProductPair.swapFee(), 30);
    }

    function testSetSwapFeeForPair() public
    {
        // act
        _factory.rawCall(
            address(_constantProductPair),
            abi.encodeWithSignature("setCustomSwapFee(uint256)", 100),
            0
        );

        // assert
        assertEq(_constantProductPair.customSwapFee(), 100);
        assertEq(_constantProductPair.swapFee(), 100);
    }

    function testSetSwapFeeForPair_Reset() public
    {
        // arrange
        _factory.rawCall(
            address(_constantProductPair),
            abi.encodeWithSignature("setCustomSwapFee(uint256)", 100),
            0
        );

        // act
        _factory.rawCall(
            address(_constantProductPair),
            abi.encodeWithSignature("setCustomSwapFee(uint256)", type(uint).max),
            0
        );

        // assert
        assertEq(_constantProductPair.customSwapFee(), type(uint).max);
        assertEq(_constantProductPair.swapFee(), 30);
    }

    function testSetSwapFeeForPair_BreachMaximum() public
    {
        // act & assert
        vm.expectRevert("CP: INVALID_SWAP_FEE");
        _factory.rawCall(
            address(_constantProductPair),
            abi.encodeWithSignature("setCustomSwapFee(uint256)", 4000),
            0
        );
    }

    function testCustomPlatformFee_OffByDefault() public
    {
        // assert
        assertEq(_constantProductPair.customPlatformFee(), type(uint).max);
        assertEq(_constantProductPair.platformFee(), 2500);
    }

    function testSetPlatformFeeForPair() public
    {
        // act
        _factory.rawCall(
            address(_constantProductPair),
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", 100),
            0
        );

        // assert
        assertEq(_constantProductPair.customPlatformFee(), 100);
        assertEq(_constantProductPair.platformFee(), 100);
    }

    function testSetPlatformFeeForPair_Reset() public
    {
        // arrange
        _factory.rawCall(
            address(_constantProductPair),
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", 100),
            0
        );

        // act
        _factory.rawCall(
            address(_constantProductPair),
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", type(uint).max),
            0
        );

        // assert
        assertEq(_constantProductPair.customPlatformFee(), type(uint).max);
        assertEq(_constantProductPair.platformFee(), 2500);
    }

    function testSetPlatformFeeForPair_BreachMaximum() public
    {
        // act & assert
        vm.expectRevert("CP: INVALID_PLATFORM_FEE");
        _factory.rawCall(
            address(_constantProductPair),
            abi.encodeWithSignature("setCustomPlatformFee(uint256)", 9000),
            0
        );
    }

    function testUpdateDefaultFees() public
    {
        // arrange
        _factory.set(keccak256("ConstantProductPair::swapFee"), bytes32(uint256(200)));
        _factory.set(keccak256("ConstantProductPair::platformFee"), bytes32(uint256(5000)));

        // act
        _constantProductPair.updateSwapFee();
        _constantProductPair.updatePlatformFee();

        // assert
        assertEq(_constantProductPair.swapFee(), 200);
        assertEq(_constantProductPair.platformFee(), 5000);
    }

    function testMint() public
    {
        // arrange
        uint256 lTotalSupplyLpToken = _constantProductPair.totalSupply();
        uint256 lLiquidityToAdd = 5e18;
        (uint256 reserve0, , ) = _constantProductPair.getReserves();

        // act
        _tokenA.mint(address(_constantProductPair), lLiquidityToAdd);
        _tokenB.mint(address(_constantProductPair), lLiquidityToAdd);
        _constantProductPair.mint(address(this));

        // assert
        uint256 lAdditionalLpTokens = lLiquidityToAdd * lTotalSupplyLpToken / reserve0;
        assertEq(_constantProductPair.balanceOf(address(this)), lAdditionalLpTokens);
    }

    function testMint_InitialMint() public
    {
        // assert
        uint256 lpTokenBalance = _constantProductPair.balanceOf(_alice);
        uint256 lExpectedLpTokenBalance = Math.sqrt(INITIAL_MINT_AMOUNT ** 2) - _constantProductPair.MINIMUM_LIQUIDITY();
        assertEq(lpTokenBalance, lExpectedLpTokenBalance);
    }

    function testMint_JustAboveMinimumLiquidity() public
    {
        // arrange
        ConstantProductPair lPair = ConstantProductPair(_createPair(address(_tokenA), address(_tokenC), 0));

        // act
        _tokenA.mint(address(lPair), 1001);
        _tokenC.mint(address(lPair), 1001);
        lPair.mint(address(this));

        // assert
        assertEq(lPair.balanceOf(address(this)), 1);
    }

    function testMint_MinimumLiquidity() public
    {
        // arrange
        ConstantProductPair lPair = ConstantProductPair(_createPair(address(_tokenA), address(_tokenC), 0));
        _tokenA.mint(address(lPair), 1000);
        _tokenC.mint(address(lPair), 1000);

        // act & assert
        vm.expectRevert("CP: INSUFFICIENT_LIQ_MINTED");
        lPair.mint(address(this));
    }

    function testMint_UnderMinimumLiquidity() public
    {
        // arrange
        ConstantProductPair lPair = ConstantProductPair(_createPair(address(_tokenA), address(_tokenC), 0));
        _tokenA.mint(address(lPair), 10);
        _tokenB.mint(address(lPair), 10);

        // act & assert
        vm.expectRevert(stdError.arithmeticError);
        lPair.mint(address(this));
    }

    function testSwap() public
    {
        // arrange
        (uint256 reserve0, uint256 reserve1, ) = _constantProductPair.getReserves();
        uint256 expectedOutput = _calculateOutput(reserve0, reserve1, 1e18, 30);

        // act
        address token0;
        address token1;
        (token0, token1) = _getToken0Token1(address(_tokenA), address(_tokenB));

        MintableERC20(token0).mint(address(_constantProductPair), 1e18);
        _constantProductPair.swap(0, expectedOutput, address(this), "");

        // assert
        assertEq(MintableERC20(token1).balanceOf(address(this)), expectedOutput);
        assertEq(MintableERC20(token0).balanceOf(address(this)), 0);
    }

    function testBurn() public
    {
        // arrange
        vm.startPrank(_alice);
        uint256 lLpTokenBalance = _constantProductPair.balanceOf(_alice);
        uint256 lLpTokenTotalSupply = _constantProductPair.totalSupply();
        (uint256 lReserve0, uint256 lReserve1, ) = _constantProductPair.getReserves();

        // act
        _constantProductPair.transfer(address(_constantProductPair), _constantProductPair.balanceOf(_alice));
        _constantProductPair.burn(_alice);

        // assert
        assertEq(_constantProductPair.balanceOf(_alice), 0);
        (address lToken0, address lToken1) = _getToken0Token1(address(_tokenA), address(_tokenB));
        assertEq(ConstantProductPair(lToken0).balanceOf(_alice), lLpTokenBalance * lReserve0 / lLpTokenTotalSupply);
        assertEq(ConstantProductPair(lToken1).balanceOf(_alice), lLpTokenBalance * lReserve1 / lLpTokenTotalSupply);
    }

    function testSync() public
    {
        // arrange
        vm.prank(address(_factory));
        _constantProductPair.setManager(_manager);
        _manager.adjustManagement(_constantProductPair, 20e18, 20e18);
        _manager.adjustBalance(address(_constantProductPair), _constantProductPair.token0(), 25e18);
        _manager.adjustBalance(address(_constantProductPair), _constantProductPair.token1(), 26e18);

        // act
        _constantProductPair.sync();

        // assert
        (uint112 lReserve0, uint112 lReserve1, ) = _constantProductPair.getReserves();
        assertEq(_constantProductPair.token0Managed(), 25e18);
        assertEq(lReserve0, 105e18);
        assertEq(lReserve1, 106e18);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    ASSET MANAGEMENT
    //////////////////////////////////////////////////////////////////////////*/

    function testSetManager() external
    {
        // sanity
        assertEq(address(_constantProductPair.assetManager()), address(0));

        // act
        vm.prank(address(_factory));
        _constantProductPair.setManager(_manager);

        // assert
        assertEq(address(_constantProductPair.assetManager()), address(_manager));
    }

    function testSetManager_CannotMigrateWithManaged() external
    {
        // arrange
        vm.prank(address(_factory));
        _constantProductPair.setManager(_manager);

        _manager.adjustManagement(_constantProductPair, 10e18, 10e18);

        // act & assert
        vm.prank(address(_factory));
        vm.expectRevert("CP: AM_STILL_ACTIVE");
        _constantProductPair.setManager(IAssetManager(address(0)));
    }

    function testManageReserves() external
    {
        // arrange
        _tokenA.mint(address(_constantProductPair), 50e18);
        _tokenB.mint(address(_constantProductPair), 50e18);
        _constantProductPair.mint(address(this));

        vm.prank(address(_factory));
        _constantProductPair.setManager(IAssetManager(address(this)));

        // act
        _constantProductPair.adjustManagement(20e18, 20e18);

        // assert
        assertEq(_tokenA.balanceOf(address(this)), 20e18);
        assertEq(_tokenB.balanceOf(address(this)), 20e18);
    }

    function testManageReserves_KStillHolds() external
    {
        // arrange
        vm.prank(address(_factory));
        _constantProductPair.setManager(_manager);

        // liquidity prior to adjustManagement
        _tokenA.mint(address(_constantProductPair), 50e18);
        _tokenB.mint(address(_constantProductPair), 50e18);
        uint256 lLiq1 = _constantProductPair.mint(address(this));

        _manager.adjustManagement(_constantProductPair, 50e18, 50e18);

        // act
        _tokenA.mint(address(_constantProductPair), 50e18);
        _tokenB.mint(address(_constantProductPair), 50e18);
        uint256 lLiq2 = _constantProductPair.mint(address(this));

        // assert
        assertEq(lLiq1, lLiq2);
    }

    function testManageReserves_DecreaseManagement() external
    {
        // arrange
        vm.prank(address(_factory));
        _constantProductPair.setManager(_manager);

        address lToken0 = _constantProductPair.token0();
        address lToken1 = _constantProductPair.token1();

        // sanity
        (uint112 lReserve0, uint112 lReserve1, ) = _constantProductPair.getReserves();
        uint256 lBal0Before = IERC20(lToken0).balanceOf(address(_constantProductPair));
        uint256 lBal1Before = IERC20(lToken1).balanceOf(address(_constantProductPair));

        _manager.adjustManagement(_constantProductPair, 20e18, 20e18);

        //solhint-disable-next-line var-name-mixedcase
        (uint112 lReserve0_1, uint112 lReserve1_1, ) = _constantProductPair.getReserves();
        uint256 lBal0After = IERC20(lToken0).balanceOf(address(_constantProductPair));
        uint256 lBal1After = IERC20(lToken1).balanceOf(address(_constantProductPair));

        assertEq(uint256(lReserve0_1), lReserve0);
        assertEq(uint256(lReserve1_1), lReserve1);
        assertEq(lBal0Before - lBal0After, 20e18);
        assertEq(lBal1Before - lBal1After, 20e18);

        assertEq(IERC20(lToken0).balanceOf(address(_manager)), 20e18);
        assertEq(IERC20(lToken1).balanceOf(address(_manager)), 20e18);
        assertEq(_manager.getBalance(address(_constantProductPair), address(lToken0)), 20e18);
        assertEq(_manager.getBalance(address(_constantProductPair), address(lToken1)), 20e18);

        // act
        _manager.adjustManagement(_constantProductPair, -10e18, -10e18);

        //solhint-disable-next-line var-name-mixedcase
        (uint112 lReserve0_2, uint112 lReserve1_2, ) = _constantProductPair.getReserves();

        // assert
        assertEq(uint256(lReserve0_2), lReserve0);
        assertEq(uint256(lReserve1_2), lReserve1);
        assertEq(IERC20(lToken0).balanceOf(address(_manager)), 10e18);
        assertEq(IERC20(lToken1).balanceOf(address(_manager)), 10e18);
        assertEq(_manager.getBalance(address(_constantProductPair), address(lToken0)), 10e18);
        assertEq(_manager.getBalance(address(_constantProductPair), address(lToken1)), 10e18);
    }

    function testSyncManaged() external
    {
        // arrange
        vm.prank(address(_factory));
        _constantProductPair.setManager(_manager);

        address lToken0 = _constantProductPair.token0();
        address lToken1 = _constantProductPair.token1();

        _manager.adjustManagement(_constantProductPair, 20e18, 20e18);
        _tokenA.mint(address(_constantProductPair), 10e18);
        _tokenB.mint(address(_constantProductPair), 10e18);
        uint256 lLiq = _constantProductPair.mint(address(this));

        // sanity
        assertEq(lLiq, 10e18); // sqrt(10e18, 10e18)
        assertEq(_tokenA.balanceOf(address(this)), 0);
        assertEq(_tokenB.balanceOf(address(this)), 0);
        assertEq(_manager.getBalance(address(_constantProductPair), lToken0), 20e18);
        assertEq(_manager.getBalance(address(_constantProductPair), lToken1), 20e18);

        // act
        _manager.adjustBalance(address(_constantProductPair), lToken0, 19e18); // 1e18 lost
        _manager.adjustBalance(address(_constantProductPair), lToken1, 19e18); // 1e18 lost
        _constantProductPair.transfer(address(_constantProductPair), 10e18);
        _constantProductPair.burn(address(this));

        // assert
        assertEq(_manager.getBalance(address(_constantProductPair), lToken0), 19e18);
        assertEq(_manager.getBalance(address(_constantProductPair), lToken1), 19e18);
        assertLt(_tokenA.balanceOf(address(this)), 10e18);
        assertLt(_tokenB.balanceOf(address(this)), 10e18);
    }
}
