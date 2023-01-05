/* solhint-disable const-name-snakecase */
pragma solidity ^0.8.0;

import { ERC20 } from "solmate/tokens/ERC20.sol";

contract ReservoirERC20 is ERC20("Reservoir LP Token", "RES-LP", 18) { }
