pragma solidity 0.8.13;

import "test/__fixtures/BaseTest.sol";

import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";

import { IPoolAddressesProvider } from "src/interfaces/aave/IPoolAddressesProvider.sol";
import { IPool } from "src/interfaces/aave/IPool.sol";
import { IAaveProtocolDataProvider } from "src/interfaces/aave/IAaveProtocolDataProvider.sol";

import { MathUtils } from "src/libraries/MathUtils.sol";
import { AaveManager } from "src/asset-manager/AaveManager.sol";

contract AaveIntegrationTest is BaseTest
{
    address public constant FTM_USDC = address(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75);
    address public constant FTM_AAVE_POOL_ADDRESS_PROVIDER = address(0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb);
    address public constant FTM_AAVE_POOL = address(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    address public constant FTM_AAVE_POOL_DATA_PROVIDER = address(0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654);

    AaveManager private _manager = new AaveManager(FTM_AAVE_POOL_ADDRESS_PROVIDER);

    function setUp() public
    {
        // mint some USDC to this address
        deal(FTM_USDC, address(this), INITIAL_MINT_AMOUNT, true);

        _uniswapV2Pair = UniswapV2Pair(_createPair(address(_tokenA), FTM_USDC, 0));
        IERC20(FTM_USDC).transfer(address(_uniswapV2Pair), INITIAL_MINT_AMOUNT);
        _tokenA.mint((address(_uniswapV2Pair)), INITIAL_MINT_AMOUNT);
        _uniswapV2Pair.mint(_alice);

        vm.prank(address(_factory));
        _uniswapV2Pair.setManager(_manager);
    }

    function testAddresses() public
    {
        assertEq(address(_manager.pool()), FTM_AAVE_POOL);
        assertEq(address(_manager.dataProvider()), FTM_AAVE_POOL_DATA_PROVIDER);
    }

    function testAdjustManagement_IncreaseManagementOneToken() public
    {
        // arrange
        int256 lAmountToManage = 500e6;

        // act
        _manager.adjustManagement(address(_uniswapV2Pair), lAmountToManage, 0);

        // assert
        IAaveProtocolDataProvider lDataProvider = _manager.dataProvider();
        (address lATokenAddress, , ) = lDataProvider.getReserveTokensAddresses(_uniswapV2Pair.token0());

        assertEq(_uniswapV2Pair.token0Managed(), uint256(lAmountToManage));
        assertEq(IERC20(FTM_USDC).balanceOf(address(_uniswapV2Pair)), INITIAL_MINT_AMOUNT - uint256(lAmountToManage));
        assertEq(_manager.shares(address(_uniswapV2Pair), _uniswapV2Pair.token0()), uint256(lAmountToManage));
        assertEq(IERC20(lATokenAddress).balanceOf(address(_manager)), uint256(lAmountToManage));
    }

    function testAdjustManagement_DecreaseManagementOneToken() public
    {
        // arrange
        int256 lAmountToManage = 500e6;
        _manager.adjustManagement(address(_uniswapV2Pair), lAmountToManage, 0);

        // act
        _manager.adjustManagement(address(_uniswapV2Pair), -lAmountToManage, 0);

        // assert
        IAaveProtocolDataProvider lDataProvider = _manager.dataProvider();
        (address lATokenAddress, , ) = lDataProvider.getReserveTokensAddresses(_uniswapV2Pair.token0());

        assertEq(_uniswapV2Pair.token0Managed(), 0);
        assertEq(IERC20(FTM_USDC).balanceOf(address(_uniswapV2Pair)), INITIAL_MINT_AMOUNT);
        assertEq(IERC20(lATokenAddress).balanceOf(address(this)), 0);
    }

    function testAdjustManagement_DecreaseManagementBeyondShare() public
    {
        // arrange
        UniswapV2Pair lOtherPair = UniswapV2Pair(_createPair(address(_tokenB), FTM_USDC, 0));
        _tokenB.mint(address(lOtherPair), INITIAL_MINT_AMOUNT);
        deal(FTM_USDC, address(lOtherPair), INITIAL_MINT_AMOUNT, true);
        lOtherPair.mint(_alice);
        vm.prank(address(_factory));
        lOtherPair.setManager(_manager);
        int256 lAmountToManage1 = 500e6;
        int256 lAmountToManage2 = 500e6;

        _manager.adjustManagement(address(_uniswapV2Pair), lAmountToManage1, 0);
        _manager.adjustManagement(address(lOtherPair), lAmountToManage2, 0);

        // act & assert
        vm.expectRevert(stdError.arithmeticError);
        _manager.adjustManagement(address(lOtherPair), -lAmountToManage2-1, 0);
    }

    function testGetBalance(uint256 aAmountToManage) public
    {
        // arrange
        IAaveProtocolDataProvider lDataProvider = _manager.dataProvider();
        (address lATokenAddress, , ) = lDataProvider.getReserveTokensAddresses(_uniswapV2Pair.token0());
        uint256 lTotalSupply = IERC20(lATokenAddress).totalSupply();
        int256 lAmountToManage = int256(bound(aAmountToManage, 0, lTotalSupply));
        _manager.adjustManagement(address(_uniswapV2Pair), lAmountToManage, 0);

        // act
        uint112 lBalance = _manager.getBalance(address(_uniswapV2Pair), FTM_USDC);

        // assert
        assertTrue(MathUtils.within1(lBalance, uint256(lAmountToManage)));
    }

    function testGetBalance_TwoPairsInSameMarket(uint256 aAmountToManage1, uint256 aAmountToManage2) public
    {
        // arrange
        UniswapV2Pair lOtherPair = UniswapV2Pair(_createPair(address(_tokenB), FTM_USDC, 0));
        _tokenB.mint(address(lOtherPair), INITIAL_MINT_AMOUNT);
        deal(FTM_USDC, address(lOtherPair), INITIAL_MINT_AMOUNT, true);
        lOtherPair.mint(_alice);
        vm.prank(address(_factory));
        lOtherPair.setManager(_manager);
        IAaveProtocolDataProvider lDataProvider = _manager.dataProvider();
        (address lATokenAddress, , ) = lDataProvider.getReserveTokensAddresses(_uniswapV2Pair.token0());
        uint256 lTotalSupply = IERC20(lATokenAddress).totalSupply();
        int256 lAmountToManage1 = int256(bound(aAmountToManage1, 1, lTotalSupply));
        int256 lAmountToManage2 = int256(bound(aAmountToManage2, 1, lTotalSupply));

        // act
        _manager.adjustManagement(address(_uniswapV2Pair), lAmountToManage1, 0);
        _manager.adjustManagement(address(lOtherPair), lAmountToManage2, 0);

        // assert
        assertTrue(MathUtils.within1(_manager.getBalance(address(_uniswapV2Pair), FTM_USDC), uint256(lAmountToManage1)));
        assertTrue(MathUtils.within1(_manager.getBalance(address(lOtherPair), FTM_USDC), uint256(lAmountToManage2)));
    }
}
