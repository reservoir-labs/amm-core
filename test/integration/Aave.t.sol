pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";
import { Errors } from "test/integration/AaveErrors.sol";

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

import { IPool } from "src/interfaces/aave/IPool.sol";
import { IAaveProtocolDataProvider } from "src/interfaces/aave/IAaveProtocolDataProvider.sol";
import { IPoolAddressesProvider } from "src/interfaces/aave/IPoolAddressesProvider.sol";
import { IPoolConfigurator } from "src/interfaces/aave/IPoolConfigurator.sol";
import { IRewardsController } from "src/interfaces/aave/IRewardsController.sol";

import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { MathUtils } from "src/libraries/MathUtils.sol";
import { AaveManager, IAssetManager } from "src/asset-management/AaveManager.sol";
import { GenericFactory, IERC20 } from "src/GenericFactory.sol";
import { IUSDC } from "test/interfaces/IUSDC.sol";

struct Network {
    string rpcUrl;
    address USDC;
    address masterMinterUSDC;
}

struct Fork {
    bool created;
    uint256 forkId;
}

contract AaveIntegrationTest is BaseTest {
    using FactoryStoreLib for GenericFactory;
    using FixedPointMathLib for uint256;

    event RewardsClaimed(
        address indexed user, address indexed reward, address indexed to, address claimer, uint256 amount
    );

    // this amount is tailored to USDC as it only has 6 decimal places
    // using the usual 100e18 would be too large and would break AAVE
    uint256 public constant MINT_AMOUNT = 1_000_000e6;

    // this address is the same across all chains
    address public constant AAVE_POOL_ADDRESS_PROVIDER = address(0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb);

    AaveManager private _manager;

    ReservoirPair[] internal _pairs;
    ReservoirPair internal _pair;

    Network[] private _networks;
    mapping(string => Fork) private _forks;
    // network specific variables
    IERC20 private USDC;
    address private masterMinterUSDC;
    address private _aaveAdmin;
    IPoolAddressesProvider private _poolAddressesProvider;
    IAaveProtocolDataProvider private _dataProvider;
    IPoolConfigurator private _poolConfigurator;

    modifier allPairs() {
        for (uint256 i = 0; i < _pairs.length; ++i) {
            uint256 lBefore = vm.snapshot();
            _pair = _pairs[i];
            _;
            vm.revertTo(lBefore);
        }
    }

    modifier allNetworks() {
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

        _deployer = _ensureDeployerExists();
        _factory = _deployer.deployFactory(type(GenericFactory).creationCode);
        _deployer.deployConstantProduct(type(ConstantProductPair).creationCode);
        _deployer.deployStable(type(StablePair).creationCode);

        _manager = new AaveManager(IPoolAddressesProvider(AAVE_POOL_ADDRESS_PROVIDER));
        USDC = IERC20(aNetwork.USDC);
        masterMinterUSDC = aNetwork.masterMinterUSDC;
        _poolAddressesProvider = IPoolAddressesProvider(AAVE_POOL_ADDRESS_PROVIDER);
        _aaveAdmin = _poolAddressesProvider.getACLAdmin();
        _dataProvider = IAaveProtocolDataProvider(_poolAddressesProvider.getPoolDataProvider());
        _poolConfigurator = IPoolConfigurator(_poolAddressesProvider.getPoolConfigurator());

        _deal(address(USDC), address(this), MINT_AMOUNT);
        _constantProductPair = ConstantProductPair(_createPair(address(_tokenA), address(USDC), 0));
        USDC.transfer(address(_constantProductPair), MINT_AMOUNT);
        _tokenA.mint(address(_constantProductPair), MINT_AMOUNT);
        _constantProductPair.mint(_alice);
        vm.prank(address(_factory));
        _constantProductPair.setManager(_manager);

        _deal(address(USDC), address(this), MINT_AMOUNT);
        _stablePair = StablePair(_createPair(address(_tokenA), address(USDC), 1));
        USDC.transfer(address(_stablePair), MINT_AMOUNT);
        _tokenA.mint(address(_stablePair), 1_000_000e18);
        _stablePair.mint(_alice);
        vm.prank(address(_factory));
        _stablePair.setManager(_manager);

        _pairs.push(_constantProductPair);
        _pairs.push(_stablePair);
    }

    function _createOtherPair() private returns (ConstantProductPair rOtherPair) {
        rOtherPair = ConstantProductPair(_createPair(address(_tokenB), address(USDC), 0));
        _tokenB.mint(address(rOtherPair), MINT_AMOUNT);
        _deal(address(USDC), address(this), MINT_AMOUNT);
        USDC.transfer(address(rOtherPair), MINT_AMOUNT);
        rOtherPair.mint(_alice);
        vm.prank(address(_factory));
        rOtherPair.setManager(_manager);
    }

    // this is a temporary workaround function to deal ERC20 tokens as forge-std's deal function is broken
    // at the moment
    function _deal(address aToken, address aRecipient, uint256 aAmount) private {
        if (aToken == address(USDC)) {
            vm.startPrank(masterMinterUSDC);
            IUSDC(address(USDC)).configureMinter(masterMinterUSDC, type(uint256).max);
            IUSDC(address(USDC)).mint(aRecipient, aAmount);
            vm.stopPrank();
        }
    }

    function setUp() external {
        _networks.push(Network(getChain("avalanche").rpcUrl, 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E, 0xB7887FED5E2f9dc1A66fBb65f76BA3731d82341A));
//        _networks.push(Network(getChain("polygon").rpcUrl, 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174, ));

        vm.makePersistent(address(_tokenA));
        vm.makePersistent(address(_tokenB));
        vm.makePersistent(address(_tokenC));
    }

    function testUpdatePoolAddress() external allNetworks allPairs {
        // arrange
        vm.mockCall(AAVE_POOL_ADDRESS_PROVIDER, bytes(""), abi.encode(address(1)));

        // act
        _manager.updatePoolAddress();
        vm.clearMockedCalls();

        // assert
        IPool lNewPool = _manager.pool();
        assertEq(address(lNewPool), address(1));
    }

    function testUpdatePoolAddress_NoChange() external allNetworks allPairs {
        // arrange
        IPool lOldPool = _manager.pool();

        // act
        _manager.updatePoolAddress();

        // assert
        IPool lNewPool = _manager.pool();
        assertEq(address(lNewPool), address(lOldPool));
    }

    function testUpdateDataProvider() external allNetworks allPairs {
        // arrange
        vm.mockCall(AAVE_POOL_ADDRESS_PROVIDER, bytes(""), abi.encode(address(1)));

        // act
        _manager.updateDataProviderAddress();
        vm.clearMockedCalls();

        // assert
        IAaveProtocolDataProvider lNewDataProvider = _manager.dataProvider();
        assertEq(address(lNewDataProvider), address(1));
    }

    function testUpdateDataProvider_NoChange() external allNetworks allPairs {
        // arrange
        IAaveProtocolDataProvider lOldDataProvider = _manager.dataProvider();

        // act
        _manager.updateDataProviderAddress();

        // assert
        IAaveProtocolDataProvider lNewDataProvider = _manager.dataProvider();
        assertEq(address(lNewDataProvider), address(lOldDataProvider));
    }

    function testSetWindDownMode() external allNetworks allPairs {
        // sanity
        assertEq(_manager.windDownMode(), false);

        // act
        _manager.setWindDownMode(true);

        // assert
        assertEq(_manager.windDownMode(), true);
    }

    function testAdjustManagement_NoMarket(uint256 aAmountToManage) public allNetworks allPairs {
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
        assertEq(_manager.getBalance(_pair, IERC20(address(_tokenA))), 0);
    }

    function testAdjustManagement_NotOwner() public allNetworks allPairs {
        // act & assert
        vm.prank(_alice);
        vm.expectRevert("UNAUTHORIZED");
        _manager.adjustManagement(_pair, 1, 1);
    }

    function _increaseManagementOneToken(int256 aAmountToManage) private {
        // arrange
        int256 lAmountToManage0 = _pair.token0() == USDC ? aAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? aAmountToManage : int256(0);

        // act
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);
    }

    function testAdjustManagement_IncreaseManagementOneToken() public allNetworks allPairs {
        // arrange
        int256 lAmountToManage = 500e6;
        int256 lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int256(0);

        // act
        _increaseManagementOneToken(lAmountToManage);

        // assert
        (address lRawAaveToken,,) = _dataProvider.getReserveTokensAddresses(address(USDC));
        IERC20 lAaveToken = IERC20(lRawAaveToken);
        assertEq(_pair.token0Managed(), uint256(lAmountToManage0));
        assertEq(_pair.token1Managed(), uint256(lAmountToManage1));
        assertEq(USDC.balanceOf(address(_pair)), MINT_AMOUNT - uint256(lAmountToManage));
        assertEq(lAaveToken.balanceOf(address(_manager)), uint256(lAmountToManage));
        assertEq(_manager.shares(_pair, USDC), uint256(lAmountToManage));
        assertEq(_manager.totalShares(lAaveToken), uint256(lAmountToManage));
    }

    function testAdjustManagement_IncreaseManagementOneToken_Frozen() public allNetworks allPairs {
        // arrange - freeze the USDC market
        int256 lAmountToManage = 500e6;
        vm.prank(_aaveAdmin);
        _poolConfigurator.setReserveFreeze(address(USDC), true);
        int256 lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int256(0);

        // act
        vm.expectRevert(bytes(Errors.RESERVE_FROZEN));
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // assert - nothing should have moved as USDC market is frozen
        (address lRawAaveToken,,) = _dataProvider.getReserveTokensAddresses(address(USDC));
        IERC20 lAaveToken = IERC20(lRawAaveToken);
        assertEq(_pair.token0Managed(), 0);
        assertEq(_pair.token1Managed(), 0);
        assertEq(USDC.balanceOf(address(_pair)), MINT_AMOUNT);
        assertEq(lAaveToken.balanceOf(address(_manager)), 0);
        assertEq(_manager.shares(_pair, USDC), 0);
        assertEq(_manager.totalShares(lAaveToken), 0);
    }

    function testAdjustManagement_IncreaseManagementOneToken_Paused() public allNetworks allPairs {
        // arrange - freeze the USDC market
        int256 lAmountToManage = 500e6;
        vm.prank(_aaveAdmin);
        _poolConfigurator.setReservePause(address(USDC), true);
        int256 lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int256(0);

        // act
        vm.expectRevert(bytes(Errors.RESERVE_PAUSED));
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // assert - nothing should have moved as USDC market is paused
        (address lRawAaveToken,,) = _dataProvider.getReserveTokensAddresses(address(USDC));
        IERC20 lAaveToken = IERC20(lRawAaveToken);
        assertEq(_pair.token0Managed(), 0);
        assertEq(_pair.token1Managed(), 0);
        assertEq(USDC.balanceOf(address(_pair)), MINT_AMOUNT);
        assertEq(lAaveToken.balanceOf(address(_manager)), 0);
        assertEq(_manager.shares(_pair, USDC), 0);
        assertEq(_manager.totalShares(lAaveToken), 0);
    }

    function testAdjustManagement_DecreaseManagementOneToken() public allNetworks allPairs {
        // arrange
        int256 lAmountToManage = -500e6;
        int256 lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int256(0);
        _increaseManagementOneToken(500e6);

        // act
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // assert
        (address lRawAaveToken,,) = _dataProvider.getReserveTokensAddresses(address(USDC));
        IERC20 lAaveToken = IERC20(lRawAaveToken);
        assertEq(_pair.token0Managed(), 0);
        assertEq(_pair.token1Managed(), 0);
        assertEq(USDC.balanceOf(address(_pair)), MINT_AMOUNT);
        assertEq(lAaveToken.balanceOf(address(_manager)), 0);
        assertEq(_manager.shares(_pair, USDC), 0);
        assertEq(_manager.totalShares(lAaveToken), 0);
    }

    function testAdjustManagement_DecreaseManagementBeyondShare() public allNetworks allPairs {
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
        _manager.adjustManagement(lOtherPair, -lAmountToManage - 1, 0);
    }

    function testAdjustManagement_DecreaseManagement_ReservePaused() public allNetworks allPairs {
        // arrange
        int256 lAmountToManage = -500e6;
        int256 lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int256(0);
        _increaseManagementOneToken(500e6);

        vm.prank(_aaveAdmin);
        _poolConfigurator.setReservePause(address(USDC), true);

        // act - withdraw should fail when reserve is paused
        vm.expectRevert(bytes(Errors.RESERVE_PAUSED));
        _manager.adjustManagement(_pair, -lAmountToManage0, -lAmountToManage1);

        // assert
        (address lRawAaveToken,,) = _dataProvider.getReserveTokensAddresses(address(USDC));
        IERC20 lAaveToken = IERC20(lRawAaveToken);
        uint256 lUsdcManaged = _pair.token0() == USDC ? _pair.token0Managed() : _pair.token1Managed();
        assertEq(lUsdcManaged, 500e6);
        assertEq(USDC.balanceOf(address(_pair)), MINT_AMOUNT - 500e6);
        assertEq(lAaveToken.balanceOf(address(_manager)), 500e6);
        assertEq(_manager.shares(_pair, USDC), 500e6);
        assertEq(_manager.totalShares(lAaveToken), 500e6);
    }

    function testAdjustManagement_DecreaseManagement_SucceedEvenWhenFrozen() public allNetworks allPairs {
        // arrange
        int256 lAmountToManage = -500e6;
        int256 lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int256(0);
        _increaseManagementOneToken(500e6);

        vm.prank(_aaveAdmin);
        _poolConfigurator.setReserveFreeze(address(USDC), true);

        // act - withdraw should still succeed when reserve is frozen
        vm.expectCall(address(_pair), abi.encodeCall(_pair.adjustManagement, (lAmountToManage0, lAmountToManage1)));
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // assert
        (address lRawAaveToken,,) = _dataProvider.getReserveTokensAddresses(address(USDC));
        IERC20 lAaveToken = IERC20(lRawAaveToken);
        assertEq(_pair.token0Managed(), 0);
        assertEq(_pair.token1Managed(), 0);
        assertEq(USDC.balanceOf(address(_pair)), MINT_AMOUNT);
        assertEq(lAaveToken.balanceOf(address(_manager)), 0);
        assertEq(_manager.shares(_pair, USDC), 0);
        assertEq(_manager.totalShares(lAaveToken), 0);
    }

    function testAdjustManagement_WindDown() external allNetworks allPairs {
        // arrange
        _increaseManagementOneToken(300e6);
        _manager.setWindDownMode(true);
        int256 lIncreaseAmt = 50e6;

        // act
        _manager.adjustManagement(
            _pair, _pair.token0() == USDC ? lIncreaseAmt : int256(0), _pair.token1() == USDC ? lIncreaseAmt : int256(0)
        );

        // assert
        assertEq(_manager.getBalance(_pair, USDC), 300e6);
    }

    function testGetBalance(uint256 aAmountToManage) public allNetworks allPairs {
        // assume
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        int256 lAmountToManage = int256(bound(aAmountToManage, 0, lReserveUSDC));

        // arrange
        int256 lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int256(0);
        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // act
        uint256 lBalance = _manager.getBalance(_pair, USDC);

        // assert
        assertTrue(MathUtils.within1(lBalance, uint256(lAmountToManage)));
    }

    function testGetBalance_TwoPairsInSameMarket(uint256 aAmountToManage1, uint256 aAmountToManage2)
        public
        allNetworks
        allPairs
    {
        // assume
        ConstantProductPair lOtherPair = _createOtherPair();
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
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

    function testGetBalance_AddingAfterProfit(uint256 aAmountToManage1, uint256 aAmountToManage2, uint256 aTime)
        public
        allNetworks
        allPairs
    {
        // assume
        ConstantProductPair lOtherPair = _createOtherPair();
        (address lRawAaveToken,,) = _dataProvider.getReserveTokensAddresses(address(USDC));
        IERC20 lAaveToken = IERC20(lRawAaveToken);
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
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
        uint256 lAaveTokenAmt2 = lAaveToken.balanceOf(address(_manager));
        _manager.adjustManagement(
            lOtherPair,
            lOtherPair.token0() == USDC ? lAmountToManageOther : int256(0),
            lOtherPair.token1() == USDC ? lAmountToManageOther : int256(0)
        );

        // assert
        assertEq(_manager.shares(_pair, USDC), uint256(lAmountToManagePair));
        assertTrue(MathUtils.within1(_manager.getBalance(_pair, USDC), lAaveTokenAmt2));

        uint256 lExpectedShares =
            uint256(lAmountToManageOther) * 1e18 / (lAaveTokenAmt2 * 1e18 / uint256(lAmountToManagePair));
        assertEq(_manager.shares(lOtherPair, USDC), lExpectedShares);
        uint256 lBalance = _manager.getBalance(lOtherPair, USDC);
        assertTrue(MathUtils.within1(lBalance, uint256(lAmountToManageOther)));
    }

    function testShares(uint256 aAmountToManage) public allNetworks allPairs {
        // assume
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        int256 lAmountToManage = int256(bound(aAmountToManage, 0, lReserveUSDC));

        // arrange
        (address lRawAaveToken,,) = _dataProvider.getReserveTokensAddresses(address(USDC));
        IERC20 lAaveToken = IERC20(lRawAaveToken);
        int256 lAmountToManage0 = _pair.token0() == USDC ? lAmountToManage : int256(0);
        int256 lAmountToManage1 = _pair.token1() == USDC ? lAmountToManage : int256(0);

        _manager.adjustManagement(_pair, lAmountToManage0, lAmountToManage1);

        // act
        uint256 lShares = _manager.shares(_pair, USDC);
        uint256 lTotalShares = _manager.totalShares(lAaveToken);

        // assert
        assertEq(lShares, lTotalShares);
        assertEq(lShares, uint256(lAmountToManage));
    }

    function testShares_AdjustManagementAfterProfit(uint256 aAmountToManage1, uint256 aAmountToManage2)
        public
        allNetworks
        allPairs
    {
        // assume
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        int256 lAmountToManage1 = int256(bound(aAmountToManage1, 100, lReserveUSDC / 2));
        int256 lAmountToManage2 = int256(bound(aAmountToManage2, 100, lReserveUSDC / 2));

        // arrange
        (address lRawAaveToken,,) = _dataProvider.getReserveTokensAddresses(address(USDC));
        IERC20 lAaveToken = IERC20(lRawAaveToken);
        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? lAmountToManage1 : int256(0),
            _pair.token1() == USDC ? lAmountToManage1 : int256(0)
        );

        // act - go forward in time to simulate accrual of profits
        skip(30 days);
        uint256 lAaveTokenAmt1 = lAaveToken.balanceOf(address(_manager));
        assertGt(lAaveTokenAmt1, uint256(lAmountToManage1));
        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? lAmountToManage2 : int256(0),
            _pair.token1() == USDC ? lAmountToManage2 : int256(0)
        );

        // assert
        uint256 lShares = _manager.shares(_pair, USDC);
        uint256 lTotalShares = _manager.totalShares(lAaveToken);
        assertEq(lShares, lTotalShares);
        assertLt(lTotalShares, uint256(lAmountToManage1 + lAmountToManage2));

        uint256 lBalance = _manager.getBalance(_pair, USDC);
        uint256 lAaveTokenAmt2 = lAaveToken.balanceOf(address(_manager));
        assertEq(lBalance, lAaveTokenAmt2);

        // pair not yet informed of the profits, so the numbers are less than what it actually has
        uint256 lUSDCManaged = _pair.token0() == USDC ? _pair.token0Managed() : _pair.token1Managed();
        assertLt(lUSDCManaged, lBalance);

        // after a sync, the pair should have the correct amount
        _pair.sync();
        uint256 lUSDCManagedAfterSync = _pair.token0() == USDC ? _pair.token0Managed() : _pair.token1Managed();
        assertEq(lUSDCManagedAfterSync, lBalance);
    }

    function testAfterLiquidityEvent_IncreaseInvestmentAfterMint() public allNetworks allPairs {
        // sanity
        uint256 lAmountManaged = _manager.getBalance(_pair, USDC);
        assertEq(lAmountManaged, 0);

        // act
        _tokenA.mint(address(_pair), 500e6);
        _deal(address(USDC), address(this), 500e6);
        USDC.transfer(address(_pair), 500e6);
        _pair.mint(address(this));

        // assert
        uint256 lNewAmount = _manager.getBalance(_pair, USDC);
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        assertEq(lNewAmount, lReserveUSDC.mulWad(uint256(_manager.lowerThreshold()).avg(_manager.upperThreshold())));
    }

    function testAfterLiquidityEvent_DecreaseInvestmentAfterBurn(uint256 aInitialAmount) public allNetworks allPairs {
        // assume
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        uint256 lInitialAmount =
            bound(aInitialAmount, lReserveUSDC.mulWad(_manager.upperThreshold() + 0.02e18), lReserveUSDC);

        // arrange
        _manager.adjustManagement(_pair, 0, int256(lInitialAmount));

        // act
        vm.prank(_alice);
        _pair.transfer(address(_pair), 100e6);
        _pair.burn(address(this));

        // assert
        uint256 lNewManagedAmt = _manager.getBalance(_pair, USDC);
        (uint256 lReserve0After, uint256 lReserve1After,,) = _pair.getReserves();
        uint256 lReserveUSDCAfter = _pair.token0() == USDC ? lReserve0After : lReserve1After;
        assertTrue(
            MathUtils.within1(
                lNewManagedAmt, lReserveUSDCAfter.divWad(_manager.lowerThreshold() + _manager.upperThreshold()) / 2)
        );
    }

    function testAfterLiquidityEvent_Mint_RevertIfFrozen() public allNetworks allPairs {
        // arrange
        uint256 lMintAmt = 100e6;
        vm.prank(_aaveAdmin);
        _poolConfigurator.setReserveFreeze(address(USDC), true);

        // act & assert
        _deal(address(USDC), address(this), lMintAmt);
        USDC.transfer(address(_pair), lMintAmt);
        _tokenA.mint(address(_pair), lMintAmt);
        vm.expectRevert(bytes(Errors.RESERVE_FROZEN));
        _pair.mint(address(this));
    }

    function testAfterLiquidityEvent_Mint_RevertIfPaused() public allNetworks allPairs {
        // arrange
        uint256 lMintAmt = 100e6;
        vm.prank(_aaveAdmin);
        _poolConfigurator.setReservePause(address(USDC), true);

        // act & assert
        _deal(address(USDC), address(this), lMintAmt);
        USDC.transfer(address(_pair), lMintAmt);
        _tokenA.mint(address(_pair), lMintAmt);
        vm.expectRevert(bytes(Errors.RESERVE_PAUSED));
        _pair.mint(address(this));
    }

    function testAfterLiquidityEvent_Burn_RevertIfFrozen() public allNetworks allPairs {
        // arrange
        uint256 lAmtToBurn = _pair.balanceOf(_alice) / 2;
        vm.prank(_aaveAdmin);
        _poolConfigurator.setReserveFreeze(address(USDC), true);

        // act & assert
        vm.prank(_alice);
        _pair.transfer(address(_pair), lAmtToBurn);
        vm.expectRevert(bytes(Errors.RESERVE_FROZEN));
        _pair.burn(address(this));
    }

    function testAfterLiquidityEvent_Burn_RevertIfPaused() public allNetworks allPairs {
        // arrange
        uint256 lAmtToBurn = _pair.balanceOf(_alice) / 2;
        vm.prank(_aaveAdmin);
        _poolConfigurator.setReservePause(address(USDC), true);

        // act & assert
        vm.prank(_alice);
        _pair.transfer(address(_pair), lAmtToBurn);
        vm.expectRevert(bytes(Errors.RESERVE_PAUSED));
        _pair.burn(address(this));
    }

    function testAfterLiquidityEvent_RevertIfNotPair() public allNetworks {
        // act & assert
        vm.expectRevert();
        _manager.afterLiquidityEvent();

        // act & assert
        vm.prank(_alice);
        vm.expectRevert();
        _manager.afterLiquidityEvent();
    }

    function testAfterLiquidityEvent_WindDown() external allNetworks allPairs {
        // arrange
        _pair.burn(address(this));
        assertGt(_pair.token0() == USDC ? _pair.token0Managed() : _pair.token1Managed(), 0);
        uint256 lAmtManaged = _manager.getBalance(_pair, USDC);

        // act
        _manager.setWindDownMode(true);

        // assert - burn should still succeed
        _pair.burn(address(this));
        // this call to increase management should have no effect
        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? int256(100e6) : int256(0),
            _pair.token1() == USDC ? int256(100e6) : int256(0)
        );
        assertEq(_manager.getBalance(_pair, USDC), lAmtManaged);
        // a call to decrease management should have an effect
        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? -int256(lAmtManaged) : int256(0),
            _pair.token1() == USDC ? -int256(lAmtManaged) : int256(0)
        );
        assertEq(_manager.getBalance(_pair, USDC), 0);
    }

    function testSwap_ReturnAsset() public allNetworks allPairs {
        // arrange
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        (uint256 lReserveUSDC, uint256 lReserveTokenA) =
            _pair.token0() == USDC ? (lReserve0, lReserve1) : (lReserve1, lReserve0);
        // manage half
        _manager.adjustManagement(
            _pair,
            int256(_pair.token0() == USDC ? lReserveUSDC / 2 : 0),
            int256(_pair.token1() == USDC ? lReserveUSDC / 2 : 0)
        );

        // sanity
        assertEq(USDC.balanceOf(address(_pair)), MINT_AMOUNT / 2);

        // act - request more than what is available in the pair
        int256 lOutputAmt = _pair.token0() == USDC ? int256(MINT_AMOUNT / 2 + 10) : -int256(MINT_AMOUNT / 2 + 10);
        (int256 lExpectedToken0Calldata, int256 lExpectedToken1Calldata) =
            _pair.token0() == USDC ? (int256(-10), int256(0)) : (int256(0), int256(-10));
        _tokenA.mint(address(_pair), lReserveTokenA * 2);
        vm.expectCall(address(_manager), abi.encodeCall(_manager.returnAsset, (_pair.token0() == USDC, 10)));
        vm.expectCall(
            address(_pair), abi.encodeCall(_pair.adjustManagement, (lExpectedToken0Calldata, lExpectedToken1Calldata))
        );
        _pair.swap(lOutputAmt, false, address(this), bytes(""));

        // assert
        (address lRawAaveToken,,) = _dataProvider.getReserveTokensAddresses(address(USDC));
        IERC20 lAaveToken = IERC20(lRawAaveToken);
        (lReserve0, lReserve1,,) = _pair.getReserves();
        lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        assertEq(USDC.balanceOf(address(this)), MINT_AMOUNT / 2 + 10);
        assertEq(USDC.balanceOf(address(_pair)), 0);
        assertEq(lReserveUSDC, MINT_AMOUNT / 2 - 10);
        assertEq(_manager.shares(_pair, USDC), MINT_AMOUNT / 2 - 10);
        assertEq(_manager.totalShares(lAaveToken), MINT_AMOUNT / 2 - 10);
        assertApproxEqAbs(_manager.getBalance(_pair, USDC), MINT_AMOUNT / 2 - 10, 1);
    }

    function testSwap_ReturnAsset_WindDown() external allNetworks allPairs {
        // arrange
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        (uint256 lReserveUSDC, uint256 lReserveTokenA) =
            _pair.token0() == USDC ? (lReserve0, lReserve1) : (lReserve1, lReserve0);
        // manage half
        _manager.adjustManagement(
            _pair,
            int256(_pair.token0() == USDC ? lReserveUSDC / 2 : 0),
            int256(_pair.token1() == USDC ? lReserveUSDC / 2 : 0)
        );
        _manager.setWindDownMode(true);

        // act - request more than what is available in the pair
        int256 lOutputAmt = _pair.token0() == USDC ? int256(MINT_AMOUNT / 2 + 10) : -int256(MINT_AMOUNT / 2 + 10);
        (int256 lExpectedToken0Calldata, int256 lExpectedToken1Calldata) =
            _pair.token0() == USDC ? (int256(-10), int256(0)) : (int256(0), int256(-10));
        _tokenA.mint(address(_pair), lReserveTokenA * 2);
        vm.expectCall(address(_manager), abi.encodeCall(_manager.returnAsset, (_pair.token0() == USDC, 10)));
        vm.expectCall(
            address(_pair), abi.encodeCall(_pair.adjustManagement, (lExpectedToken0Calldata, lExpectedToken1Calldata))
        );
        _pair.swap(lOutputAmt, false, address(this), bytes(""));

        // assert
        (address lRawAaveToken,,) = _dataProvider.getReserveTokensAddresses(address(USDC));
        IERC20 lAaveToken = IERC20(lRawAaveToken);
        (lReserve0, lReserve1,,) = _pair.getReserves();
        lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        assertEq(USDC.balanceOf(address(this)), MINT_AMOUNT / 2 + 10);
        assertEq(USDC.balanceOf(address(_pair)), 0);
        assertEq(lReserveUSDC, MINT_AMOUNT / 2 - 10);
        assertEq(_manager.shares(_pair, USDC), MINT_AMOUNT / 2 - 10);
        assertEq(_manager.totalShares(lAaveToken), MINT_AMOUNT / 2 - 10);
        assertApproxEqAbs(_manager.getBalance(_pair, USDC), MINT_AMOUNT / 2 - 10, 1);
    }

    // when the pool is paused, attempts to withdraw should fail and the swap should fail too
    function testSwap_ReturnAsset_PausedFail() public allNetworks allPairs {
        // arrange
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        (uint256 lReserveUSDC, uint256 lReserveTokenA) =
            _pair.token0() == USDC ? (lReserve0, lReserve1) : (lReserve1, lReserve0);
        // manage half
        _manager.adjustManagement(
            _pair,
            int256(_pair.token0() == USDC ? lReserveUSDC / 2 : 0),
            int256(_pair.token1() == USDC ? lReserveUSDC / 2 : 0)
        );
        vm.prank(_aaveAdmin);
        _poolConfigurator.setReservePause(address(USDC), true);

        // act & assert
        int256 lOutputAmt = _pair.token0() == USDC ? int256(MINT_AMOUNT / 2 + 10) : -int256(MINT_AMOUNT / 2 + 10);
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
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        (uint256 lReserveUSDC, uint256 lReserveTokenA) =
            _pair.token0() == USDC ? (lReserve0, lReserve1) : (lReserve1, lReserve0);
        // manage half
        _manager.adjustManagement(
            _pair,
            int256(_pair.token0() == USDC ? lReserveUSDC / 2 : 0),
            int256(_pair.token1() == USDC ? lReserveUSDC / 2 : 0)
        );

        // sanity
        assertEq(USDC.balanceOf(address(_pair)), MINT_AMOUNT / 2);

        // act - request exactly what is available in the pair
        int256 lOutputAmt = _pair.token0() == USDC ? int256(MINT_AMOUNT / 2) : -int256(MINT_AMOUNT / 2);
        _tokenA.mint(address(_pair), lReserveTokenA * 2);
        _pair.swap(lOutputAmt, false, address(this), bytes(""));

        // assert
        (lReserve0, lReserve1,,) = _pair.getReserves();
        lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        assertEq(USDC.balanceOf(address(this)), MINT_AMOUNT / 2);
        assertEq(USDC.balanceOf(address(_pair)), 0);
        assertEq(lReserveUSDC, MINT_AMOUNT / 2);
        assertApproxEqAbs(_manager.getBalance(_pair, USDC), MINT_AMOUNT / 2, 1);
    }

    function testBurn_ReturnAsset() public allNetworks allPairs {
        // arrange
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        // manage half
        _manager.adjustManagement(
            _pair,
            int256(_pair.token0() == USDC ? lReserveUSDC / 2 : 0),
            int256(_pair.token1() == USDC ? lReserveUSDC / 2 : 0)
        );

        // sanity
        (address lRawAaveToken,,) = _dataProvider.getReserveTokensAddresses(address(USDC));
        IERC20 lAaveToken = IERC20(lRawAaveToken);
        assertEq(USDC.balanceOf(address(_pair)), MINT_AMOUNT / 2);
        assertEq(_manager.totalShares(lAaveToken), lReserveUSDC / 2);

        // act
        vm.startPrank(_alice);
        _pair.transfer(address(_pair), _pair.balanceOf(_alice));
        vm.expectCall(address(_manager), bytes(""));
        vm.expectCall(address(_pair), bytes(""));
        _pair.burn(address(this));
        vm.stopPrank();

        // assert - range due to slight diff in liq between CP and SP
        assertApproxEqRel(USDC.balanceOf(address(this)), MINT_AMOUNT, 0.000000001e18);
    }

    function testBurn_ReturnAsset_PausedFail() public allNetworks allPairs {
        // arrange
        (uint256 lReserve0, uint256 lReserve1,,) = _pair.getReserves();
        uint256 lReserveUSDC = _pair.token0() == USDC ? lReserve0 : lReserve1;
        // manage half
        _manager.adjustManagement(
            _pair,
            int256(_pair.token0() == USDC ? lReserveUSDC / 2 : 0),
            int256(_pair.token1() == USDC ? lReserveUSDC / 2 : 0)
        );
        vm.prank(_aaveAdmin);
        _poolConfigurator.setReservePause(address(USDC), true);

        // act & assert
        vm.startPrank(_alice);
        _pair.transfer(address(_pair), _pair.balanceOf(_alice));
        vm.expectRevert(bytes(Errors.RESERVE_PAUSED));
        _pair.burn(address(this));
        vm.stopPrank();

        // assert
        (address lRawAaveToken,,) = _dataProvider.getReserveTokensAddresses(address(USDC));
        IERC20 lAaveToken = IERC20(lRawAaveToken);
        assertEq(USDC.balanceOf(address(_pair)), lReserveUSDC / 2);
        assertEq(lAaveToken.balanceOf(address(_manager)), lReserveUSDC / 2);
        assertEq(_manager.getBalance(_pair, USDC), lReserveUSDC / 2);
        assertEq(_manager.shares(_pair, USDC), lReserveUSDC / 2);
        assertEq(_manager.totalShares(lAaveToken), lReserveUSDC / 2);
    }

    function testSetThresholds_BreachMaximum() public allNetworks {
        // act & assert
        vm.expectRevert("AM: INVALID_THRESHOLDS");
        _manager.setThresholds(0, 1e18 + 1);
    }

    function testSetThresholds_UpperLessThanLowerThreshold(uint256 aThreshold) public allNetworks {
        // assume
        uint128 lLowerThreshold = _manager.lowerThreshold();
        uint256 lThreshold = bound(aThreshold, 0, lLowerThreshold - 1);

        // act & assert
        vm.expectRevert("AM: INVALID_THRESHOLDS");
        _manager.setThresholds(lLowerThreshold, uint128(lThreshold));
    }

    function testSetThresholds_LowerMoreThanUpperThreshold(uint256 aThreshold) public allNetworks {
        // assume
        uint128 lUpperThreshold = _manager.upperThreshold();
        uint256 lThreshold = bound(aThreshold, lUpperThreshold + 1, type(uint128).max);

        // act & assert
        vm.expectRevert("AM: INVALID_THRESHOLDS");
        _manager.setThresholds(uint128(lThreshold), lUpperThreshold);
    }

    function testThresholdToZero_Migrate(
        uint256 aAmtToManage0,
        uint256 aAmtToManage1,
        uint256 aAmtToManage2,
        uint256 aFastForwardTime
    ) external allNetworks allPairs {
        // assume
        uint256 lAmtToManage0 = bound(aAmtToManage0, 1, MINT_AMOUNT);
        uint256 lAmtToManage1 = bound(aAmtToManage1, 1, MINT_AMOUNT);
        uint256 lAmtToManage2 = bound(aAmtToManage2, 1, MINT_AMOUNT);
        uint256 lFastForwardTime = bound(aFastForwardTime, 5 minutes, 60 days);

        // arrange
        ConstantProductPair lOtherPair = _createOtherPair();
        StablePair lThirdPair = StablePair(_createPair(address(USDC), address(_tokenC), 1));
        _deal(address(USDC), address(lThirdPair), MINT_AMOUNT);
        _tokenC.mint(address(lThirdPair), MINT_AMOUNT);
        lThirdPair.mint(_alice);
        vm.prank(address(_factory));
        lThirdPair.setManager(_manager);
        _increaseManagementOneToken(int256(lAmtToManage0));
        _manager.adjustManagement(
            lOtherPair,
            lOtherPair.token0() == USDC ? int256(lAmtToManage1) : int256(0),
            lOtherPair.token1() == USDC ? int256(lAmtToManage1) : int256(0)
        );
        _manager.adjustManagement(
            lThirdPair,
            lThirdPair.token0() == USDC ? int256(lAmtToManage2) : int256(0),
            lThirdPair.token1() == USDC ? int256(lAmtToManage2) : int256(0)
        );

        // act
        _manager.setThresholds(0, 0);
        // step some time to accumulate some profits
        _stepTime(lFastForwardTime);

        // assert
        _pair.burn(address(this));
        lOtherPair.burn(address(this));
        lThirdPair.burn(address(this));
        // attempts to migrate after this should succeed
        vm.startPrank(address(_factory));
        _pair.setManager(IAssetManager(address(0)));
        lOtherPair.setManager(IAssetManager(address(0)));
        lThirdPair.setManager(IAssetManager(address(0)));
        vm.stopPrank();
        assertEq(address(_pair.assetManager()), address(0));
        assertEq(address(lOtherPair.assetManager()), address(0));
        assertEq(address(lThirdPair.assetManager()), address(0));
        assertEq(_pair.token0Managed(), 0);
        assertEq(_pair.token1Managed(), 0);
        assertEq(lOtherPair.token0Managed(), 0);
        assertEq(lOtherPair.token1Managed(), 0);
        assertEq(lThirdPair.token0Managed(), 0);
        assertEq(lThirdPair.token1Managed(), 0);
        assertEq(_manager.shares(_pair, USDC), 0);
        assertEq(_manager.shares(lOtherPair, USDC), 0);
        assertEq(_manager.shares(lThirdPair, USDC), 0);
    }

    function testClaimReward() external allNetworks allPairs {
        // this test is only applicable on AVAX as USDC does not have additional rewards on polygon
        if (vm.activeFork() != 0) return;

        // arrange
        _increaseManagementOneToken(500e6);
        _manager.setRewardSeller(address(this));
        _manager.setRewardsController(address(0x929EC64c34a17401F460460D4B9390518E5B473e));
        (address lUSDCMarket,,) = _dataProvider.getReserveTokensAddresses(address(USDC));
        address lWavax = address(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
        address[] memory lMarkets = new address[](1);
        lMarkets[0] = lUSDCMarket;

        // act - step time to accumulate some rewards
        _stepTime(5000);
        address lRewardsController = address(_manager.rewardsController());
        vm.expectCall(
            lRewardsController,
            abi.encodeCall(IRewardsController.claimRewards, (lMarkets, type(uint256).max, address(this), lWavax))
        );
        uint256 lClaimed = _manager.claimRewardForMarket(lUSDCMarket, lWavax);

        // assert
        assertEq(IERC20(lWavax).balanceOf(address(this)), lClaimed);
    }

    function testClaimRewards_SellAndPutRewardsBackIntoManager() external allNetworks allPairs {
        // this test is only applicable on AVAX as USDC does not have additional rewards on polygon
        if (vm.activeFork() != 0) return;

        // arrange
        _increaseManagementOneToken(500e6);
        ConstantProductPair lOtherPair = _createOtherPair();
        _manager.adjustManagement(
            lOtherPair,
            lOtherPair.token0() == USDC ? int256(100e6) : int256(0),
            lOtherPair.token1() == USDC ? int256(100e6) : int256(0)
        );
        _manager.setRewardSeller(address(this));
        _manager.setRewardsController(address(0x929EC64c34a17401F460460D4B9390518E5B473e));
        (address lUSDCMarket,,) = _dataProvider.getReserveTokensAddresses(address(USDC));
        IERC20 lAaveToken = IERC20(lUSDCMarket);
        address lWavax = address(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
        address[] memory lMarkets = new address[](1);
        lMarkets[0] = lUSDCMarket;

        // act - simulate a claiming and selling of the rewards into more aaveUSDC
        _stepTime(5000);
        uint256 lBalAfterTimePair = _manager.getBalance(_pair, USDC);
        uint256 lBalAfterTimeOther = _manager.getBalance(lOtherPair, USDC);
        uint256 lClaimed = _manager.claimRewardForMarket(lUSDCMarket, lWavax);
        uint256 lAmtUSDC = 9_019_238;
        _deal(address(USDC), address(this), lAmtUSDC);
        // supply the USDC for aaveUSDC
        IPool lPool = _manager.pool();
        USDC.approve(address(lPool), type(uint256).max);
        lPool.supply(address(USDC), lAmtUSDC, address(this), 0);
        assertEq(lAaveToken.balanceOf(address(this)), lAmtUSDC);
        lAaveToken.transfer(address(_manager), lAmtUSDC);

        // assert
        uint256 lBalAfterCompoundingPair = _manager.getBalance(_pair, USDC);
        uint256 lBalAfterCompoundingOther = _manager.getBalance(lOtherPair, USDC);
        // percentage growth is the same
        uint256 lPercentageIncreasePair = lBalAfterCompoundingPair.divWad(lBalAfterTimePair);
        uint256 lPercentageIncreaseOther = lBalAfterCompoundingOther.divWad(lBalAfterTimeOther);
        // percentage diff is no greater than 0.000001%
        assertApproxEqRel(lPercentageIncreasePair, lPercentageIncreaseOther, 0.00000001e18);
    }

    function testFullRedeem_MultiplePairs(
        uint256 aAmtToManage0,
        uint256 aAmtToManage1,
        uint256 aAmtToManage2,
        uint256 aFastForwardTime
    ) external allNetworks allPairs {
        // assume
        uint256 lAmtToManage0 = bound(aAmtToManage0, 1, MINT_AMOUNT);
        uint256 lAmtToManage1 = bound(aAmtToManage1, 1, MINT_AMOUNT);
        uint256 lAmtToManage2 = bound(aAmtToManage2, 1, MINT_AMOUNT);
        uint256 lFastForwardTime = bound(aFastForwardTime, 10 days, 60 days);

        // arrange
        ConstantProductPair lOtherPair = _createOtherPair();
        StablePair lThirdPair = StablePair(_createPair(address(USDC), address(_tokenC), 1));
        _deal(address(USDC), address(lThirdPair), MINT_AMOUNT);
        _tokenC.mint(address(lThirdPair), MINT_AMOUNT);
        lThirdPair.mint(_alice);
        vm.prank(address(_factory));
        lThirdPair.setManager(_manager);
        (address lUSDCMarket,,) = _dataProvider.getReserveTokensAddresses(address(USDC));
        IERC20 lAaveToken = IERC20(lUSDCMarket);
        _increaseManagementOneToken(int256(lAmtToManage0));
        _manager.adjustManagement(
            lOtherPair,
            lOtherPair.token0() == USDC ? int256(lAmtToManage1) : int256(0),
            lOtherPair.token1() == USDC ? int256(lAmtToManage1) : int256(0)
        );
        _manager.adjustManagement(
            lThirdPair,
            lThirdPair.token0() == USDC ? int256(lAmtToManage2) : int256(0),
            lThirdPair.token1() == USDC ? int256(lAmtToManage2) : int256(0)
        );

        // act
        _stepTime(lFastForwardTime);

        // divest everything
        lOtherPair.sync();
        _manager.adjustManagement(
            lOtherPair,
            lOtherPair.token0() == USDC ? -int256(_manager.getBalance(lOtherPair, USDC)) : int256(0),
            lOtherPair.token1() == USDC ? -int256(_manager.getBalance(lOtherPair, USDC)) : int256(0)
        );
        lThirdPair.sync();
        _manager.adjustManagement(
            lThirdPair,
            lThirdPair.token0() == USDC ? -int256(_manager.getBalance(lThirdPair, USDC)) : int256(0),
            lThirdPair.token1() == USDC ? -int256(_manager.getBalance(lThirdPair, USDC)) : int256(0)
        );
        _pair.sync();
        _manager.adjustManagement(
            _pair,
            _pair.token0() == USDC ? -int256(_manager.getBalance(_pair, USDC)) : int256(0),
            _pair.token1() == USDC ? -int256(_manager.getBalance(_pair, USDC)) : int256(0)
        );

        // assert
        // actually these checks for managed amounts zero are kind of redundant
        // cuz it's checked in setManager anyway
        assertEq(_pair.token0Managed(), 0);
        assertEq(_pair.token1Managed(), 0);
        assertEq(lOtherPair.token0Managed(), 0);
        assertEq(lOtherPair.token1Managed(), 0);
        assertEq(lThirdPair.token0Managed(), 0);
        assertEq(lThirdPair.token1Managed(), 0);
        vm.startPrank(address(_factory));
        _pair.setManager(IAssetManager(address(0)));
        lOtherPair.setManager(IAssetManager(address(0)));
        lThirdPair.setManager(IAssetManager(address(0)));
        vm.stopPrank();
        assertEq(address(_pair.assetManager()), address(0));
        assertEq(address(lOtherPair.assetManager()), address(0));
        assertEq(address(lThirdPair.assetManager()), address(0));
        assertEq(_manager.totalShares(lAaveToken), 0);
        assertEq(_manager.shares(_pair, USDC), 0);
        assertEq(_manager.shares(lOtherPair, USDC), 0);
        assertEq(_manager.shares(lThirdPair, USDC), 0);
    }
}
