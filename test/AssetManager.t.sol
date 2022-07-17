pragma solidity 0.8.13;

import { BaseTest } from "test/__fixtures/BaseTest.sol";

contract AssetManagerTest is BaseTest {

    function setUp() public
    {
        vm.prank(address(_factory));
        _uniswapV2Pair.setManager(_manager);
    }

    function testGetBalance() public
    {
    }

    function testAdjustManagement() public
    {
    }
}
