pragma solidity ^0.8.0;

import "test/__fixtures/BaseTest.sol";

import { ReservoirPair } from "src/ReservoirPair.sol";

contract PairTest is BaseTest {
    using FactoryStoreLib for GenericFactory;

    event SwapFeeChanged(uint256 oldSwapFee, uint256 newSwapFee);
    event PlatformFeeChanged(uint256 oldPlatformFee, uint256 newPlatformFee);

    ReservoirPair[] internal _pairs;
    ReservoirPair internal _pair;

    function setUp() public {
        _pairs.push(_constantProductPair);
        _pairs.push(_stablePair);
    }

    modifier allPairs() {
        for (uint256 i = 0; i < _pairs.length; ++i) {
            uint256 lBefore = vm.snapshot();
            _pair = _pairs[i];
            _;
            vm.revertTo(lBefore);
        }
    }

    function testNonPayable() public allPairs {
        // arrange
        address payable lStablePair = payable(address(_stablePair));

        // act & assert
        vm.expectRevert();
        lStablePair.transfer(1 ether);
    }

    function testEmitEventOnCreation() public {
        // act & assert
        vm.expectEmit(true, true, false, false);
        emit SwapFeeChanged(0, ConstantsLib.DEFAULT_SWAP_FEE_CP);
        vm.expectEmit(true, true, false, false);
        emit PlatformFeeChanged(0, ConstantsLib.DEFAULT_PLATFORM_FEE);
        _createPair(address(_tokenC), address(_tokenD), 0);

        vm.expectEmit(true, true, false, false);
        emit SwapFeeChanged(0, ConstantsLib.DEFAULT_SWAP_FEE_SP);
        vm.expectEmit(true, true, false, false);
        emit PlatformFeeChanged(0, ConstantsLib.DEFAULT_PLATFORM_FEE);
        _createPair(address(_tokenC), address(_tokenD), 1);
    }

    function testSwapFee_UseDefault() public {
        // assert
        assertEq(_constantProductPair.swapFee(), ConstantsLib.DEFAULT_SWAP_FEE_CP);
        assertEq(_stablePair.swapFee(), ConstantsLib.DEFAULT_SWAP_FEE_SP);
    }

    function testCustomSwapFee_OffByDefault() public allPairs {
        // assert
        assertEq(_pair.customSwapFee(), type(uint256).max);
    }

    function testSetSwapFeeForPair() public allPairs {
        // act
        _factory.rawCall(address(_pair), abi.encodeWithSignature("setCustomSwapFee(uint256)", 357), 0);

        // assert
        assertEq(_pair.customSwapFee(), 357);
        assertEq(_pair.swapFee(), 357);
    }

    function testSetSwapFeeForPair_Reset() public allPairs {
        // arrange
        _factory.rawCall(address(_pair), abi.encodeWithSignature("setCustomSwapFee(uint256)", 10_000), 0);

        // act
        _factory.rawCall(address(_pair), abi.encodeWithSignature("setCustomSwapFee(uint256)", type(uint256).max), 0);

        // assert
        assertEq(_pair.customSwapFee(), type(uint256).max);
        if (_pair == _constantProductPair) {
            assertEq(_pair.swapFee(), ConstantsLib.DEFAULT_SWAP_FEE_CP);
        } else if (_pair == _stablePair) {
            assertEq(_pair.swapFee(), ConstantsLib.DEFAULT_SWAP_FEE_SP);
        }
    }

    function testSetSwapFeeForPair_BreachMaximum(uint256 aCustomSwapFee) public allPairs {
        // assume
        uint256 lCustomSwapFee = bound(aCustomSwapFee, _pair.MAX_SWAP_FEE() + 1, type(uint256).max - 1);

        // act & assert
        vm.expectRevert("P: INVALID_SWAP_FEE");
        _factory.rawCall(address(_pair), abi.encodeWithSignature("setCustomSwapFee(uint256)", lCustomSwapFee), 0);
    }

    function testCustomPlatformFee_OffByDefault() public allPairs {
        // assert
        assertEq(_pair.customPlatformFee(), type(uint256).max);
        assertEq(_pair.platformFee(), ConstantsLib.DEFAULT_PLATFORM_FEE);
    }

    function testSetPlatformFeeForPair() public allPairs {
        // act
        _factory.rawCall(address(_pair), abi.encodeWithSignature("setCustomPlatformFee(uint256)", 10_000), 0);

        // assert
        assertEq(_pair.customPlatformFee(), 10_000);
        assertEq(_pair.platformFee(), 10_000);
    }

    function testSetPlatformFeeForPair_Reset() public allPairs {
        // arrange
        _factory.rawCall(address(_pair), abi.encodeWithSignature("setCustomPlatformFee(uint256)", 10_000), 0);

        // act
        _factory.rawCall(address(_pair), abi.encodeWithSignature("setCustomPlatformFee(uint256)", type(uint256).max), 0);

        // assert
        assertEq(_pair.customPlatformFee(), type(uint256).max);
        assertEq(_pair.platformFee(), ConstantsLib.DEFAULT_PLATFORM_FEE);
    }

    function testSetPlatformFeeForPair_BreachMaximum(uint256 aPlatformFee) public allPairs {
        // assume - max is type(uint256).max - 1 as type(uint256).max is used to indicate absence of custom platformFee
        uint256 lPlatformFee = bound(aPlatformFee, _pair.MAX_PLATFORM_FEE() + 1, type(uint256).max - 1);

        // act & assert
        vm.expectRevert("P: INVALID_PLATFORM_FEE");
        _factory.rawCall(address(_pair), abi.encodeWithSignature("setCustomPlatformFee(uint256)", lPlatformFee), 0);
    }

    function testUpdateDefaultFees() public allPairs {
        // arrange
        uint256 lNewDefaultSwapFee = 200;
        uint256 lNewDefaultPlatformFee = 5000;
        _factory.write("CP::swapFee", lNewDefaultSwapFee);
        _factory.write("SP::swapFee", lNewDefaultSwapFee);
        _factory.write("Shared::platformFee", lNewDefaultPlatformFee);

        // act
        vm.expectEmit(true, true, false, false);
        emit SwapFeeChanged(
            _pair == _constantProductPair ? ConstantsLib.DEFAULT_SWAP_FEE_CP : ConstantsLib.DEFAULT_SWAP_FEE_SP,
            lNewDefaultSwapFee
        );
        _pair.updateSwapFee();

        vm.expectEmit(true, true, false, false);
        emit PlatformFeeChanged(ConstantsLib.DEFAULT_PLATFORM_FEE, lNewDefaultPlatformFee);
        _pair.updatePlatformFee();

        // assert
        assertEq(_pair.swapFee(), lNewDefaultSwapFee);
        assertEq(_pair.platformFee(), lNewDefaultPlatformFee);
    }

    function testRecoverToken() public allPairs {
        // arrange
        uint256 lAmountToRecover = 1e18;
        _tokenC.mint(address(_pair), 1e18);

        // act
        _pair.recoverToken(address(_tokenC));

        // assert
        assertEq(_tokenC.balanceOf(address(_recoverer)), lAmountToRecover);
        assertEq(_tokenC.balanceOf(address(_pair)), 0);
    }
}
