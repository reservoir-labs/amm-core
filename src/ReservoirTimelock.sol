// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { CompTimelock } from "@openzeppelin/mocks/compound/CompTimelock.sol";

import { GenericFactory } from "src/GenericFactory.sol";
import { ReservoirPair } from "src/ReservoirPair.sol";
import { StablePair } from "src/curve/stable/StablePair.sol";

contract ReservoirTimelock is CompTimelock(msg.sender, 3 days) {
    function setCustomSwapFee(GenericFactory aFactory, address aPair, uint256 aSwapFee) external {
        require(msg.sender == admin, "RT: ADMIN");

        bytes memory lCalldata = abi.encodeCall(ReservoirPair.setCustomSwapFee, (aSwapFee));
        aFactory.rawCall(aPair, lCalldata, 0);
    }

    function setCustomPlatformFee(GenericFactory aFactory, address aPair, uint256 aPlatformFee) external {
        require(msg.sender == admin, "RT: ADMIN");

        bytes memory lCalldata = abi.encodeCall(ReservoirPair.setCustomPlatformFee, (aPlatformFee));
        aFactory.rawCall(aPair, lCalldata, 0);
    }

    function rampA(GenericFactory aFactory, address aPair, uint64 aFutureARaw, uint64 aFutureATime) external {
        require(msg.sender == admin, "RT: ADMIN");

        bytes memory lCalldata = abi.encodeCall(StablePair.rampA, (aFutureARaw, aFutureATime));
        aFactory.rawCall(aPair, lCalldata, 0);
    }
}
