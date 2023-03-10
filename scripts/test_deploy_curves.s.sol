// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "scripts/BaseScript.sol";

import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { ConstantsLib } from "src/libraries/Constants.sol";
import { ConstantProductPair } from "src/curve/constant-product/ConstantProductPair.sol";
import { StableMintBurn } from "src/curve/stable/StableMintBurn.sol";
import { StablePair } from "src/curve/stable/StablePair.sol";
import { OracleCaller } from "src/oracle/OracleCaller.sol";
import { MintableERC20 } from "test/__fixtures/MintableERC20.sol";

contract VaultScript is BaseScript {
    using FactoryStoreLib for GenericFactory;

    MintableERC20 internal _usdc;
    MintableERC20 internal _usdt;

    address internal _recoverer = _makeAddress("recoverer");
    address internal _platformFeeTo = _makeAddress("platformFeeTo");

    OracleCaller private _oracleCaller;

    uint256 private _privateKey = vm.envUint("TEST_PRIVATE_KEY");
    address private _wallet = vm.rememberKey(_privateKey);

    function _makeAddress(string memory aName) internal returns (address) {
        address lAddress = address(uint160(uint256(keccak256(abi.encodePacked(aName)))));
        vm.label(lAddress, aName);

        return lAddress;
    }

    function run() external {
        _setup(_privateKey);
        _deployInfra();
        _deployCore();
    }

    function _deployInfra() internal {
        vm.startBroadcast(_privateKey);
        _usdc = new MintableERC20("USD Circle", "USDC", 6);
        _usdt = new MintableERC20("USD Tether", "USDT", 6);
        vm.stopBroadcast();
    }

    function _deployCore() internal {
        vm.startBroadcast(_privateKey);

        // set shared variables
        _factory.write("Shared::platformFee", ConstantsLib.DEFAULT_PLATFORM_FEE);
        _factory.write("Shared::platformFeeTo", _platformFeeTo);
        _factory.write("Shared::defaultRecoverer", _recoverer);
        _factory.write("Shared::maxChangeRate", ConstantsLib.DEFAULT_MAX_CHANGE_RATE);

        // add constant product curve
        _factory.addCurve(type(ConstantProductPair).creationCode);
        _factory.write("CP::swapFee", ConstantsLib.DEFAULT_SWAP_FEE_CP);

        // add stable curve
        _factory.addCurve(type(StablePair).creationCode);
        _factory.write("SP::swapFee", ConstantsLib.DEFAULT_SWAP_FEE_SP);
        _factory.write("SP::amplificationCoefficient", ConstantsLib.DEFAULT_AMP_COEFF);
        _factory.write("SP::StableMintBurn", ConstantsLib.MINT_BURN_ADDRESS);

        // set oracle caller
        _oracleCaller = new OracleCaller();
        _factory.write("Shared::oracleCaller", address(_oracleCaller));
        _oracleCaller.whitelistAddress(_wallet, true);

        _factory.createPair(address(_usdt), address(_usdc), 0);
        _factory.createPair(address(_usdt), address(_usdc), 1);
        vm.stopBroadcast();
    }
}
