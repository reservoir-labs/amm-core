pragma solidity 0.8.13;

import "forge-std/Test.sol";

import { MintableERC20 } from "test/__fixtures/MintableERC20.sol";

import { GenericFactory } from "src/GenericFactory.sol";
import { ConstantProductPair } from "src/curve/constant-product/ConstantProductPair.sol";
import { StablePair, AmplificationData } from "src/curve/stable/StablePair.sol";

abstract contract BaseTest is Test {
    uint256 public constant INITIAL_MINT_AMOUNT = 100e18;

    GenericFactory  internal _factory       = new GenericFactory();

    address         internal _recoverer     = _makeAddress("recoverer");
    address         internal _platformFeeTo = _makeAddress("platformFeeTo");
    address         internal _alice         = _makeAddress("alice");

    MintableERC20   internal _tokenA        = new MintableERC20("TokenA", "TA");
    MintableERC20   internal _tokenB        = new MintableERC20("TokenB", "TB");
    MintableERC20   internal _tokenC        = new MintableERC20("TokenC", "TC");

    ConstantProductPair   internal _constantProductPair;
    StablePair      internal _stablePair;

    constructor()
    {
        // set shared variables
        _factory.set(keccak256("ConstantProductPair::platformFeeTo"), bytes32(uint256(uint160(_platformFeeTo))));
        _factory.set(keccak256("ConstantProductPair::swapFee"), bytes32(uint256(30)));
        _factory.set(keccak256("ConstantProductPair::platformFee"), bytes32(uint256(2500)));
        _factory.set(keccak256("ConstantProductPair::defaultRecoverer"), bytes32(uint256(uint160(_recoverer))));

        // add constant product curve
        _factory.addCurve(type(ConstantProductPair).creationCode);

        // add hybridpool curve
        _factory.addCurve(type(StablePair).creationCode);
        _factory.set(keccak256("ConstantProductPair::amplificationCoefficient"), bytes32(uint256(1000)));

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
}
