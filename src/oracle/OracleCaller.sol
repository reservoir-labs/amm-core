pragma solidity ^0.8.0;

import { Owned } from "solmate/auth/Owned.sol";
import { IOracleWriter, Observation } from "src/interfaces/IOracleWriter.sol";

contract OracleCaller is Owned(msg.sender) {
    event WhitelistChanged(address aCaller, bool aWhitelist);

    mapping(address => bool) public whitelist;

    function observation(IOracleWriter aPair, uint256 aIndex) external returns (Observation memory rObservation) {
        require(whitelist[msg.sender], "OC: NOT_WHITELISTED");
        rObservation = aPair.observation(aIndex);
    }

    function whitelistAddress(address aCaller, bool aWhitelist) external onlyOwner {
        if (whitelist[aCaller] != aWhitelist) {
            whitelist[aCaller] = aWhitelist;
            emit WhitelistChanged(aCaller, aWhitelist);
        }
    }
}
