pragma solidity 0.8.13;

import "test/__fixtures/BaseTest.sol";

import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";

import { IAaveProtocolDataProvider } from "src/interfaces/aave/IAaveProtocolDataProvider.sol";
import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";

import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { MathUtils } from "src/libraries/MathUtils.sol";
import { AaveManager } from "src/asset-management/AaveManager.sol";
import { GenericFactory } from "src/GenericFactory.sol";

struct Network {
    string rpcUrl;
    address USDC;
}

struct Fork {
    bool created;
    uint256 forkId;
}

contract AaveIntegrationTest is BaseTest
{
    using FactoryStoreLib for GenericFactory;

    // this amount is tailored to USDC as it only has 6 decimal places
    // using the usual 100e18 would be too large and would break AAVE
    uint256 public constant MINT_AMOUNT = 1_000_000e6;

    // this address is the same across all chains
    address public constant AAVE_POOL_ADDRESS_PROVIDER = address(0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb);

    AaveManager private _manager;

    IAssetManagedPair[] internal _pairs;
    IAssetManagedPair   internal _pair;

    Network[] private _networks;
    mapping(string => Fork) private _forks;
    address private USDC;

    modifier allPairs {
        for (uint256 i = 0; i < _pairs.length; ++i) {
            uint256 lBefore = vm.snapshot();
            _pair = _pairs[i];
            _;
            vm.revertTo(lBefore);
        }
    }

    modifier allNetworks {
        for (uint256 i = 0; i < _networks.length; ++i) {
            uint256 lBefore = vm.snapshot();
            Network memory lNetwork = _networks[i];
            _setupRPC(lNetwork);
            _;
            vm.revertTo(lBefore);
        }
    }

    function _setupRPC(Network memory aNetwork) private {
        Fork memory lFork = _forks[aNetwork.rpcUrl];

        if (lFork.created == false) {
            uint256 lForkId = vm.createFork(aNetwork.rpcUrl);

            lFork = Fork(true, lForkId);
            _forks[aNetwork.rpcUrl] = lFork;
        }
        vm.selectFork(lFork.forkId);

        _factory = new GenericFactory();
        _factory.set(keccak256("CP::swapFee"), bytes32(uint256(DEFAULT_SWAP_FEE_CP)));
        _factory.set(keccak256("SP::swapFee"), bytes32(uint256(DEFAULT_SWAP_FEE_SP)));
        _factory.set(keccak256("Shared::platformFee"), bytes32(uint256(DEFAULT_PLATFORM_FEE)));
        _factory.addCurve(type(ConstantProductPair).creationCode);
        _factory.addCurve(type(StablePair).creationCode);
        _factory.set(keccak256("SP::amplificationCoefficient"), bytes32(uint256(1000)));

        _manager = new AaveManager(AAVE_POOL_ADDRESS_PROVIDER);
        USDC = aNetwork.USDC;
        deal(USDC, address(this), MINT_AMOUNT, true);
        _constantProductPair = ConstantProductPair(_createPair(address(_tokenA), USDC, 0));
        IERC20(USDC).transfer(address(_constantProductPair), MINT_AMOUNT);
        _tokenA.mint(address(_constantProductPair), MINT_AMOUNT);
        _constantProductPair.mint(_alice);
        vm.prank(address(_factory));
        _constantProductPair.setManager(_manager);

        deal(USDC, address(this), MINT_AMOUNT, true);
        _stablePair = StablePair(_createPair(address(_tokenA), USDC, 1));
        IERC20(USDC).transfer(address(_stablePair), MINT_AMOUNT);
        _tokenA.mint(address(_stablePair), 1_000_000e18);
        _stablePair.mint(_alice);
        vm.prank(address(_factory));
        _stablePair.setManager(_manager);

        _pairs.push(_constantProductPair);
        _pairs.push(_stablePair);
    }

    function setUp() external
    {
        _networks.push(
            Network(vm.rpcUrl("avalanche"), 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E)
        );
        _networks.push(
            Network(vm.rpcUrl("polygon"), 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174)
        );

        vm.makePersistent(address(_tokenA));
        vm.makePersistent(address(_tokenB));
    }

    function _createOtherPair() private returns (ConstantProductPair rOtherPair)
    {
        rOtherPair = ConstantProductPair(_createPair(address(_tokenB), USDC, 0));
        _tokenB.mint(address(rOtherPair), MINT_AMOUNT);
        deal(USDC, address(rOtherPair), MINT_AMOUNT, true);
        rOtherPair.mint(_alice);
        vm.prank(address(_factory));
        rOtherPair.setManager(_manager);
    }

    function testAdjustManagement_NoMarket(uint256 aAmountToManage) public allNetworks allPairs
    {
        // assume - we want negative numbers too
        int256 lAmountToManage = int256(bound(aAmountToManage, 0, type(uint256).max));

        // act
        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? int256(0) : lAmountToManage,
            _pair.token1() == USDC ? int256(0) : lAmountToManage
        );

        // assert
        assertEq(_manager.getBalance(_pair, USDC), 0);
        assertEq(_manager.getBalance(_pair, address(_tokenA)), 0);
    }

    function _increaseManagementOneToken() private
    {
        // arrange
        int256 lAmountToManage = 500e6;
        int256 lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int256(0);

        // act
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // assert
        IAaveProtocolDataProvider lDataProvider = _manager.dataProvider();
        (address lAaveToken, , ) = lDataProvider.getReserveTokensAddresses(USDC);

        assertEq(_pair.token0Managed(), uint256(lAmountToManage0));
        assertEq(_pair.token1Managed(), uint256(lAmountToManage1));
        assertEq(IERC20(USDC).balanceOf(address(_pair)), MINT_AMOUNT - uint256(lAmountToManage));
        assertEq(IERC20(lAaveToken).balanceOf(address(_manager)), uint256(lAmountToManage));
        assertEq(_manager.shares(_pair, USDC), uint256(lAmountToManage));
        assertEq(_manager.totalShares(lAaveToken), uint256(lAmountToManage));
    }

    function testAdjustManagement_IncreaseManagementOneToken() public allNetworks allPairs
    {
        _increaseManagementOneToken();
    }

    function testAdjustManagement_DecreaseManagementOneToken() public allNetworks allPairs
    {
        // arrange
        int256 lAmountToManage = -500e6;
        int256 lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int256(0);
        _increaseManagementOneToken();

        // act
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // assert
        IAaveProtocolDataProvider lDataProvider = _manager.dataProvider();
        (address lAaveToken, , ) = lDataProvider.getReserveTokensAddresses(USDC);

        assertEq(_pair.token0Managed(), 0);
        assertEq(_pair.token1Managed(), 0);
        assertEq(IERC20(USDC).balanceOf(address(_pair)), MINT_AMOUNT);
        assertEq(IERC20(lAaveToken).balanceOf(address(this)), 0);
        assertEq(_manager.shares(_pair, address(USDC)), 0);
        assertEq(_manager.totalShares(lAaveToken), 0);
    }

    function testAdjustManagement_DecreaseManagementBeyondShare() public allNetworks allPairs
    {
        // arrange
        ConstantProductPair lOtherPair = _createOtherPair();
        int256 lAmountToManage = 500e6;
        int256 lAmountToManage0Pair = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1Pair = _pair.token1() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage0Other = lOtherPair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1Other = lOtherPair.token1() == USDC ? lAmountToManage : int256(0);

        _manager.adjustManagement(_pair, lAmountToManage0Pair, lAmountToManage1Pair);
        _manager.adjustManagement(lOtherPair, lAmountToManage0Other, lAmountToManage1Other);

        // act & assert
        vm.expectRevert(stdError.arithmeticError);
        _manager.adjustManagement(lOtherPair, -lAmountToManage-1, 0);
    }

    function testGetBalance(uint256 aAmountToManage) public allNetworks allPairs
    {
        // assume
        (uint256 lReserve0, uint256 lReserve1, ) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        int256 lAmountToManage = int256(bound(aAmountToManage, 0, lReserveUSDC));

        // arrange
        int256 lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int256(0);
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // act
        uint112 lBalance = _manager.getBalance(_pair, USDC);

        // assert
        assertTrue(MathUtils.within1(lBalance, uint256(lAmountToManage)));
    }

    function testGetBalance_NoShares(uint256 aToken) public allNetworks allPairs
    {
        // assume
        address lToken = address(uint160(aToken));
        vm.assume(lToken != USDC);

        // arrange
        int256 lAmountToManage = 500e6;
        int256 lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int256(0);
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // act
        uint256 lRes = _manager.getBalance(_pair, lToken);

        // assert
        assertEq(lRes, 0);
    }

    function testGetBalance_TwoPairsInSameMarket(uint256 aAmountToManage1, uint256 aAmountToManage2) public allNetworks allPairs
    {
        // assume
        ConstantProductPair lOtherPair = _createOtherPair();
        (uint256 lReserve0, uint256 lReserve1, ) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        int256 lAmountToManagePair = int256(bound(aAmountToManage1, 1, lReserveUSDC));
        int256 lAmountToManageOther = int256(bound(aAmountToManage2, 1, lReserveUSDC));

        // arrange
        int256 lAmountToManage0Pair = _pair.token0() == USDC ? lAmountToManagePair : int256(0);
        int256 lAmountToManage1Pair = _pair.token1() == USDC ? lAmountToManagePair : int256(0);
        int256 lAmountToManage0Other = lOtherPair.token0() == USDC ? lAmountToManageOther : int256(0);
        int256 lAmountToManage1Other = lOtherPair.token1() == USDC ? lAmountToManageOther : int256(0);

        // act
        _manager.adjustManagement(_pair, lAmountToManage0Pair, lAmountToManage1Pair);
        _manager.adjustManagement(lOtherPair, lAmountToManage0Other, lAmountToManage1Other);

        // assert
        assertTrue(MathUtils.within1(_manager.getBalance(_pair, USDC), uint256(lAmountToManagePair)));
        assertTrue(MathUtils.within1(_manager.getBalance(lOtherPair, USDC), uint256(lAmountToManageOther)));
    }

    function testGetBalance_AddingAfterExchangeRateChange(
        uint256 aAmountToManage1,
        uint256 aAmountToManage2,
        uint256 aTime
    ) public allNetworks allPairs
    {
        // assume
        ConstantProductPair lOtherPair = _createOtherPair();
        (address lAaveToken, , ) = _manager.dataProvider().getReserveTokensAddresses(USDC);
        (uint256 lReserve0, uint256 lReserve1, ) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        int256 lAmountToManagePair = int256(bound(aAmountToManage1, 1, lReserveUSDC));
        int256 lAmountToManageOther = int256(bound(aAmountToManage2, 1, lReserveUSDC));
        uint256 lTime = bound(aTime, 1, 52 weeks);

        // arrange
        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? lAmountToManagePair : int256(0),
            _pair.token1() == USDC ? lAmountToManagePair : int256(0)
        );

        // act
        skip(lTime);
        uint256 lAaveTokenAmt2 = IERC20(lAaveToken).balanceOf(address(_manager));
        _manager.adjustManagement(
            lOtherPair,
            lOtherPair.token0() == USDC ? lAmountToManageOther : int256(0),
            lOtherPair.token1() == USDC ? lAmountToManageOther : int256(0)
        );

        // assert
        assertEq(_manager.shares(_pair, USDC), uint256(lAmountToManagePair));
        assertTrue(MathUtils.within1(_manager.getBalance(_pair, USDC), lAaveTokenAmt2));

        uint256 lExpectedShares
            = uint256(lAmountToManageOther) * 1e18
            / (lAaveTokenAmt2 * 1e18 / uint256(lAmountToManagePair));
        assertEq(_manager.shares(lOtherPair, USDC), lExpectedShares);
        uint256 lBalance = _manager.getBalance(lOtherPair, USDC);
        assertTrue(MathUtils.within1(lBalance, uint256(lAmountToManageOther)));
    }

    function testShares(uint256 aAmountToManage) public allNetworks allPairs
    {
        // assume
        (uint256 lReserve0, uint256 lReserve1, ) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        int256 lAmountToManage = int256(bound(aAmountToManage, 0, lReserveUSDC));

        // arrange
        IAaveProtocolDataProvider lDataProvider = _manager.dataProvider();
        (address lAaveToken, , ) = lDataProvider.getReserveTokensAddresses(USDC);
        int256 lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int256(0);

        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // act
        uint256 lShares = _manager.shares(_pair, USDC);
        uint256 lTotalShares = _manager.totalShares(lAaveToken);

        // assert
        assertEq(lShares, lTotalShares);
        assertEq(lShares, uint256(lAmountToManage));
        assertEq(lTotalShares, uint256(lAmountToManage));
    }

    function testCallback_IncreaseInvestmentAfterMint() public allNetworks allPairs
    {
        // sanity
        uint256 lAmountManaged = _manager.getBalance(_pair, USDC);
        assertEq(lAmountManaged, 0);

        // act
        _tokenA.mint(address(_pair), 500e6);
        deal(USDC, address(this), 500e6, true);
        IERC20(USDC).transfer(address(_pair), 500e6);
        _pair.mint(address(this));

        // assert
        uint256 lNewAmount = _manager.getBalance(_pair, USDC);
        (uint256 lReserve0, uint256 lReserve1, ) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        assertEq(lNewAmount, lReserveUSDC * (_manager.lowerThreshold() + _manager.upperThreshold()) / 2 / 100);
    }

    function testCallback_DecreaseInvestmentAfterBurn(uint256 aInitialAmount) public allNetworks allPairs
    {
        // assume
        (uint256 lReserve0, uint256 lReserve1, ) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        uint256 lInitialAmount = bound(aInitialAmount, lReserveUSDC * (_manager.upperThreshold() + 2) / 100, lReserveUSDC);

        // arrange
        _manager.adjustManagement(_pair, 0, int256(lInitialAmount));

        // act
        vm.prank(_alice);
        _pair.transfer(address(_pair), 100e6);
        _pair.burn(address(this));

        // assert
        uint256 lNewAmount = _manager.getBalance(_pair, USDC);
        (uint256 lReserve0After, uint256 lReserve1After, ) = _pair.getReserves();
        uint256 lReserveUSDCAfter = _pair.token0() == USDC ? lReserve0After : lReserve1After;
        assertTrue(MathUtils.within1(lNewAmount, lReserveUSDCAfter * (_manager.lowerThreshold() + _manager.upperThreshold()) / 2 / 100));
    }

    function testCallback_ShouldFailIfNotPair() public allNetworks
    {
        // act & assert
        vm.expectRevert();
        _manager.afterLiquidityEvent();

        // act & assert
        vm.prank(_alice);
        vm.expectRevert();
        _manager.afterLiquidityEvent();
    }

    function testSetUpperThreshold_BreachMaximum() public allNetworks
    {
        // act & assert
        vm.expectRevert("AM: INVALID_THRESHOLD");
        _manager.setUpperThreshold(101);
    }

    function testSetUpperThreshold_LessThanEqualLowerThreshold(uint256 aThreshold) public allNetworks
    {
        // assume
        uint256 lThreshold = bound(aThreshold, 0, _manager.lowerThreshold());

        // act & assert
        vm.expectRevert("AM: INVALID_THRESHOLD");
        _manager.setUpperThreshold(lThreshold);
    }

    function testSetLowerThreshold_MoreThanEqualUpperThreshold(uint256 aThreshold) public allNetworks
    {
        // assume
        uint256 lThreshold = bound(aThreshold, _manager.upperThreshold(), type(uint256).max);

        // act & assert
        vm.expectRevert("AM: INVALID_THRESHOLD");
        _manager.setLowerThreshold(lThreshold);
    }
}
