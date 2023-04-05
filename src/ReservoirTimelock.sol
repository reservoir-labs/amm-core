// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { CompTimelock } from "@openzeppelin/mocks/compound/CompTimelock.sol";

contract ReservoirTimelock is CompTimelock(msg.sender, 100) {
    constructor(){

    }
}
