pragma solidity 0.8.13;

import "test/__fixtures/BaseTest.sol";

import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";
import { CERC20 } from "libcompound/interfaces/CERC20.sol";
import { LibCompound } from "libcompound/LibCompound.sol";

import { IComptroller } from "src/interfaces/IComptroller.sol";
import { MathUtils } from "src/libraries/MathUtils.sol";

/// @dev we extend the interface here instead of placing it in IComptroller
/// to eliminate mistakenly calling it in production code
interface IComptrollerTest is IComptroller
{
    function getAllMarkets() external view returns (CERC20[] memory);
}

contract CompoundIntegrationTest is BaseTest
{
    address public constant ETH_MAINNET_USDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address public constant ETH_MAINNET_CUSDC = address(0x39AA39c021dfbaE8faC545936693aC917d5E7563);
    uint256 public constant ETH_MAINNET_CUSDC_MARKET_INDEX = 4;

    function setUp() public
    {
        // mint some USDC to this address
        deal(ETH_MAINNET_USDC, address(this), INITIAL_MINT_AMOUNT, true);

        _uniswapV2Pair = _createPair(address(_tokenA), ETH_MAINNET_USDC);

        vm.prank(address(_factory));
        _uniswapV2Pair.setManager(_manager);

        IERC20(ETH_MAINNET_USDC).transfer(address(_uniswapV2Pair), INITIAL_MINT_AMOUNT);
        _tokenA.mint((address(_uniswapV2Pair)), INITIAL_MINT_AMOUNT);
        _uniswapV2Pair.mint(_alice);
    }

    function testAdjustManagement_IncreaseManagementOneToken() public
    {
        // arrange
        int256 lAmountToManage = 500e6;

        // act
        _manager.adjustManagement(address(_uniswapV2Pair), lAmountToManage, 0, ETH_MAINNET_CUSDC_MARKET_INDEX, 0);

        // assert
        uint256 lExchangeRate = LibCompound.viewExchangeRate(CERC20(ETH_MAINNET_CUSDC));
        assertEq(_uniswapV2Pair.token0Managed(), uint256(lAmountToManage));
        assertEq(IERC20(ETH_MAINNET_USDC).balanceOf(address(_uniswapV2Pair)), INITIAL_MINT_AMOUNT - uint256(lAmountToManage));
        assertEq(IERC20(ETH_MAINNET_CUSDC).balanceOf(address(_manager)), uint256(lAmountToManage) * 1e18 / lExchangeRate);
    }

    function testAdjustManagement_DecreaseManagementOneToken() public
    {
        // arrange
        int256 lAmountToManage = 500e6;
        _manager.adjustManagement(address(_uniswapV2Pair), lAmountToManage, 0, ETH_MAINNET_CUSDC_MARKET_INDEX, 0);

        // act
        _manager.adjustManagement(address(_uniswapV2Pair), -lAmountToManage, 0, ETH_MAINNET_CUSDC_MARKET_INDEX, 0);

        // assert
        assertEq(_uniswapV2Pair.token0Managed(), 0);
        assertEq(IERC20(ETH_MAINNET_USDC).balanceOf(address(_uniswapV2Pair)), INITIAL_MINT_AMOUNT);
        assertEq(IERC20(ETH_MAINNET_CUSDC).balanceOf(address(this)), 0);
    }

    function testAdjustManagement_DecreaseManagementBeyondShare() public
    {
        // arrange
        UniswapV2Pair lOtherPair = _createPair(address(_tokenB), ETH_MAINNET_USDC);
        _tokenB.mint(address(lOtherPair), INITIAL_MINT_AMOUNT);
        deal(ETH_MAINNET_USDC, address(lOtherPair), INITIAL_MINT_AMOUNT, true);
        lOtherPair.mint(_alice);
        vm.prank(address(_factory));
        lOtherPair.setManager(_manager);
        int256 lAmountToManage1 = 500e6;
        int256 lAmountToManage2 = 500e6;

        _manager.adjustManagement(address(_uniswapV2Pair), lAmountToManage1, 0, ETH_MAINNET_CUSDC_MARKET_INDEX, 0);
        _manager.adjustManagement(address(lOtherPair), lAmountToManage2, 0, ETH_MAINNET_CUSDC_MARKET_INDEX, 0);

        // act & assert
        vm.expectRevert(stdError.arithmeticError);
        _manager.adjustManagement(address(lOtherPair), -lAmountToManage2-1, 0, ETH_MAINNET_CUSDC_MARKET_INDEX, 0);
    }

    function testAdjustManagement_MarketIndexIncorrect(uint256 aIndex) public
    {
        // arrange
        int256 lAmountToManage = 500e6;
        CERC20[] memory lAllMarkets = IComptrollerTest(ETH_MAINNET_COMPOUND_COMPTROLLER).getAllMarkets();
        aIndex = bound(aIndex, 0, lAllMarkets.length - 1);
        vm.assume(aIndex != ETH_MAINNET_CUSDC_MARKET_INDEX);

        // act & assert
        vm.expectRevert("WRONG MARKET FOR TOKEN");
        _manager.adjustManagement(address(_uniswapV2Pair), lAmountToManage, 0, aIndex, 0);
    }

    function testAdjustManagement_MarketIndexOutOfBound() public
    {
        // arrange
        int256 lAmountToManage = 500e6;
        CERC20[] memory lAllMarkets = IComptrollerTest(ETH_MAINNET_COMPOUND_COMPTROLLER).getAllMarkets();

        // act & assert
        vm.expectRevert();
        _manager.adjustManagement(address(_uniswapV2Pair), lAmountToManage, 0, lAllMarkets.length, 0);
    }

    function testGetBalance() public
    {
        // arrange
        int256 lAmountToManage = 500e6;
        _manager.adjustManagement(address(_uniswapV2Pair), lAmountToManage, 0, ETH_MAINNET_CUSDC_MARKET_INDEX, 0);

        // act
        uint112 lBalance = _manager.getBalance(address(_uniswapV2Pair), ETH_MAINNET_USDC);

        // assert
        assertTrue(MathUtils.within1(lBalance, uint256(lAmountToManage)));
    }

    function testGetBalance_TwoPairsInSameMarket(uint256 aAmountToManage1, uint256 aAmountToManage2) public
    {
        // arrange
        UniswapV2Pair lOtherPair = _createPair(address(_tokenB), ETH_MAINNET_USDC);
        _tokenB.mint(address(lOtherPair), INITIAL_MINT_AMOUNT);
        deal(ETH_MAINNET_USDC, address(lOtherPair), INITIAL_MINT_AMOUNT, true);
        lOtherPair.mint(_alice);
        vm.prank(address(_factory));
        lOtherPair.setManager(_manager);
        int256 lAmountToManage1 = int256(bound(aAmountToManage1, 1, INITIAL_MINT_AMOUNT));
        int256 lAmountToManage2 = int256(bound(aAmountToManage2, 1, INITIAL_MINT_AMOUNT));

        // act
        _manager.adjustManagement(address(_uniswapV2Pair), lAmountToManage1, 0, ETH_MAINNET_CUSDC_MARKET_INDEX, 0);
        _manager.adjustManagement(address(lOtherPair), lAmountToManage2, 0, ETH_MAINNET_CUSDC_MARKET_INDEX, 0);

        // assert
        assertEq(address(_manager.markets(address(_uniswapV2Pair), ETH_MAINNET_USDC)), address(_manager.markets(address(lOtherPair), ETH_MAINNET_USDC)));
        assertTrue(MathUtils.within1(_manager.getBalance(address(_uniswapV2Pair), ETH_MAINNET_USDC), uint256(lAmountToManage1)));
        assertTrue(MathUtils.within1(_manager.getBalance(address(lOtherPair), ETH_MAINNET_USDC), uint256(lAmountToManage2)));
    }
}
