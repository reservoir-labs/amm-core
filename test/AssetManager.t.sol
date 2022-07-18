pragma solidity 0.8.13;

import { BaseTest } from "test/__fixtures/BaseTest.sol";

contract AssetManagerTest is BaseTest {

    address public constant ETH_MAINNET_CUSDC = address(0x39AA39c021dfbaE8faC545936693aC917d5E7563);

    function setUp() public
    {
        vm.prank(address(_factory));
        _uniswapV2Pair.setManager(_manager);

        // sanity - to make sure that we are talking to a real contract and not on the wrong network
        assertTrue(ETH_MAINNET_CUSDC.code.length != 0);
    }

    function testAdjustManagement() public
    {
        // arrange

        // act
//        _manager.adjustManagement();
    }


    function testGetBalance() public
    {
    }
}
