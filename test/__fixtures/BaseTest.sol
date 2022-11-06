pragma solidity 0.8.13;

import "forge-std/Test.sol";

import { MintableERC20 } from "test/__fixtures/MintableERC20.sol";

import { GenericFactory } from "src/GenericFactory.sol";
import { ReservoirPair } from "src/ReservoirPair.sol";
import { ConstantProductPair } from "src/curve/constant-product/ConstantProductPair.sol";
import { StablePair, AmplificationData } from "src/curve/stable/StablePair.sol";

abstract contract BaseTest is Test {
    uint256 public constant INITIAL_MINT_AMOUNT = 100e18;
    uint256 public constant DEFAULT_SWAP_FEE_CP = 3_000;
    uint256 public constant DEFAULT_SWAP_FEE_SP = 100;
    uint256 public constant DEFAULT_PLATFORM_FEE = 250_000;
    uint256 public constant DEFAULT_AMP_COEFF   = 1_000;
    uint256 public constant DEFAULT_ALLOWED_CHANGE_PER_SECOND = 0.0005e18;

    GenericFactory  internal _factory       = new GenericFactory();

    address         internal _recoverer     = _makeAddress("recoverer");
    address         internal _platformFeeTo = _makeAddress("platformFeeTo");
    address         internal _alice         = _makeAddress("alice");
    address         internal _bob           = _makeAddress("bob");
    address         internal _cal           = _makeAddress("cal");

    MintableERC20   internal _tokenA        = new MintableERC20("TokenA", "TA", 18);
    MintableERC20   internal _tokenB        = new MintableERC20("TokenB", "TB", 18);
    MintableERC20   internal _tokenC        = new MintableERC20("TokenC", "TC", 18);
    MintableERC20   internal _tokenD        = new MintableERC20("TokenD", "TD", 6);
    MintableERC20   internal _tokenE        = new MintableERC20("TokenF", "TF", 25);

    ConstantProductPair   internal _constantProductPair;
    StablePair            internal _stablePair;

    constructor()
    {
        // set shared variables
        _factory.set(keccak256("Shared::platformFee"), bytes32(uint256(DEFAULT_PLATFORM_FEE))); // 25%
        _factory.set(keccak256("Shared::platformFeeTo"), bytes32(uint256(uint160(_platformFeeTo))));
        _factory.set(keccak256("Shared::defaultRecoverer"), bytes32(uint256(uint160(_recoverer))));
        _factory.set(keccak256("Shared::allowedChangePerSecond"), bytes32(DEFAULT_ALLOWED_CHANGE_PER_SECOND));

        // add constant product curve
        _factory.addCurve(type(ConstantProductPair).creationCode);
        _factory.set(keccak256("CP::swapFee"), bytes32(uint256(DEFAULT_SWAP_FEE_CP))); // 0.3%

        // add stable curve
        _factory.addCurve(type(StablePair).creationCode);
        _factory.set(keccak256("SP::swapFee"), bytes32(uint256(DEFAULT_SWAP_FEE_SP))); // 0.01%
        _factory.set(keccak256("SP::amplificationCoefficient"), bytes32(uint256(DEFAULT_AMP_COEFF)));

        // initial mint
        _constantProductPair = ConstantProductPair(_createPair(address(_tokenA), address(_tokenB), 0));
        _tokenA.mint(address(_constantProductPair), INITIAL_MINT_AMOUNT);
        _tokenB.mint(address(_constantProductPair), INITIAL_MINT_AMOUNT);
        _constantProductPair.mint(_alice);

        _stablePair = StablePair(_createPair(address(_tokenA), address(_tokenB), 1));
        _tokenA.mint(address(_stablePair), INITIAL_MINT_AMOUNT);
        _tokenB.mint(address(_stablePair), INITIAL_MINT_AMOUNT);
        _stablePair.mint(_alice);
    }

    function _makeAddress(string memory aName) internal returns (address)
    {
        address lAddress = address(
            uint160(uint256(
                keccak256(abi.encodePacked(aName))
            ))
        );
        vm.label(lAddress, aName);

        return lAddress;
    }

    function _createPair(address aTokenA, address aTokenB, uint256 aCurveId) internal returns (address rPair)
    {
        rPair = _factory.createPair(aTokenA, aTokenB, aCurveId);
    }

    function _stepTime(uint256 aTime) internal
    {
        vm.roll(block.number + 1);
        skip(aTime);
    }

    function _writeObservation(
        ReservoirPair aPair,
        uint256 aIndex,
        int112 aRawPrice,
        int56 aClampedPrice,
        int56 aLiq,
        uint32 aTime
    ) internal
    {
        bytes32 lEncoded = bytes32(
            bytes.concat(
                bytes4(aTime),
                bytes7(uint56(aLiq)),
                bytes7(uint56(aClampedPrice)),
                bytes14(uint112(aRawPrice))
            )
        );

        vm.record();
        aPair.observations(aIndex);
        (bytes32[] memory lAccesses, ) = vm.accesses(address(aPair));
        require(lAccesses.length == 1, "invalid number of accesses");

        vm.store(address(aPair), lAccesses[0], lEncoded);
    }
}
