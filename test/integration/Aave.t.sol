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
    // this amount is tailored to USDC as it only has 6 decimal places
    // using the usual 100e18 would be too large and would break AAVE
    uint256 public constant MINT_AMOUNT = 1_000_000e6;

    address public constant FTM_USDC = address(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75);
    address public constant FTM_AAVE_POOL_ADDRESS_PROVIDER = address(0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb);

    AaveManager private _manager = new AaveManager(FTM_AAVE_POOL_ADDRESS_PROVIDER);

    function setUp() public
    {
        // mint some USDC to this address
        deal(FTM_USDC, address(this), MINT_AMOUNT, true);

        _constantProductPair = ConstantProductPair(_createPair(address(_tokenA), FTM_USDC, 0));
        IERC20(FTM_USDC).transfer(address(_constantProductPair), MINT_AMOUNT);
        _tokenA.mint((address(_constantProductPair)), MINT_AMOUNT);
        _constantProductPair.mint(_alice);

        vm.prank(address(_factory));
        _constantProductPair.setManager(_manager);
    }

    function _createOtherPair() private returns (ConstantProductPair rOtherPair)
    {
        rOtherPair = ConstantProductPair(_createPair(address(_tokenB), FTM_USDC, 0));
        _tokenB.mint(address(rOtherPair), MINT_AMOUNT);
        deal(FTM_USDC, address(rOtherPair), MINT_AMOUNT, true);
        rOtherPair.mint(_alice);
        vm.prank(address(_factory));
        rOtherPair.setManager(_manager);
    }

    function testAdjustManagement_IncreaseManagementOneToken() public
    {
        // arrange
        int256 lAmountToManage = 500e6;

        // act
        _manager.adjustManagement(address(_constantProductPair), lAmountToManage, 0);

        // assert
        IAaveProtocolDataProvider lDataProvider = _manager.dataProvider();
        (address lAaveToken, , ) = lDataProvider.getReserveTokensAddresses(_constantProductPair.token0());

        assertEq(_constantProductPair.token0Managed(), uint256(lAmountToManage));
        assertEq(IERC20(FTM_USDC).balanceOf(address(_constantProductPair)), MINT_AMOUNT - uint256(lAmountToManage));
        assertEq(IERC20(lAaveToken).balanceOf(address(_manager)), uint256(lAmountToManage));
        assertEq(_manager.shares(address(_constantProductPair), _constantProductPair.token0()), uint256(lAmountToManage));
        assertEq(_manager.totalShares(lAaveToken), uint256(lAmountToManage));
    }

    function testAdjustManagement_DecreaseManagementOneToken() public
    {
        // arrange
        int256 lAmountToManage = 500e6;
        testAdjustManagement_IncreaseManagementOneToken();

        // act
        _manager.adjustManagement(address(_constantProductPair), -lAmountToManage, 0);

        // assert
        IAaveProtocolDataProvider lDataProvider = _manager.dataProvider();
        (address lAaveToken, , ) = lDataProvider.getReserveTokensAddresses(_constantProductPair.token0());

        assertEq(_constantProductPair.token0Managed(), 0);
        assertEq(IERC20(FTM_USDC).balanceOf(address(_constantProductPair)), MINT_AMOUNT);
        assertEq(IERC20(lAaveToken).balanceOf(address(this)), 0);
        assertEq(_manager.shares(address(_constantProductPair), address(FTM_USDC)), 0);
        assertEq(_manager.totalShares(lAaveToken), 0);
    }

    function testAdjustManagement_DecreaseManagementBeyondShare() public
    {
        // arrange
        ConstantProductPair lOtherPair = _createOtherPair();
        int256 lAmountToManage1 = 500e6;
        int256 lAmountToManage2 = 500e6;

        _manager.adjustManagement(address(_constantProductPair), lAmountToManage1, 0);
        _manager.adjustManagement(address(lOtherPair), lAmountToManage2, 0);

        // act & assert
        vm.expectRevert(stdError.arithmeticError);
        _manager.adjustManagement(address(lOtherPair), -lAmountToManage2-1, 0);
    }

    function testGetBalance(uint256 aAmountToManage) public
    {
        // arrange
        (uint256 lReserve0, , ) = _constantProductPair.getReserves();
        int256 lAmountToManage = int256(bound(aAmountToManage, 0, lReserve0));
        _manager.adjustManagement(address(_constantProductPair), lAmountToManage, 0);

        // act
        uint112 lBalance = _manager.getBalance(address(_constantProductPair), FTM_USDC);

        // assert
        assertTrue(MathUtils.within1(lBalance, uint256(lAmountToManage)));
    }

    function testGetBalance_NoShares(address aToken) public
    {
        // arrange
        vm.assume(aToken != FTM_USDC);
        int256 lAmountToManage = 500e6;
        _manager.adjustManagement(address(_constantProductPair), lAmountToManage, 0);

        // act
        uint256 lRes = _manager.getBalance(address(_constantProductPair), aToken);

        // assert
        assertEq(lRes, 0);
    }

    function testGetBalance_TwoPairsInSameMarket(uint256 aAmountToManage1, uint256 aAmountToManage2) public
    {
        // arrange
        ConstantProductPair lOtherPair = _createOtherPair();
        (uint256 lReserve0, , ) = _constantProductPair.getReserves();
        int256 lAmountToManage1 = int256(bound(aAmountToManage1, 1, lReserve0));
        int256 lAmountToManage2 = int256(bound(aAmountToManage2, 1, lReserve0));

        // act
        _manager.adjustManagement(address(_constantProductPair), lAmountToManage1, 0);
        _manager.adjustManagement(address(lOtherPair), lAmountToManage2, 0);

        // assert
        assertTrue(MathUtils.within1(_manager.getBalance(address(_constantProductPair), FTM_USDC), uint256(lAmountToManage1)));
        assertTrue(MathUtils.within1(_manager.getBalance(address(lOtherPair), FTM_USDC), uint256(lAmountToManage2)));
    }

    function testGetBalance_AddingAfterExchangeRateChange(
        uint256 aAmountToManage1,
        uint256 aAmountToManage2,
        uint256 aTime
    ) public
    {
        // arrange
        ConstantProductPair lOtherPair = _createOtherPair();
        (address lAaveToken, , ) = _manager.dataProvider().getReserveTokensAddresses(_constantProductPair.token0());
        (uint256 lReserve0, , ) = _constantProductPair.getReserves();
        int256 lAmountToManage1 = int256(bound(aAmountToManage1, 1, lReserve0));
        _manager.adjustManagement(address(_constantProductPair), lAmountToManage1, 0);

        // act
        skip(bound(aTime, 1, 52 weeks));
        uint256 lAaveTokenAmt2 = IERC20(lAaveToken).balanceOf(address(_manager));
        int256 lAmountToManage2 = int256(bound(aAmountToManage2, 1, lReserve0));
        _manager.adjustManagement(address(lOtherPair), lAmountToManage2, 0);

        // assert
        assertEq(_manager.shares(address(_constantProductPair), FTM_USDC), uint256(lAmountToManage1));
        assertTrue(MathUtils.within1(_manager.getBalance(address(_constantProductPair), FTM_USDC), lAaveTokenAmt2));

        uint256 lExpectedShares
            = uint256(lAmountToManage2) * 1e18
            / (lAaveTokenAmt2 * 1e18 / uint256(lAmountToManage1));
        assertEq(_manager.shares(address(lOtherPair), FTM_USDC), lExpectedShares);
        assertTrue(MathUtils.within1(_manager.getBalance(address(lOtherPair), FTM_USDC), uint256(lAmountToManage2)));
    }

    function testShares(uint256 aAmountToManage) public
    {
        // arrange
        IAaveProtocolDataProvider lDataProvider = _manager.dataProvider();
        (address lAaveToken, , ) = lDataProvider.getReserveTokensAddresses(_constantProductPair.token0());
        (uint256 lReserve0, , ) = _constantProductPair.getReserves();
        int256 lAmountToManage = int256(bound(aAmountToManage, 0, lReserve0));
        _manager.adjustManagement(address(_constantProductPair), lAmountToManage, 0);

        // act
        uint256 lShares = _manager.shares(address(_constantProductPair), FTM_USDC);
        uint256 lTotalShares = _manager.totalShares(lAaveToken);

        // assert
        assertEq(lShares, lTotalShares);
        assertEq(lShares, uint256(lAmountToManage));
        assertEq(lTotalShares, uint256(lAmountToManage));
    }

    function testCallback_IncreaseInvestmentAfterMint() public
    {
        // sanity
        uint256 lAmountManaged = _manager.getBalance(address(_constantProductPair), FTM_USDC);
        assertEq(lAmountManaged, 0);

        // act
        _tokenA.mint(address(_constantProductPair), 500e6);
        deal(FTM_USDC, address(this), 500e6, true);
        IERC20(FTM_USDC).transfer(address(_constantProductPair), 500e6);
        _constantProductPair.mint(address(this));

        // assert
        uint256 lNewAmount = _manager.getBalance(address(_constantProductPair), FTM_USDC);
        (uint256 lReserve0, , ) = _constantProductPair.getReserves();
        assertEq(lNewAmount, lReserve0 * (_manager.lowerThreshold() + _manager.upperThreshold()) / 2 / 100);
    }

    function testCallback_DecreaseInvestmentAfterBurn(uint256 aInitialAmount) public
    {
        // arrange
        (uint256 lReserve0, , ) = _constantProductPair.getReserves();
        uint256 lInitialAmount = bound(aInitialAmount, lReserve0 * (_manager.upperThreshold() + 2) / 100, lReserve0);
        _manager.adjustManagement(address(_constantProductPair), int256(lInitialAmount), 0);

        // act
        vm.prank(_alice);
        IERC20(address(_constantProductPair)).transfer(address(_constantProductPair), 100e6);
        _constantProductPair.burn(address(this));

        // assert
        uint256 lNewAmount = _manager.getBalance(address(_constantProductPair), FTM_USDC);
        (uint256 lReserve0After, , ) = _constantProductPair.getReserves();
        assertTrue(MathUtils.within1(lNewAmount, lReserve0After * (_manager.lowerThreshold() + _manager.upperThreshold()) / 2 / 100));
    }

    function testCallback_ShouldFailIfNotPair() public
    {
        // act & assert
        vm.expectRevert();
        _manager.afterLiquidityEvent();

        // act & assert
        vm.prank(_alice);
        vm.expectRevert();
        _manager.afterLiquidityEvent();
    }

    function testSetUpperThreshold_BreachMaximum() public
    {
        // act & assert
        vm.expectRevert("AM: INVALID_THRESHOLD");
        _manager.setUpperThreshold(101);
    }

    function testSetUpperThreshold_LessThanEqualLowerThreshold(uint256 aThreshold) public
    {
        // arrange
        uint256 lThreshold = bound(aThreshold, 0, _manager.lowerThreshold());

        // act & assert
        vm.expectRevert("AM: INVALID_THRESHOLD");
        _manager.setUpperThreshold(lThreshold);
    }

    function testSetLowerThreshold_MoreThanEqualUpperThreshold(uint256 aThreshold) public
    {
        // arrange
        uint256 lThreshold = bound(aThreshold, _manager.upperThreshold(), type(uint256).max);

        // act & assert
        vm.expectRevert("AM: INVALID_THRESHOLD");
        _manager.setLowerThreshold(lThreshold);
    }
}
