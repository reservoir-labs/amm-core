pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { LogExpMath } from "src/libraries/LogExpMath.sol";

contract LogExpMathTest is BaseTest
{
    address private _balancerLogExpMath = address(100);

    function setUp() public
    {
        // we use getDeployedCode since the library contract is stateless
        bytes memory lBytecode = vm.getDeployedCode("./reference/balancer-v2-monorepo/pkg/solidity-utils/artifacts/contracts/math/LogExpMathWrapper.sol/LogExpMathWrapper.json");
        vm.etch(_balancerLogExpMath, lBytecode);
    }

    function testPow(uint256 aX, uint256 xY) external
    {
        // assume
        uint256 lX = bound(aX, 0, type(uint256).max);
        uint256 lY = bound(xY, 0, type(uint256).max);

        // act
        (bool lBool, bytes memory lRes) = _balancerLogExpMath.staticcall(abi.encodeWithSignature("pow(uint256,uint256)", lX, lY));

        // assert
        if (lBool) {
            uint256 lLocalRes = LogExpMath.pow(lX, lY);
            uint256 lDecoded = abi.decode(lRes, (uint256));
            assertEq(lLocalRes, lDecoded);
        }
        else {
            vm.expectRevert();
            LogExpMath.pow(lX, lY);
        }
    }

    function testExp() external
    {}

    function testLog() external
    {}

    function testLn() external
    {}
}
