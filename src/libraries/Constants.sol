// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

library ConstantsLib {
    // TODO: to replace this with the actual production address once the deployer address / key has been decided
    address public constant MINT_BURN_ADDRESS = 0xa69E8DF7232756e49EB9Fa8e56c2441154dc0Ff6;

    uint256 public constant INITIAL_MINT_AMOUNT = 100e18;
    uint256 public constant DEFAULT_SWAP_FEE_CP = 3000; // 0.3%
    uint256 public constant DEFAULT_SWAP_FEE_SP = 100; // 0.01%
    uint256 public constant DEFAULT_PLATFORM_FEE = 250_000; // 25%
    uint256 public constant DEFAULT_AMP_COEFF = 1000;
    uint256 public constant DEFAULT_MAX_CHANGE_RATE = 0.0005e18;
}
