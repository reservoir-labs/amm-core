pragma solidity 0.8.13;

import { IERC20 } from "@openzeppelin/interfaces/IERC20.sol";

import "test/__fixtures/BaseTest.sol";

contract AssetManagerTest is BaseTest {

    address public constant ETH_MAINNET_CUSDC = address(0x39AA39c021dfbaE8faC545936693aC917d5E7563);
    address public constant ETH_MAINNET_USDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    function setUp() public
    {
        deal(ETH_MAINNET_USDC, address(this), INITIAL_MINT_AMOUNT);
        console2.log(IERC20(ETH_MAINNET_USDC).balanceOf(address(this)));

        vm.prank(address(_factory));
        _uniswapV2Pair.setManager(_manager);

        // sanity - to make sure that we are talking to a real contract and not on the wrong network
        assertTrue(ETH_MAINNET_CUSDC.code.length != 0);
    }

    function testAdjustManagement_OneToken() public
    {
        // arrange
        int256 lAmountToManage = 5e18;

        // act
        _manager.adjustManagement(address(_uniswapV2Pair), lAmountToManage, 0, ETH_MAINNET_CUSDC);

        // assert
        assertEq(_uniswapV2Pair.token0Managed(), uint256(lAmountToManage));
    }

    function testGetBalance() public
    {

    }
}
