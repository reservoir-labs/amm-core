pragma solidity 0.8.13;

import "test/__fixtures/BaseTest.sol";

import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

import { MathUtils } from "src/libraries/MathUtils.sol";
import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";
import { AssetManager } from "test/__mocks/AssetManager.sol";

contract AssetManagedPairTest is BaseTest
{
    AssetManager private _manager = new AssetManager();

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
        _pairs.push(_constantProductPair);
        _pairs.push(_stablePair);
    }

    function testSetManager() external parameterizedTest
    {
        // sanity
        assertEq(address(_pair.assetManager()), address(0));

        // act
        vm.prank(address(_factory));
        _pair.setManager(_manager);

        // assert
        assertEq(address(_pair.assetManager()), address(_manager));
    }

    function testSetManager_CannotMigrateWithManaged() external parameterizedTest
    {
        // arrange
        vm.prank(address(_factory));
        _pair.setManager(_manager);

        _manager.adjustManagement(_pair, 10e18, 10e18);

        // act & assert
        vm.prank(address(_factory));
        vm.expectRevert("AMP: AM_STILL_ACTIVE");
        _pair.setManager(AssetManager(address(0)));
    }

    function testManageReserves() external parameterizedTest
    {
        // arrange
        _tokenA.mint(address(_pair), 50e18);
        _tokenB.mint(address(_pair), 50e18);
        _pair.mint(address(this));

        vm.prank(address(_factory));
        _pair.setManager(AssetManager(address(this)));

        // act
        _pair.adjustManagement(20e18, 20e18);

        // assert
        assertEq(_tokenA.balanceOf(address(this)), 20e18);
        assertEq(_tokenB.balanceOf(address(this)), 20e18);
    }

    function testManageReserves_DecreaseManagement() external parameterizedTest
    {
        // arrange
        vm.prank(address(_factory));
        _pair.setManager(_manager);

        address lToken0 = _pair.token0();
        address lToken1 = _pair.token1();

        // sanity
        (uint112 lReserve0, uint112 lReserve1, ) = _pair.getReserves();
        uint256 lBal0Before = IERC20(lToken0).balanceOf(address(_pair));
        uint256 lBal1Before = IERC20(lToken1).balanceOf(address(_pair));

        _manager.adjustManagement(_pair, 20e18, 20e18);

        //solhint-disable-next-line var-name-mixedcase
        (uint112 lReserve0_1, uint112 lReserve1_1, ) = _pair.getReserves();
        uint256 lBal0After = IERC20(lToken0).balanceOf(address(_pair));
        uint256 lBal1After = IERC20(lToken1).balanceOf(address(_pair));

        assertEq(uint256(lReserve0_1), lReserve0);
        assertEq(uint256(lReserve1_1), lReserve1);
        assertEq(lBal0Before - lBal0After, 20e18);
        assertEq(lBal1Before - lBal1After, 20e18);

        assertEq(IERC20(lToken0).balanceOf(address(_manager)), 20e18);
        assertEq(IERC20(lToken1).balanceOf(address(_manager)), 20e18);
        assertEq(_manager.getBalance(_pair, address(lToken0)), 20e18);
        assertEq(_manager.getBalance(_pair, address(lToken1)), 20e18);

        // act
        _manager.adjustManagement(_pair, -10e18, -10e18);

        //solhint-disable-next-line var-name-mixedcase
        (uint112 lReserve0_2, uint112 lReserve1_2, ) = _pair.getReserves();

        // assert
        assertEq(uint256(lReserve0_2), lReserve0);
        assertEq(uint256(lReserve1_2), lReserve1);
        assertEq(IERC20(lToken0).balanceOf(address(_manager)), 10e18);
        assertEq(IERC20(lToken1).balanceOf(address(_manager)), 10e18);
        assertEq(_manager.getBalance(_pair, address(lToken0)), 10e18);
        assertEq(_manager.getBalance(_pair, address(lToken1)), 10e18);
    }

    function testManageReserves_KStillHolds() external parameterizedTest
    {
        // arrange
        vm.prank(address(_factory));
        _pair.setManager(_manager);

        // liquidity prior to adjustManagement
        _tokenA.mint(address(_pair), 50e18);
        _tokenB.mint(address(_pair), 50e18);
        uint256 lLiq1 = _pair.mint(address(this));

        _manager.adjustManagement(_pair, 50e18, 50e18);

        // act
        _tokenA.mint(address(_pair), 50e18);
        _tokenB.mint(address(_pair), 50e18);
        uint256 lLiq2 = _pair.mint(address(this));

        // assert
        assertEq(lLiq1, lLiq2);
    }

    function testSyncManaged_ConstantProduct() external
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
        assertEq(lLiq, 10e18); // sqrt 10e18 * 10e18
        assertEq(_tokenA.balanceOf(address(this)), 0);
        assertEq(_tokenB.balanceOf(address(this)), 0);
        assertEq(_manager.getBalance(_constantProductPair, lToken0), 20e18);
        assertEq(_manager.getBalance(_constantProductPair, lToken1), 20e18);

        // act
        _manager.adjustBalance(_constantProductPair, lToken0, 19e18); // 1e18 lost
        _manager.adjustBalance(_constantProductPair, lToken1, 19e18); // 1e18 lost
        _constantProductPair.transfer(address(_constantProductPair), 10e18);
        _constantProductPair.burn(address(this));

        // assert
        assertEq(_manager.getBalance(_constantProductPair, lToken0), 19e18);
        assertEq(_manager.getBalance(_constantProductPair, lToken1), 19e18);
        assertLt(_tokenA.balanceOf(address(this)), 10e18);
        assertLt(_tokenB.balanceOf(address(this)), 10e18);
    }

    function testSyncManaged_Stable() external
    {
        // arrange
        vm.prank(address(_factory));
        _stablePair.setManager(_manager);

        address lToken0 = _stablePair.token0();
        address lToken1 = _stablePair.token1();

        _manager.adjustManagement(_stablePair, 20e18, 20e18);
        _tokenA.mint(address(_stablePair), 10e18);
        _tokenB.mint(address(_stablePair), 10e18);
        uint256 lLiq = _stablePair.mint(address(this));

        // sanity
        assertEq(lLiq, 20e18); // 10e18 + 10e18
        assertEq(_tokenA.balanceOf(address(this)), 0);
        assertEq(_tokenB.balanceOf(address(this)), 0);
        assertEq(_manager.getBalance(_stablePair, lToken0), 20e18);
        assertEq(_manager.getBalance(_stablePair, lToken1), 20e18);

        // act
        _manager.adjustBalance(_stablePair, lToken0, 19e18); // 1e18 lost
        _manager.adjustBalance(_stablePair, lToken1, 19e18); // 1e18 lost
        _stablePair.transfer(address(_stablePair), 10e18);
        _stablePair.burn(address(this));

        // assert
        assertEq(_manager.getBalance(_stablePair, lToken0), 19e18);
        assertEq(_manager.getBalance(_stablePair, lToken1), 19e18);
        (uint112 lReserve0, uint112 lReserve1, ) = _stablePair.getReserves();
        assertTrue(MathUtils.within1(lReserve0, (INITIAL_MINT_AMOUNT + 10e18 - 1e18) * 210e18 / 220e18));
        assertTrue(MathUtils.within1(lReserve1, (INITIAL_MINT_AMOUNT + 10e18 - 1e18) * 210e18 / 220e18));
        assertLt(_tokenA.balanceOf(address(this)), 10e18);
        assertLt(_tokenB.balanceOf(address(this)), 10e18);
    }

    function testSync() external parameterizedTest
    {
        // arrange
        vm.prank(address(_factory));
        _pair.setManager(_manager);
        _manager.adjustManagement(_pair, 20e18, 20e18);
        _manager.adjustBalance(_pair, _pair.token0(), 25e18);
        _manager.adjustBalance(_pair, _pair.token1(), 26e18);

        // act
        _pair.sync();

        // assert
        (uint112 lReserve0, uint112 lReserve1, ) = _pair.getReserves();
        assertEq(_pair.token0Managed(), 25e18);
        assertEq(lReserve0, 105e18);
        assertEq(lReserve1, 106e18);
    }
}
