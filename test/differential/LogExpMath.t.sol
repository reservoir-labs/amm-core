pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { LogExpMath } from "src/libraries/LogExpMath.sol";

contract LogExpMathTest is Test {
    address private _balancerLogExpMath = address(100);

    function setUp() public {
        // we use getDeployedCode since the library contract is stateless
        bytes memory lBytecode = vm.getDeployedCode(
            "./reference/balancer-v2-monorepo/pkg/solidity-utils/artifacts/contracts/math/LogExpMathWrapper.sol/LogExpMathWrapper.json"
        );
        vm.etch(_balancerLogExpMath, lBytecode);
    }

    function testPow(uint aX, uint aY) external {
        // act
        (bool lSuccess, bytes memory lRes) =
            _balancerLogExpMath.staticcall(abi.encodeWithSignature("pow(uint256,uint256)", aX, aY));

        // assert
        if (lSuccess) {
            uint lLocalRes = LogExpMath.pow(aX, aY);
            uint lDecoded = abi.decode(lRes, (uint));
            assertEq(lLocalRes, lDecoded);
        } else {
            vm.expectRevert();
            LogExpMath.pow(aX, aY);
        }
    }

    function testExp(int aX) external {
        // act
        (bool lSuccess, bytes memory lRes) = _balancerLogExpMath.staticcall(abi.encodeWithSignature("exp(int256)", aX));

        // assert
        if (lSuccess) {
            int lLocalRes = LogExpMath.exp(aX);
            int lDecoded = abi.decode(lRes, (int));
            assertEq(lLocalRes, lDecoded);
        } else {
            vm.expectRevert();
            LogExpMath.exp(aX);
        }
    }

    function testLog(int aArg, int aBase) external {
        // act
        (bool lSuccess, bytes memory lRes) =
            _balancerLogExpMath.staticcall(abi.encodeWithSignature("log(int256,int256)", aArg, aBase));

        // assert
        if (lSuccess) {
            int lLocalRes = LogExpMath.log(aArg, aBase);
            int lDecoded = abi.decode(lRes, (int));
            assertEq(lLocalRes, lDecoded);
        } else {
            vm.expectRevert();
            LogExpMath.log(aArg, aBase);
        }
    }

    function testLn(int aArg) external {
        // act
        (bool lSuccess, bytes memory lRes) = _balancerLogExpMath.staticcall(abi.encodeWithSignature("ln(int256)", aArg));

        // assert
        if (lSuccess) {
            int lLocalRes = LogExpMath.ln(aArg);
            int lDecoded = abi.decode(lRes, (int));
            assertEq(lLocalRes, lDecoded);
        } else {
            vm.expectRevert();
            LogExpMath.ln(aArg);
        }
    }
}
