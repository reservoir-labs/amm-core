pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { LogExpMath } from "src/libraries/LogExpMath.sol";

contract LogExpMathTest is BaseTest
{
    address private _balancerLogExpMath = address(100);

    function setUp() public
    {
        // we use getDeployedCode since the library contract is stateless
        bytes memory lBytecode = vm.getDeployedCode("./reference/balancer-v2-monorepo/pkg/solidity-utils/artifacts/contracts/math/LogExpMath.sol/LogExpMath.json");
        vm.etch(_balancerLogExpMath, lBytecode);
    }

    function testPow() external
    {
        uint256 lX = 5;
        uint256 lY = 6;

        (bool lBool, bytes memory xx) = _balancerLogExpMath.staticcall(abi.encodeWithSignature("pow(uint256,uint256)", lX, lY));
        uint256 lLocalRes = LogExpMath.pow(lX, lY);
    }

    function testExp() external
    {}

    function testLog() external
    {}

    function testLn() external
    {}
}
