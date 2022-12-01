pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";
import { Errors } from "test/integration/AaveErrors.sol";

import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";

import { IAaveProtocolDataProvider } from "src/interfaces/aave/IAaveProtocolDataProvider.sol";
import { IPoolAddressesProvider } from "src/interfaces/aave/IPoolAddressesProvider.sol";
import { IPoolConfigurator } from "src/interfaces/aave/IPoolConfigurator.sol";
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
    uint forkId;
}

contract AaveIntegrationTest is BaseTest {
    using FactoryStoreLib for GenericFactory;

    // this amount is tailored to USDC as it only has 6 decimal places
    // using the usual 100e18 would be too large and would break AAVE
    uint public constant MINT_AMOUNT = 1_000_000e6;

    // this address is the same across all chains
    address public constant AAVE_POOL_ADDRESS_PROVIDER = address(0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb);

    AaveManager private _manager;

    IAssetManagedPair[] internal _pairs;
    IAssetManagedPair internal _pair;

    Network[] private _networks;
    mapping(string => Fork) private _forks;
    // network specific variables
    address private USDC;
    address private _aaveAdmin;
    IPoolAddressesProvider private _poolAddressesProvider;
    IAaveProtocolDataProvider private _dataProvider;
    IPoolConfigurator private _poolConfigurator;

    modifier allPairs() {
        for (uint i = 0; i < _pairs.length; ++i) {
            uint lBefore = vm.snapshot();
            _pair = _pairs[i];
            _;
            vm.revertTo(lBefore);
        }
    }

    modifier allNetworks() {
        for (uint i = 0; i < _networks.length; ++i) {
            uint lBefore = vm.snapshot();
            Network memory lNetwork = _networks[i];
            _setupRPC(lNetwork);
            _;
            vm.revertTo(lBefore);
        }
    }

    function _setupRPC(Network memory aNetwork) private {
        Fork memory lFork = _forks[aNetwork.rpcUrl];

        if (lFork.created == false) {
            uint lForkId = vm.createFork(aNetwork.rpcUrl);

            lFork = Fork(true, lForkId);
            _forks[aNetwork.rpcUrl] = lFork;
        }
        vm.selectFork(lFork.forkId);

        _factory = new GenericFactory();
        _factory.write("CP::swapFee", DEFAULT_SWAP_FEE_CP);
        _factory.write("SP::swapFee", DEFAULT_SWAP_FEE_SP);
        _factory.write("Shared::platformFee", DEFAULT_PLATFORM_FEE);
        _factory.write("Shared::allowedChangePerSecond", DEFAULT_ALLOWED_CHANGE_PER_SECOND);
        _factory.addCurve(type(ConstantProductPair).creationCode);
        _factory.addCurve(type(StablePair).creationCode);
        _factory.write("SP::amplificationCoefficient", DEFAULT_AMP_COEFF);

        _manager = new AaveManager(AAVE_POOL_ADDRESS_PROVIDER);
        USDC = aNetwork.USDC;
        _poolAddressesProvider = IPoolAddressesProvider(AAVE_POOL_ADDRESS_PROVIDER);
        _aaveAdmin = _poolAddressesProvider.getACLAdmin();
        _dataProvider = IAaveProtocolDataProvider(_poolAddressesProvider.getPoolDataProvider());
        _poolConfigurator = IPoolConfigurator(_poolAddressesProvider.getPoolConfigurator());

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

    function setUp() external {
        _networks.push(Network(vm.rpcUrl("avalanche"), 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E));
        _networks.push(Network(vm.rpcUrl("polygon"), 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174));

        vm.makePersistent(address(_tokenA));
        vm.makePersistent(address(_tokenB));
    }

    function _createOtherPair() private returns (ConstantProductPair rOtherPair) {
        rOtherPair = ConstantProductPair(_createPair(address(_tokenB), USDC, 0));
        _tokenB.mint(address(rOtherPair), MINT_AMOUNT);
        deal(USDC, address(this), MINT_AMOUNT, true);
        IERC20(USDC).transfer(address(rOtherPair), MINT_AMOUNT);
        rOtherPair.mint(_alice);
        vm.prank(address(_factory));
        rOtherPair.setManager(_manager);
    }

    function testAdjustManagement_NoMarket(uint aAmountToManage) public allNetworks allPairs {
        // assume - we want negative numbers too
        int lAmountToManage = int(bound(aAmountToManage, 0, type(uint).max));

        // act
        _manager.adjustManagement(
            _pair, _pair.token0() == USDC ? int(0) : lAmountToManage, _pair.token1() == USDC ? int(0) : lAmountToManage
        );

        // assert
        assertEq(_manager.getBalance(_pair, USDC), 0);
        assertEq(_manager.getBalance(_pair, address(_tokenA)), 0);
    }

    function testAdjustManagement_NotOwner() public allNetworks allPairs {
        // act & assert
        vm.prank(_alice);
        vm.expectRevert("UNAUTHORIZED");
        _manager.adjustManagement(_pair, 1, 1);
    }

    function _increaseManagementOneToken(int aAmountToManage) private {
        // arrange
        int lAmountToManage0 = _pair.token0() == USDC ? aAmountToManage : int(0);
        int lAmountToManage1 = _pair.token1() == USDC ? aAmountToManage : int(0);

        // act
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);
    }

    function testAdjustManagement_IncreaseManagementOneToken() public allNetworks allPairs {
        // arrange
        int lAmountToManage = 500e6;
        int lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int(0);
        int lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int(0);

        // act
        _increaseManagementOneToken(lAmountToManage);

        // assert
        (address lAaveToken,,) = _dataProvider.getReserveTokensAddresses(USDC);
        assertEq(_pair.token0Managed(), uint(lAmountToManage0));
        assertEq(_pair.token1Managed(), uint(lAmountToManage1));
        assertEq(IERC20(USDC).balanceOf(address(_pair)), MINT_AMOUNT - uint(lAmountToManage));
        assertEq(IERC20(lAaveToken).balanceOf(address(_manager)), uint(lAmountToManage));
        assertEq(_manager.shares(_pair, USDC), uint(lAmountToManage));
        assertEq(_manager.totalShares(lAaveToken), uint(lAmountToManage));
    }

    function testAdjustManagement_IncreaseManagementOneToken_Frozen() public allNetworks allPairs {
        // arrange - freeze the USDC market
        int lAmountToManage = 500e6;
        vm.prank(_aaveAdmin);
        _poolConfigurator.setReserveFreeze(USDC, true);
        int lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int(0);
        int lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int(0);

        // act
        vm.expectRevert(bytes(Errors.RESERVE_FROZEN));
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // assert - nothing should have moved as USDC market is frozen
        (address lAaveToken,,) = _dataProvider.getReserveTokensAddresses(USDC);
        assertEq(_pair.token0Managed(), 0);
        assertEq(_pair.token1Managed(), 0);
        assertEq(IERC20(USDC).balanceOf(address(_pair)), MINT_AMOUNT);
        assertEq(IERC20(lAaveToken).balanceOf(address(_manager)), 0);
        assertEq(_manager.shares(_pair, USDC), 0);
        assertEq(_manager.totalShares(lAaveToken), 0);
    }

    function testAdjustManagement_IncreaseManagementOneToken_Paused() public allNetworks allPairs {
        // arrange - freeze the USDC market
        int lAmountToManage = 500e6;
        vm.prank(_aaveAdmin);
        _poolConfigurator.setReservePause(USDC, true);
        int lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int(0);
        int lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int(0);

        // act
        vm.expectRevert(bytes(Errors.RESERVE_PAUSED));
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // assert - nothing should have moved as USDC market is paused
        (address lAaveToken,,) = _dataProvider.getReserveTokensAddresses(USDC);
        assertEq(_pair.token0Managed(), 0);
        assertEq(_pair.token1Managed(), 0);
        assertEq(IERC20(USDC).balanceOf(address(_pair)), MINT_AMOUNT);
        assertEq(IERC20(lAaveToken).balanceOf(address(_manager)), 0);
        assertEq(_manager.shares(_pair, USDC), 0);
        assertEq(_manager.totalShares(lAaveToken), 0);
    }

    function testAdjustManagement_DecreaseManagementOneToken() public allNetworks allPairs {
        // arrange
        int lAmountToManage = -500e6;
        int lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int(0);
        int lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int(0);
        _increaseManagementOneToken(500e6);

        // act
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // assert
        (address lAaveToken,,) = _dataProvider.getReserveTokensAddresses(USDC);

        assertEq(_pair.token0Managed(), 0);
        assertEq(_pair.token1Managed(), 0);
        assertEq(IERC20(USDC).balanceOf(address(_pair)), MINT_AMOUNT);
        assertEq(IERC20(lAaveToken).balanceOf(address(_manager)), 0);
        assertEq(_manager.shares(_pair, address(USDC)), 0);
        assertEq(_manager.totalShares(lAaveToken), 0);
    }

    function testAdjustManagement_DecreaseManagementBeyondShare() public allNetworks allPairs {
        // arrange
        ConstantProductPair lOtherPair = _createOtherPair();
        int lAmountToManage = 500e6;
        int lAmountToManage0Pair = _pair.token0() == USDC ? lAmountToManage : int(0);
        int lAmountToManage1Pair = _pair.token1() == USDC ? lAmountToManage : int(0);
        int lAmountToManage0Other = lOtherPair.token0() == USDC ? lAmountToManage : int(0);
        int lAmountToManage1Other = lOtherPair.token1() == USDC ? lAmountToManage : int(0);

        _manager.adjustManagement(_pair, lAmountToManage0Pair, lAmountToManage1Pair);
        _manager.adjustManagement(lOtherPair, lAmountToManage0Other, lAmountToManage1Other);

        // act & assert
        vm.expectRevert(stdError.arithmeticError);
        _manager.adjustManagement(lOtherPair, -lAmountToManage - 1, 0);
    }

    function testAdjustManagement_DecreaseManagement_ReservePaused() public allNetworks allPairs {
        // arrange
        int lAmountToManage = -500e6;
        int lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int(0);
        int lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int(0);
        _increaseManagementOneToken(500e6);

        vm.prank(_aaveAdmin);
        _poolConfigurator.setReservePause(USDC, true);

        // act - withdraw should fail when reserve is paused
        vm.expectRevert(bytes(Errors.RESERVE_PAUSED));
        _manager.adjustManagement(_pair, -lAmountToManage0, -lAmountToManage1);

        // assert
        (address lAaveToken,,) = _dataProvider.getReserveTokensAddresses(USDC);
        uint lUsdcManaged = _pair.token0() == USDC ? _pair.token0Managed() : _pair.token1Managed();
        assertEq(lUsdcManaged, 500e6);
        assertEq(IERC20(USDC).balanceOf(address(_pair)), MINT_AMOUNT - 500e6);
        assertEq(IERC20(lAaveToken).balanceOf(address(_manager)), 500e6);
        assertEq(_manager.shares(_pair, address(USDC)), 500e6);
        assertEq(_manager.totalShares(lAaveToken), 500e6);
    }

    function testAdjustManagement_DecreaseManagement_SucceedEvenWhenFrozen() public allNetworks allPairs {
        // arrange
        int lAmountToManage = -500e6;
        int lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int(0);
        int lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int(0);
        _increaseManagementOneToken(500e6);

        vm.prank(_aaveAdmin);
        _poolConfigurator.setReserveFreeze(USDC, true);

        // act - withdraw should still succeed when reserve is frozen
        vm.expectCall(address(_pair), abi.encodeCall(_pair.adjustManagement, (lAmountToManage0, lAmountToManage1)));
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // assert
        (address lAaveToken,,) = _dataProvider.getReserveTokensAddresses(USDC);
        assertEq(_pair.token0Managed(), 0);
        assertEq(_pair.token1Managed(), 0);
        assertEq(IERC20(USDC).balanceOf(address(_pair)), MINT_AMOUNT);
        assertEq(IERC20(lAaveToken).balanceOf(address(_manager)), 0);
        assertEq(_manager.shares(_pair, address(USDC)), 0);
        assertEq(_manager.totalShares(lAaveToken), 0);
    }

    function testGetBalance(uint aAmountToManage) public allNetworks allPairs {
        // assume
        (uint lReserve0, uint lReserve1,) = _pair.getReserves();
        uint lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        int lAmountToManage = int(bound(aAmountToManage, 0, lReserveUSDC));

        // arrange
        int lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int(0);
        int lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int(0);
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // act
        uint112 lBalance = _manager.getBalance(_pair, USDC);

        // assert
        assertTrue(MathUtils.within1(lBalance, uint(lAmountToManage)));
    }

    function testGetBalance_NoShares(uint aToken) public allNetworks allPairs {
        // assume
        address lToken = address(uint160(aToken));
        vm.assume(lToken != USDC);

        // arrange
        int lAmountToManage = 500e6;
        int lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int(0);
        int lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int(0);
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // act
        uint lRes = _manager.getBalance(_pair, lToken);

        // assert
        assertEq(lRes, 0);
    }

    function testGetBalance_TwoPairsInSameMarket(uint aAmountToManage1, uint aAmountToManage2)
        public
        allNetworks
        allPairs
    {
        // assume
        ConstantProductPair lOtherPair = _createOtherPair();
        (uint lReserve0, uint lReserve1,) = _pair.getReserves();
        uint lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        int lAmountToManagePair = int(bound(aAmountToManage1, 1, lReserveUSDC));
        int lAmountToManageOther = int(bound(aAmountToManage2, 1, lReserveUSDC));

        // arrange
        int lAmountToManage0Pair = _pair.token0() == USDC ? lAmountToManagePair : int(0);
        int lAmountToManage1Pair = _pair.token1() == USDC ? lAmountToManagePair : int(0);
        int lAmountToManage0Other = lOtherPair.token0() == USDC ? lAmountToManageOther : int(0);
        int lAmountToManage1Other = lOtherPair.token1() == USDC ? lAmountToManageOther : int(0);

        // act
        _manager.adjustManagement(_pair, lAmountToManage0Pair, lAmountToManage1Pair);
        _manager.adjustManagement(lOtherPair, lAmountToManage0Other, lAmountToManage1Other);

        // assert
        assertTrue(MathUtils.within1(_manager.getBalance(_pair, USDC), uint(lAmountToManagePair)));
        assertTrue(MathUtils.within1(_manager.getBalance(lOtherPair, USDC), uint(lAmountToManageOther)));
    }

    function testGetBalance_AddingAfterProfit(uint aAmountToManage1, uint aAmountToManage2, uint aTime)
        public
        allNetworks
        allPairs
    {
        // assume
        ConstantProductPair lOtherPair = _createOtherPair();
        (address lAaveToken,,) = _dataProvider.getReserveTokensAddresses(USDC);
        (uint lReserve0, uint lReserve1,) = _pair.getReserves();
        uint lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        int lAmountToManagePair = int(bound(aAmountToManage1, 1, lReserveUSDC));
        int lAmountToManageOther = int(bound(aAmountToManage2, 1, lReserveUSDC));
        uint lTime = bound(aTime, 1, 52 weeks);

        // arrange
        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? lAmountToManagePair : int(0),
            _pair.token1() == USDC ? lAmountToManagePair : int(0)
        );

        // act
        skip(lTime);
        uint lAaveTokenAmt2 = IERC20(lAaveToken).balanceOf(address(_manager));
        _manager.adjustManagement(
            lOtherPair,
            lOtherPair.token0() == USDC ? lAmountToManageOther : int(0),
            lOtherPair.token1() == USDC ? lAmountToManageOther : int(0)
        );

        // assert
        assertEq(_manager.shares(_pair, USDC), uint(lAmountToManagePair));
        assertTrue(MathUtils.within1(_manager.getBalance(_pair, USDC), lAaveTokenAmt2));

        uint lExpectedShares = uint(lAmountToManageOther) * 1e18 / (lAaveTokenAmt2 * 1e18 / uint(lAmountToManagePair));
        assertEq(_manager.shares(lOtherPair, USDC), lExpectedShares);
        uint lBalance = _manager.getBalance(lOtherPair, USDC);
        assertTrue(MathUtils.within1(lBalance, uint(lAmountToManageOther)));
    }

    function testShares(uint aAmountToManage) public allNetworks allPairs {
        // assume
        (uint lReserve0, uint lReserve1,) = _pair.getReserves();
        uint lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        int lAmountToManage = int(bound(aAmountToManage, 0, lReserveUSDC));

        // arrange
        (address lAaveToken,,) = _dataProvider.getReserveTokensAddresses(USDC);
        int lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int(0);
        int lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int(0);

        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // act
        uint lShares = _manager.shares(_pair, USDC);
        uint lTotalShares = _manager.totalShares(lAaveToken);

        // assert
        assertEq(lShares, lTotalShares);
        assertEq(lShares, uint(lAmountToManage));
    }

    function testShares_AdjustManagementAfterProfit(uint aAmountToManage1, uint aAmountToManage2)
        public
        allNetworks
        allPairs
    {
        // assume
        (uint lReserve0, uint lReserve1,) = _pair.getReserves();
        uint lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        int lAmountToManage1 = int(bound(aAmountToManage1, 100, lReserveUSDC / 2));
        int lAmountToManage2 = int(bound(aAmountToManage2, 100, lReserveUSDC / 2));

        // arrange
        (address lAaveToken,,) = _dataProvider.getReserveTokensAddresses(USDC);
        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? lAmountToManage1 : int(0),
            _pair.token1() == USDC ? lAmountToManage1 : int(0)
        );

        // act - go forward in time to simulate accrual of profits
        skip(30 days);
        uint lAaveTokenAmt1 = IERC20(lAaveToken).balanceOf(address(_manager));
        assertGt(lAaveTokenAmt1, uint(lAmountToManage1));
        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? lAmountToManage2 : int(0),
            _pair.token1() == USDC ? lAmountToManage2 : int(0)
        );

        // assert
        uint lShares = _manager.shares(_pair, USDC);
        uint lTotalShares = _manager.totalShares(lAaveToken);
        assertEq(lShares, lTotalShares);
        assertLt(lTotalShares, uint(lAmountToManage1 + lAmountToManage2));

        uint lBalance = _manager.getBalance(_pair, USDC);
        uint lAaveTokenAmt2 = IERC20(lAaveToken).balanceOf(address(_manager));
        assertEq(lBalance, lAaveTokenAmt2);

        // pair not yet informed of the profits, so the numbers are less than what it actually has
        uint lUSDCManaged = _pair.token0() == USDC ? _pair.token0Managed() : _pair.token1Managed();
        assertLt(lUSDCManaged, lBalance);

        // after a sync, the pair should have the correct amount
        _pair.sync();
        uint lUSDCManagedAfterSync = _pair.token0() == USDC ? _pair.token0Managed() : _pair.token1Managed();
        assertEq(lUSDCManagedAfterSync, lBalance);
    }

    function testAfterLiquidityEvent_IncreaseInvestmentAfterMint() public allNetworks allPairs {
        // sanity
        uint lAmountManaged = _manager.getBalance(_pair, USDC);
        assertEq(lAmountManaged, 0);

        // act
        _tokenA.mint(address(_pair), 500e6);
        deal(USDC, address(this), 500e6, true);
        IERC20(USDC).transfer(address(_pair), 500e6);
        _pair.mint(address(this));

        // assert
        uint lNewAmount = _manager.getBalance(_pair, USDC);
        (uint lReserve0, uint lReserve1,) = _pair.getReserves();
        uint lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        assertEq(lNewAmount, lReserveUSDC * (_manager.lowerThreshold() + _manager.upperThreshold()) / 2 / 100);
    }

    function testAfterLiquidityEvent_DecreaseInvestmentAfterBurn(uint aInitialAmount) public allNetworks allPairs {
        // assume
        (uint lReserve0, uint lReserve1,) = _pair.getReserves();
        uint lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        uint lInitialAmount = bound(aInitialAmount, lReserveUSDC * (_manager.upperThreshold() + 2) / 100, lReserveUSDC);

        // arrange
        _manager.adjustManagement(_pair, 0, int(lInitialAmount));

        // act
        vm.prank(_alice);
        _pair.transfer(address(_pair), 100e6);
        _pair.burn(address(this));

        // assert
        uint lNewAmount = _manager.getBalance(_pair, USDC);
        (uint lReserve0After, uint lReserve1After,) = _pair.getReserves();
        uint lReserveUSDCAfter = _pair.token0() == USDC ? lReserve0After : lReserve1After;
        assertTrue(
            MathUtils.within1(
                lNewAmount, lReserveUSDCAfter * (_manager.lowerThreshold() + _manager.upperThreshold()) / 2 / 100
            )
        );
    }

    // Not enough assets being managed, the AM would want to put some assets into AAVE
    // but that fails because AAVE is frozen. But the mint should still succeed
    function testAfterLiquidityEvent_Mint_SucceedEvenIfFrozen() public allNetworks allPairs {
        // arrange
        uint lMintAmt = 100e6;
        vm.prank(_aaveAdmin);
        _poolConfigurator.setReserveFreeze(USDC, true);

        // act
        deal(USDC, address(this), lMintAmt, true);
        IERC20(USDC).transfer(address(_pair), lMintAmt);
        _tokenA.mint(address(_pair), lMintAmt);
        _pair.mint(address(this));

        // assert - mint succeeds but no assets should have been moved
        (address lAaveToken,,) = _dataProvider.getReserveTokensAddresses(USDC);
        assertGt(_pair.balanceOf(address(this)), 0);
        assertEq(_pair.token0Managed(), 0);
        assertEq(_pair.token1Managed(), 0);
        assertEq(IERC20(lAaveToken).balanceOf(address(_manager)), 0);
        assertEq(_manager.shares(_pair, USDC), 0);
        assertEq(IERC20(USDC).balanceOf(address(_pair)), MINT_AMOUNT + lMintAmt);
    }

    function testAfterLiquidityEvent_Mint_SucceedEvenIfPaused() public allNetworks allPairs {
        // arrange
        uint lMintAmt = 100e6;
        vm.prank(_aaveAdmin);
        _poolConfigurator.setReservePause(USDC, true);

        // act
        deal(USDC, address(this), lMintAmt, true);
        IERC20(USDC).transfer(address(_pair), lMintAmt);
        _tokenA.mint(address(_pair), lMintAmt);
        _pair.mint(address(this));

        // assert
        (address lAaveToken,,) = _dataProvider.getReserveTokensAddresses(USDC);
        assertGt(_pair.balanceOf(address(this)), 0);
        assertEq(_pair.token0Managed(), 0);
        assertEq(_pair.token1Managed(), 0);
        assertEq(IERC20(lAaveToken).balanceOf(address(_manager)), 0);
        assertEq(_manager.shares(_pair, USDC), 0);
        assertEq(IERC20(USDC).balanceOf(address(_pair)), MINT_AMOUNT + lMintAmt);
    }

    function testAfterLiquidityEvent_Burn_SucceedEvenIfFrozen() public allNetworks allPairs {
        // arrange
        uint lAmtToBurn = _pair.balanceOf(_alice) / 2;
        vm.prank(_aaveAdmin);
        _poolConfigurator.setReserveFreeze(USDC, true);

        // act
        vm.prank(_alice);
        _pair.transfer(address(_pair), lAmtToBurn);
        _pair.burn(address(this));

        // assert - burn succeeds but no assets should have been moved
        (address lAaveToken,,) = _dataProvider.getReserveTokensAddresses(USDC);
        (uint lReserve0, uint lReserve1,) = _pair.getReserves();
        uint lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;

        assertGt(IERC20(USDC).balanceOf(address(this)), 0);
        assertGt(_tokenA.balanceOf(address(this)), 0);
        assertEq(lReserveUSDC, IERC20(USDC).balanceOf(address(_pair)));
        assertEq(_pair.token0Managed(), 0);
        assertEq(_pair.token1Managed(), 0);
        assertEq(_manager.shares(_pair, USDC), 0);
        assertEq(IERC20(lAaveToken).balanceOf(address(_manager)), 0);
    }

    function testAfterLiquidityEvent_Burn_SucceedEvenIfPaused() public allNetworks allPairs {
        // arrange
        uint lAmtToBurn = _pair.balanceOf(_alice) / 2;
        vm.prank(_aaveAdmin);
        _poolConfigurator.setReservePause(USDC, true);

        // act
        vm.prank(_alice);
        _pair.transfer(address(_pair), lAmtToBurn);
        _pair.burn(address(this));

        // assert
        (address lAaveToken,,) = _dataProvider.getReserveTokensAddresses(USDC);
        (uint lReserve0, uint lReserve1,) = _pair.getReserves();
        uint lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;

        assertGt(IERC20(USDC).balanceOf(address(this)), 0);
        assertGt(_tokenA.balanceOf(address(this)), 0);
        assertEq(lReserveUSDC, IERC20(USDC).balanceOf(address(_pair)));
        assertEq(_pair.token0Managed(), 0);
        assertEq(_pair.token1Managed(), 0);
        assertEq(_manager.shares(_pair, USDC), 0);
        assertEq(IERC20(lAaveToken).balanceOf(address(_manager)), 0);
    }

    // Having too much assets managed, the asset manager would want to
    // divest some and put it back into the pair. But if AAVE is paused,
    // the withdrawal from AAVE will fail but the burn should still succeed
    function testAfterLiquidityEvent_SucceedEvenIfWithdrawFailed() public allNetworks allPairs {
        // arrange
        uint lAmtToBurn = _pair.balanceOf(_alice) / 10;
        int lAmtToManage = int(MINT_AMOUNT * 8 / 10); // put 80% of USDC under management, above the upper threshold
        _increaseManagementOneToken(lAmtToManage);
        uint lUsdcManagedBefore = _pair.token0() == USDC ? _pair.token0Managed() : _pair.token1Managed();
        uint lSharesBefore = _manager.shares(_pair, USDC);
        (address lAaveToken,,) = _dataProvider.getReserveTokensAddresses(USDC);
        uint lAaveTokenBefore = IERC20(lAaveToken).balanceOf(address(_manager));

        vm.prank(_aaveAdmin);
        _poolConfigurator.setReservePause(USDC, true);

        // act
        vm.prank(_alice);
        _pair.transfer(address(_pair), lAmtToBurn);
        vm.expectCall(_poolAddressesProvider.getPool(), bytes(""));
        _pair.burn(address(this));

        // assert - burn succeeded but managed assets have not been moved
        uint lUsdcManagedAfter = _pair.token0() == USDC ? _pair.token0Managed() : _pair.token1Managed();
        assertEq(lUsdcManagedBefore, lUsdcManagedAfter);
        assertGt(IERC20(USDC).balanceOf(address(this)), 0);
        assertGt(_tokenA.balanceOf(address(this)), 0);
        assertEq(_manager.shares(_pair, USDC), lSharesBefore);
        assertEq(IERC20(lAaveToken).balanceOf(address(_manager)), lAaveTokenBefore);
    }

    function testAfterLiquidityEvent_ShouldFailIfNotPair() public allNetworks {
        // act & assert
        vm.expectRevert();
        _manager.afterLiquidityEvent();

        // act & assert
        vm.prank(_alice);
        vm.expectRevert();
        _manager.afterLiquidityEvent();
    }

    function testSwap_ReturnAsset() public allNetworks allPairs {
        // arrange
        (uint lReserve0, uint lReserve1,) = _pair.getReserves();
        (uint lReserveUSDC, uint lReserveTokenA) =
            _pair.token0() == USDC ? (lReserve0, lReserve1) : (lReserve1, lReserve0);
        // manage half
        _manager.adjustManagement(
            _pair,
            int(_pair.token0() == USDC ? lReserveUSDC / 2 : 0),
            int(_pair.token1() == USDC ? lReserveUSDC / 2 : 0)
        );

        // sanity
        assertEq(IERC20(USDC).balanceOf(address(_pair)), MINT_AMOUNT / 2);

        // act - request more than what is available in the pair
        int lOutputAmt = _pair.token0() == USDC ? int(MINT_AMOUNT / 2 + 10) : -int(MINT_AMOUNT / 2 + 10);
        (int lExpectedToken0Calldata, int lExpectedToken1Calldata) =
            _pair.token0() == USDC ? (int(-10), int(0)) : (int(0), int(-10));
        _tokenA.mint(address(_pair), lReserveTokenA * 2);
        vm.expectCall(address(_manager), abi.encodeCall(_manager.returnAsset, (_pair.token0() == USDC, 10)));
        vm.expectCall(
            address(_pair), abi.encodeCall(_pair.adjustManagement, (lExpectedToken0Calldata, lExpectedToken1Calldata))
        );
        _pair.swap(lOutputAmt, false, address(this), bytes(""));

        // assert
        (address lAaveToken,,) = _dataProvider.getReserveTokensAddresses(USDC);
        (lReserve0, lReserve1,) = _pair.getReserves();
        lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        assertEq(IERC20(USDC).balanceOf(address(this)), MINT_AMOUNT / 2 + 10);
        assertEq(IERC20(USDC).balanceOf(address(_pair)), 0);
        assertEq(lReserveUSDC, MINT_AMOUNT / 2 - 10);
        assertEq(_manager.shares(_pair, USDC), MINT_AMOUNT / 2 - 10);
        assertEq(_manager.totalShares(lAaveToken), MINT_AMOUNT / 2 - 10);
        assertApproxEqAbs(_manager.getBalance(_pair, USDC), MINT_AMOUNT / 2 - 10, 1);
    }

    // when the pool is paused, attempts to withdraw should fail and the swap should fail too
    function testSwap_ReturnAsset_PausedFail() public allNetworks allPairs {
        // arrange
        (uint lReserve0, uint lReserve1,) = _pair.getReserves();
        (uint lReserveUSDC, uint lReserveTokenA) =
            _pair.token0() == USDC ? (lReserve0, lReserve1) : (lReserve1, lReserve0);
        // manage half
        _manager.adjustManagement(
            _pair,
            int(_pair.token0() == USDC ? lReserveUSDC / 2 : 0),
            int(_pair.token1() == USDC ? lReserveUSDC / 2 : 0)
        );
        vm.prank(_aaveAdmin);
        _poolConfigurator.setReservePause(USDC, true);

        // act & assert
        int lOutputAmt = _pair.token0() == USDC ? int(MINT_AMOUNT / 2 + 10) : -int(MINT_AMOUNT / 2 + 10);
        _tokenA.mint(address(_pair), lReserveTokenA * 2);
        vm.expectRevert(bytes(Errors.RESERVE_PAUSED));
        _pair.swap(lOutputAmt, false, address(this), bytes(""));

        // assert
        assertEq(_manager.shares(_pair, USDC), MINT_AMOUNT / 2);
        assertEq(_manager.getBalance(_pair, USDC), MINT_AMOUNT / 2);
    }

    // the amount requested is within the balance of the pair, no need to return asset
    function testSwap_NoReturnAsset() public allNetworks allPairs {
        // arrange
        (uint lReserve0, uint lReserve1,) = _pair.getReserves();
        (uint lReserveUSDC, uint lReserveTokenA) =
            _pair.token0() == USDC ? (lReserve0, lReserve1) : (lReserve1, lReserve0);
        // manage half
        _manager.adjustManagement(
            _pair,
            int(_pair.token0() == USDC ? lReserveUSDC / 2 : 0),
            int(_pair.token1() == USDC ? lReserveUSDC / 2 : 0)
        );

        // sanity
        assertEq(IERC20(USDC).balanceOf(address(_pair)), MINT_AMOUNT / 2);

        // act - request exactly what is available in the pair
        int lOutputAmt = _pair.token0() == USDC ? int(MINT_AMOUNT / 2) : -int(MINT_AMOUNT / 2);
        _tokenA.mint(address(_pair), lReserveTokenA * 2);
        _pair.swap(lOutputAmt, false, address(this), bytes(""));

        // assert
        (lReserve0, lReserve1,) = _pair.getReserves();
        lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        assertEq(IERC20(USDC).balanceOf(address(this)), MINT_AMOUNT / 2);
        assertEq(IERC20(USDC).balanceOf(address(_pair)), 0);
        assertEq(lReserveUSDC, MINT_AMOUNT / 2);
        assertApproxEqAbs(_manager.getBalance(_pair, USDC), MINT_AMOUNT / 2, 1);
    }

    function testBurn_ReturnAsset() public allNetworks allPairs {
        // arrange
        (uint lReserve0, uint lReserve1,) = _pair.getReserves();
        uint lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        // manage half
        _manager.adjustManagement(
            _pair,
            int(_pair.token0() == USDC ? lReserveUSDC / 2 : 0),
            int(_pair.token1() == USDC ? lReserveUSDC / 2 : 0)
        );

        // sanity
        (address lAaveToken,,) = _dataProvider.getReserveTokensAddresses(USDC);
        assertEq(IERC20(USDC).balanceOf(address(_pair)), MINT_AMOUNT / 2);
        assertEq(_manager.totalShares(lAaveToken), lReserveUSDC / 2);

        // act
        vm.startPrank(_alice);
        _pair.transfer(address(_pair), _pair.balanceOf(_alice));
        vm.expectCall(address(_manager), bytes(""));
        vm.expectCall(address(_pair), bytes(""));
        _pair.burn(address(this));
        vm.stopPrank();

        // assert - range due to slight diff in liq between CP and SP
        assertApproxEqRel(IERC20(USDC).balanceOf(address(this)), MINT_AMOUNT, 0.000000001e18);
    }

    function testBurn_ReturnAsset_PausedFail() public allNetworks allPairs {
        // arrange
        (uint lReserve0, uint lReserve1,) = _pair.getReserves();
        uint lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        // manage half
        _manager.adjustManagement(
            _pair,
            int(_pair.token0() == USDC ? lReserveUSDC / 2 : 0),
            int(_pair.token1() == USDC ? lReserveUSDC / 2 : 0)
        );
        vm.prank(_aaveAdmin);
        _poolConfigurator.setReservePause(USDC, true);

        // act & assert
        vm.startPrank(_alice);
        _pair.transfer(address(_pair), _pair.balanceOf(_alice));
        vm.expectRevert(bytes(Errors.RESERVE_PAUSED));
        _pair.burn(address(this));
        vm.stopPrank();

        // assert
        (address lAaveToken,,) = _dataProvider.getReserveTokensAddresses(USDC);
        assertEq(IERC20(USDC).balanceOf(address(_pair)), lReserveUSDC / 2);
        assertEq(IERC20(lAaveToken).balanceOf(address(_manager)), lReserveUSDC / 2);
        assertEq(_manager.getBalance(_pair, USDC), lReserveUSDC / 2);
        assertEq(_manager.shares(_pair, USDC), lReserveUSDC / 2);
        assertEq(_manager.totalShares(lAaveToken), lReserveUSDC / 2);
    }

    function testSetUpperThreshold_BreachMaximum() public allNetworks {
        // act & assert
        vm.expectRevert("AM: INVALID_THRESHOLD");
        _manager.setUpperThreshold(101);
    }

    function testSetUpperThreshold_LessThanEqualLowerThreshold(uint aThreshold) public allNetworks {
        // assume
        uint lThreshold = bound(aThreshold, 0, _manager.lowerThreshold());

        // act & assert
        vm.expectRevert("AM: INVALID_THRESHOLD");
        _manager.setUpperThreshold(lThreshold);
    }

    function testSetLowerThreshold_MoreThanEqualUpperThreshold(uint aThreshold) public allNetworks {
        // assume
        uint lThreshold = bound(aThreshold, _manager.upperThreshold(), type(uint).max);

        // act & assert
        vm.expectRevert("AM: INVALID_THRESHOLD");
        _manager.setLowerThreshold(lThreshold);
    }
}
