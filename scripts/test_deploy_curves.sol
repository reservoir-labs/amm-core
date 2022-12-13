// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "scripts/BaseScript.sol";

import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";
import { ConstantProductPair } from "src/curve/constant-product/ConstantProductPair.sol";
import { StablePair } from "src/curve/stable/StablePair.sol";

uint256 constant INITIAL_MINT_AMOUNT = 100e18;
uint256 constant DEFAULT_SWAP_FEE_CP = 3000; // 0.3%
uint256 constant DEFAULT_SWAP_FEE_SP = 100; // 0.01%
uint256 constant DEFAULT_PLATFORM_FEE = 250_000; // 25%
uint256 constant DEFAULT_AMP_COEFF = 1000;
uint256 constant DEFAULT_ALLOWED_CHANGE_PER_SECOND = 0.0005e18;

contract VaultScript is BaseScript
{
    using FactoryStoreLib for GenericFactory;

    function run() external
    {
        _setup();

        vm.startBroadcast();
        // set shared variables
        _factory.write("Shared::platformFee", DEFAULT_PLATFORM_FEE);
        // _factory.write("Shared::platformFeeTo", _platformFeeTo);
        // _factory.write("Shared::defaultRecoverer", _recoverer);
        _factory.write("Shared::allowedChangePerSecond", DEFAULT_ALLOWED_CHANGE_PER_SECOND);

        // add constant product curve
        _factory.addCurve(type(ConstantProductPair).creationCode);
        _factory.write("CP::swapFee", DEFAULT_SWAP_FEE_CP);

        // add stable curve
        _factory.addCurve(type(StablePair).creationCode);
        _factory.write("SP::swapFee", DEFAULT_SWAP_FEE_SP);
        _factory.write("SP::amplificationCoefficient", DEFAULT_AMP_COEFF);

        _factory.createPair(0x11fE4B6AE13d2a6055C8D9cF65c55bac32B5d844, 0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6, 0);
        _factory.createPair(0x11fE4B6AE13d2a6055C8D9cF65c55bac32B5d844, 0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6, 1);
        vm.stopBroadcast();
    }
}
