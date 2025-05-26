pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import { LogExpMath } from "src/libraries/LogExpMath.sol";
import { LogExpMathWrapper } from "test/__mocks/LogExpMathWrapper.sol";

contract LogExpMathTest is Test {
    address private _balancerLogExpMath = address(100);

    LogExpMathWrapper internal _logExpMathWrapper = new LogExpMathWrapper();

    constructor() {
        // we use getDeployedCode since the library contract is stateless
        bytes memory lBytecode = vm.getDeployedCode(
            "./reference/balancer-v2-monorepo/pkg/solidity-utils/artifacts/contracts/math/LogExpMathWrapper.sol/LogExpMathWrapper.json"
        );
        vm.etch(_balancerLogExpMath, lBytecode);
    }

    function testPow(uint256 aX, uint256 aY) external {
        // act
        (bool lSuccess, bytes memory lRes) =
            _balancerLogExpMath.staticcall(abi.encodeWithSignature("pow(uint256,uint256)", aX, aY));

        // assert
        if (lSuccess) {
            uint256 lLocalRes = _logExpMathWrapper.pow(aX, aY);
            uint256 lDecoded = abi.decode(lRes, (uint256));
            assertEq(lLocalRes, lDecoded);
        } else {
            vm.expectRevert();
            _logExpMathWrapper.pow(aX, aY);
        }
    }

    function testExp(int256 aX) external {
        // act
        (bool lSuccess, bytes memory lRes) = _balancerLogExpMath.staticcall(abi.encodeWithSignature("exp(int256)", aX));

        // assert
        if (lSuccess) {
            int256 lLocalRes = _logExpMathWrapper.exp(aX);
            int256 lDecoded = abi.decode(lRes, (int256));
            assertEq(lLocalRes, lDecoded);
        } else {
            vm.expectRevert();
            _logExpMathWrapper.exp(aX);
        }
    }

    function testLog(int256 aArg, int256 aBase) external {
        // act
        (bool lSuccess, bytes memory lRes) =
            _balancerLogExpMath.staticcall(abi.encodeWithSignature("log(int256,int256)", aArg, aBase));

        // assert
        if (lSuccess) {
            int256 lLocalRes = _logExpMathWrapper.log(aArg, aBase);
            int256 lDecoded = abi.decode(lRes, (int256));
            assertEq(lLocalRes, lDecoded);
        } else {
            vm.expectRevert();
            _logExpMathWrapper.log(aArg, aBase);
        }
    }

    function testLn(int256 aArg) external {
        // act
        (bool lSuccess, bytes memory lRes) = _balancerLogExpMath.staticcall(abi.encodeWithSignature("ln(int256)", aArg));

        // assert
        if (lSuccess) {
            int256 lLocalRes = _logExpMathWrapper.ln(aArg);
            int256 lDecoded = abi.decode(lRes, (int256));
            assertEq(lLocalRes, lDecoded);
        } else {
            vm.expectRevert();
            _logExpMathWrapper.ln(aArg);
        }
    }
}
