// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { ERC20 } from "solmate/tokens/ERC20.sol";

// solhint-disable-next-line no-empty-blocks
contract ReservoirERC20 is ERC20("Reservoir LP Token", "RES-LP", 18) {
    // no additional initialization is required as all constructor logic is in ERC20
}
