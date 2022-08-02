pragma solidity 0.8.13;

import "test/__fixtures/BaseTest.sol";

import { IPoolAddressesProvider } from "src/interfaces/IPoolAddressesProvider.sol";
import { IPool } from "src/interfaces/IPool.sol";

import { AaveManager } from "src/asset-manager/AaveManager.sol";

contract AaveIntegrationTest is BaseTest
{
    address public constant FTM_USDC = address(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75);
    address public constant FTM_AAVE_POOL_ADDRESS_PROVIDER = address(0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb);
    address public constant FTM_AAVE_POOL = address(0x794a61358D6845594F94dc1DB02A252b5b4814aD);

    AaveManager private _manager = new AaveManager(FTM_AAVE_POOL_ADDRESS_PROVIDER);

    function testPoolAddress() public
    {
        assertEq(address(_manager.pool()), FTM_AAVE_POOL);
    }
}
