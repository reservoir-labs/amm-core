pragma solidity 0.8.13;

import "test/__fixtures/BaseTest.sol";

import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";
import { CTokenInterface } from "src/interfaces/CErc20Interface.sol";

contract AssetManagerTest is BaseTest {

    address public constant ETH_MAINNET_CUSDC = address(0x39AA39c021dfbaE8faC545936693aC917d5E7563);
    address public constant ETH_MAINNET_USDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    function setUp() public
    {
        // sanity - to make sure that we are talking to a real contract and not on the wrong network
        assertTrue(ETH_MAINNET_CUSDC.code.length != 0);

        // mint some USDC to this address
        deal(ETH_MAINNET_USDC, address(this), INITIAL_MINT_AMOUNT, true);

        _uniswapV2Pair = UniswapV2Pair(_factory.createPair(address(_tokenA), address(ETH_MAINNET_USDC), 0));

        vm.prank(address(_factory));
        _uniswapV2Pair.setManager(_manager);

        IERC20(ETH_MAINNET_USDC).transfer(address(_uniswapV2Pair), INITIAL_MINT_AMOUNT);
        _tokenA.mint((address(_uniswapV2Pair)), INITIAL_MINT_AMOUNT);
        _uniswapV2Pair.mint(_alice);
    }

    function testAdjustManagement_OneToken() public
    {
        // arrange
        int256 lAmountToManage = 5e18;
        uint256 lExchangeRate = CTokenInterface(ETH_MAINNET_CUSDC).exchangeRateStored();

        // act
        _manager.adjustManagement(address(_uniswapV2Pair), lAmountToManage, 0, ETH_MAINNET_CUSDC);

        // assert
        assertEq(_uniswapV2Pair.token0Managed(), uint256(lAmountToManage));
        assertEq(IERC20(ETH_MAINNET_USDC).balanceOf(address(_uniswapV2Pair)), INITIAL_MINT_AMOUNT - uint256(lAmountToManage));
        // TODO: clean up the math that calculates the amount of cUSDC received. Currently off by a bit
        // assertEq(IERC20(ETH_MAINNET_CUSDC).balanceOf(address(_manager)), uint256(lAmountToManage) * 10e18 / lExchangeRate);
    }

    function testGetBalance() public
    {

    }
}
