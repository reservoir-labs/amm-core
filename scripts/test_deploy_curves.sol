// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "scripts/BaseScript.sol";

import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { ConstantProductPair } from "src/curve/constant-product/ConstantProductPair.sol";
import { StableMintBurn } from "src/curve/stable/StableMintBurn.sol";
import { StablePair } from "src/curve/stable/StablePair.sol";

contract VaultScript is BaseScript
{
    using FactoryStoreLib for GenericFactory;

    function run() external
    {
        _setup();

        vm.startBroadcast();

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
        _factory.write("Shared::oracleCaller", address(_oracleCaller));
        _oracleCaller.whitelistAddress(address(this), true);

        _factory.createPair(0x51fCe89b9f6D4c530698f181167043e1bB4abf89, 0xb16F35c0Ae2912430DAc15764477E179D9B9EbEa, 0);
        _factory.createPair(0x51fCe89b9f6D4c530698f181167043e1bB4abf89, 0xb16F35c0Ae2912430DAc15764477E179D9B9EbEa, 1);
        vm.stopBroadcast();
    }
}
