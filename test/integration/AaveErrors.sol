pragma solidity ^0.8.0;

library Errors {
    string public constant RESERVE_INACTIVE = "27"; // "Action requires an active reserve"
    string public constant RESERVE_FROZEN = "28"; // "Action cannot be performed because the reserve is frozen"
    string public constant RESERVE_PAUSED = "29"; // "Action cannot be performed because the reserve is paused"
}
