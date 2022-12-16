// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";
import { MintableUniswapV2ERC20 } from "test/__fixtures/MintableUniswapV2ERC20.sol";

contract UniswapV2ERC20Gas is BaseTest {
    MintableUniswapV2ERC20 private _token = new MintableUniswapV2ERC20(18);

    uint256 private _ownerPkey = 0xa11ce;
    address private _owner = vm.addr(_ownerPkey);
    address private _spender = _alice;
    uint256 private _amount = 12.5e18;
    uint256 private _deadline = block.timestamp + 100;
    bytes32 private _digest = keccak256(
        abi.encodePacked(
            "\x19\x01",
            _token.DOMAIN_SEPARATOR(),
            keccak256(abi.encode(_token.PERMIT_TYPEHASH(), _owner, _spender, _amount, _token.nonces(_owner), _deadline))
        )
    );
    uint8 private _v;
    bytes32 private _r;
    bytes32 private _s;

    function setUp() external {
        _token.mint(address(this), 100e18);
        _token.approve(_bob, 50e18);

        // Permit alice to spend 0xa11ce money.
        (_v, _r, _s) = vm.sign(_ownerPkey, _digest);
    }

    function testGasApprove() external {
        // act
        _token.approve(_alice, 50e18);
    }

    function testGasTransfer() external {
        // act
        _token.transfer(_alice, 50e18);
    }

    function testGasTransferFrom() external {
        // act
        vm.prank(_bob);
        _token.transferFrom(address(this), _bob, 50e18);
    }

    function testGasMint() external {
        // act
        _token.mint(_alice, 25e18);
    }

    function testGasBurn() external {
        // act
        _token.burn(address(this), 25e18);
    }

    function testGasPermit() external {
        // act
        _token.permit(_owner, _spender, _amount, _deadline, _v, _r, _s);
    }
}
