pragma solidity 0.8.13;

import "forge-std/Test.sol";

import { MintableERC20 } from "test/__fixtures/MintableERC20.sol";

import { GenericFactory } from "src/GenericFactory.sol";
import { UniswapV2Pair } from "src/curve/constant-product/UniswapV2Pair.sol";
import { HybridPool, AmplificationData } from "src/curve/stable/HybridPool.sol";
import { AssetManager } from "src/asset-manager/AssetManager.sol";

abstract contract BaseTest is Test {
    address public constant ETH_MAINNET_COMPOUND_COMPTROLLER = address(0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B);

    uint256 public constant INITIAL_MINT_AMOUNT = 100e18;

    GenericFactory internal _factory = new GenericFactory();
    AssetManager internal _manager = new AssetManager(ETH_MAINNET_COMPOUND_COMPTROLLER);

    address internal _recoverer = _makeAddress("recoverer");
    address internal _alice     = _makeAddress("alice");

    MintableERC20 internal _tokenA = new MintableERC20("TokenA", "TA");
    MintableERC20 internal _tokenB = new MintableERC20("TokenB", "TB");
    MintableERC20 internal _tokenC = new MintableERC20("TokenC", "TC");

    UniswapV2Pair internal _uniswapV2Pair;

    constructor()
    {
        // set shared variables
        _factory.set(keccak256("UniswapV2Pair::swapFee"), bytes32(uint256(30)));
        _factory.set(keccak256("UniswapV2Pair::platformFee"), bytes32(uint256(2500)));
        _factory.set(keccak256("UniswapV2Pair::defaultRecoverer"), bytes32(uint256(uint160(_recoverer))));

        // add constant product curve
        _factory.addCurve(type(UniswapV2Pair).creationCode);

        // add hybridpool curve
        _factory.addCurve(type(HybridPool).creationCode);
        _factory.set(keccak256("UniswapV2Pair::amplificationCoefficient"), bytes32(uint256(1000)));

        // initial mint
        _uniswapV2Pair = _createPair(_tokenA, _tokenB);
        _tokenA.mint(address(_uniswapV2Pair), INITIAL_MINT_AMOUNT);
        _tokenB.mint(address(_uniswapV2Pair), INITIAL_MINT_AMOUNT);
        _uniswapV2Pair.mint(_alice);
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

    function _createPair(MintableERC20 aTokenA, MintableERC20 aTokenB) private returns (UniswapV2Pair rPair)
    {
        rPair = UniswapV2Pair(_factory.createPair(address(aTokenA), address(aTokenB), 0));
    }
}
