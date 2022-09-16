pragma solidity 0.8.13;

import "test/__fixtures/BaseTest.sol";

import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";

import { IAaveProtocolDataProvider } from "src/interfaces/aave/IAaveProtocolDataProvider.sol";
import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";

import { MathUtils } from "src/libraries/MathUtils.sol";
import { AaveManager } from "src/asset-management/AaveManager.sol";

contract AaveIntegrationTest is BaseTest
{
    // this amount is tailored to USDC as it only has 6 decimal places
    // using the usual 100e18 would be too large and would break AAVE
    uint256 public constant MINT_AMOUNT = 1_000_000e6;

    address public constant FTM_USDC = address(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75);
    address public constant FTM_AAVE_POOL_ADDRESS_PROVIDER = address(0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb);

    AaveManager private _manager = new AaveManager(FTM_AAVE_POOL_ADDRESS_PROVIDER);

    IAssetManagedPair[] internal _pairs;
    IAssetManagedPair   internal _pair;

    modifier parameterizedTest() {
        for (uint256 i = 0; i < _pairs.length; ++i) {
            uint256 lBefore = vm.snapshot();
            _pair = _pairs[i];
            _;
            vm.revertTo(lBefore);
        }
    }

    function setUp() public
    {
        deal(FTM_USDC, address(this), MINT_AMOUNT, true);
        _constantProductPair = ConstantProductPair(_createPair(address(_tokenA), FTM_USDC, 0));
        IERC20(FTM_USDC).transfer(address(_constantProductPair), MINT_AMOUNT);
        _tokenA.mint(address(_constantProductPair), MINT_AMOUNT);
        _constantProductPair.mint(_alice);
        vm.prank(address(_factory));
        _constantProductPair.setManager(_manager);

        deal(FTM_USDC, address(this), MINT_AMOUNT, true);
        _stablePair = StablePair(_createPair(address(_tokenA), FTM_USDC, 1));
        IERC20(FTM_USDC).transfer(address(_stablePair), MINT_AMOUNT);
        _tokenA.mint(address(_stablePair), 1_000_000e18);
        _stablePair.mint(_alice);
        vm.prank(address(_factory));
        _stablePair.setManager(_manager);

        _pairs.push(_constantProductPair);
        _pairs.push(_stablePair);
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

    function _increaseManagementOneToken() internal
    {
        // arrange
        int256 lAmountToManage = 500e6;

        // act
        _manager.adjustManagement(_pair, lAmountToManage, 0);

        // assert
        IAaveProtocolDataProvider lDataProvider = _manager.dataProvider();
        (address lAaveToken, , ) = lDataProvider.getReserveTokensAddresses(_pair.token0());

        assertEq(_pair.token0Managed(), uint256(lAmountToManage));
        assertEq(IERC20(FTM_USDC).balanceOf(address(_pair)), MINT_AMOUNT - uint256(lAmountToManage));
        assertEq(IERC20(lAaveToken).balanceOf(address(_manager)), uint256(lAmountToManage));
        assertEq(_manager.shares(_pair, _pair.token0()), uint256(lAmountToManage));
        assertEq(_manager.totalShares(lAaveToken), uint256(lAmountToManage));
    }

    function testAdjustManagement_IncreaseManagementOneToken() public parameterizedTest
    {
        _increaseManagementOneToken();
    }

    function testAdjustManagement_DecreaseManagementOneToken() public parameterizedTest
    {
        // arrange
        int256 lAmountToManage = 500e6;
        _increaseManagementOneToken();

        // act
        _manager.adjustManagement(_pair, -lAmountToManage, 0);

        // assert
        IAaveProtocolDataProvider lDataProvider = _manager.dataProvider();
        (address lAaveToken, , ) = lDataProvider.getReserveTokensAddresses(_pair.token0());

        assertEq(_pair.token0Managed(), 0);
        assertEq(IERC20(FTM_USDC).balanceOf(address(_pair)), MINT_AMOUNT);
        assertEq(IERC20(lAaveToken).balanceOf(address(this)), 0);
        assertEq(_manager.shares(_pair, address(FTM_USDC)), 0);
        assertEq(_manager.totalShares(lAaveToken), 0);
    }

    function testAdjustManagement_DecreaseManagementBeyondShare() public parameterizedTest
    {
        // arrange
        ConstantProductPair lOtherPair = _createOtherPair();
        int256 lAmountToManage1 = 500e6;
        int256 lAmountToManage2 = 500e6;

        _manager.adjustManagement(_pair, lAmountToManage1, 0);
        _manager.adjustManagement(lOtherPair, lAmountToManage2, 0);

        // act & assert
        vm.expectRevert(stdError.arithmeticError);
        _manager.adjustManagement(lOtherPair, -lAmountToManage2-1, 0);
    }

    function testGetBalance(uint256 aAmountToManage) public parameterizedTest
    {
        // arrange
        (uint256 lReserve0, , ) = _pair.getReserves();
        int256 lAmountToManage = int256(bound(aAmountToManage, 0, lReserve0));
        _manager.adjustManagement(_pair, lAmountToManage, 0);

        // act
        uint112 lBalance = _manager.getBalance(_pair, FTM_USDC);

        // assert
        assertTrue(MathUtils.within1(lBalance, uint256(lAmountToManage)));
    }

    function testGetBalance_NoShares(address aToken) public parameterizedTest
    {
        // arrange
        vm.assume(aToken != FTM_USDC);
        int256 lAmountToManage = 500e6;
        _manager.adjustManagement(_pair, lAmountToManage, 0);

        // act
        uint256 lRes = _manager.getBalance(_pair, aToken);

        // assert
        assertEq(lRes, 0);
    }

    function testGetBalance_TwoPairsInSameMarket(uint256 aAmountToManage1, uint256 aAmountToManage2) public parameterizedTest
    {
        // arrange
        ConstantProductPair lOtherPair = _createOtherPair();
        (uint256 lReserve0, , ) = _pair.getReserves();
        int256 lAmountToManage1 = int256(bound(aAmountToManage1, 1, lReserve0));
        int256 lAmountToManage2 = int256(bound(aAmountToManage2, 1, lReserve0));

        // act
        _manager.adjustManagement(_pair, lAmountToManage1, 0);
        _manager.adjustManagement(lOtherPair, lAmountToManage2, 0);

        // assert
        assertTrue(MathUtils.within1(_manager.getBalance(_pair, FTM_USDC), uint256(lAmountToManage1)));
        assertTrue(MathUtils.within1(_manager.getBalance(lOtherPair, FTM_USDC), uint256(lAmountToManage2)));
    }

    function testGetBalance_AddingAfterExchangeRateChange(
        uint256 aAmountToManage1,
        uint256 aAmountToManage2,
        uint256 aTime
    ) public parameterizedTest
    {
        // arrange
        ConstantProductPair lOtherPair = _createOtherPair();
        (address lAaveToken, , ) = _manager.dataProvider().getReserveTokensAddresses(_pair.token0());
        (uint256 lReserve0, , ) = _pair.getReserves();
        int256 lAmountToManage1 = int256(bound(aAmountToManage1, 1, lReserve0));
        _manager.adjustManagement(_pair, lAmountToManage1, 0);

        // act
        skip(bound(aTime, 1, 52 weeks));
        uint256 lAaveTokenAmt2 = IERC20(lAaveToken).balanceOf(address(_manager));
        int256 lAmountToManage2 = int256(bound(aAmountToManage2, 1, lReserve0));
        _manager.adjustManagement(lOtherPair, lAmountToManage2, 0);

        // assert
        assertEq(_manager.shares(_pair, FTM_USDC), uint256(lAmountToManage1));
        assertTrue(MathUtils.within1(_manager.getBalance(_pair, FTM_USDC), lAaveTokenAmt2));

        uint256 lExpectedShares
            = uint256(lAmountToManage2) * 1e18
            / (lAaveTokenAmt2 * 1e18 / uint256(lAmountToManage1));
        assertEq(_manager.shares(lOtherPair, FTM_USDC), lExpectedShares);
        assertTrue(MathUtils.within1(_manager.getBalance(lOtherPair, FTM_USDC), uint256(lAmountToManage2)));
    }

    function testShares(uint256 aAmountToManage) public parameterizedTest
    {
        // arrange
        IAaveProtocolDataProvider lDataProvider = _manager.dataProvider();
        (address lAaveToken, , ) = lDataProvider.getReserveTokensAddresses(_pair.token0());
        (uint256 lReserve0, , ) = _pair.getReserves();
        int256 lAmountToManage = int256(bound(aAmountToManage, 0, lReserve0));
        _manager.adjustManagement(_pair, lAmountToManage, 0);

        // act
        uint256 lShares = _manager.shares(_pair, FTM_USDC);
        uint256 lTotalShares = _manager.totalShares(lAaveToken);

        // assert
        assertEq(lShares, lTotalShares);
        assertEq(lShares, uint256(lAmountToManage));
        assertEq(lTotalShares, uint256(lAmountToManage));
    }

    function testCallback_IncreaseInvestmentAfterMint() public parameterizedTest
    {
        // sanity
        uint256 lAmountManaged = _manager.getBalance(_pair, FTM_USDC);
        assertEq(lAmountManaged, 0);

        // act
        _tokenA.mint(address(_pair), 500e6);
        deal(FTM_USDC, address(this), 500e6, true);
        IERC20(FTM_USDC).transfer(address(_pair), 500e6);
        _pair.mint(address(this));

        // assert
        uint256 lNewAmount = _manager.getBalance(_pair, FTM_USDC);
        (uint256 lReserve0, , ) = _pair.getReserves();
        assertEq(lNewAmount, lReserve0 * (_manager.lowerThreshold() + _manager.upperThreshold()) / 2 / 100);
    }

    function testCallback_DecreaseInvestmentAfterBurn(uint256 aInitialAmount) public parameterizedTest
    {
        // arrange
        (uint256 lReserve0, , ) = _pair.getReserves();
        uint256 lInitialAmount = bound(aInitialAmount, lReserve0 * (_manager.upperThreshold() + 2) / 100, lReserve0);
        _manager.adjustManagement(_pair, int256(lInitialAmount), 0);

        // act
        vm.prank(_alice);
        _pair.transfer(address(_pair), 100e6);
        _pair.burn(address(this));

        // assert
        uint256 lNewAmount = _manager.getBalance(_pair, FTM_USDC);
        (uint256 lReserve0After, , ) = _pair.getReserves();
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
