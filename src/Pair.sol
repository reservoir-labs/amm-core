pragma solidity 0.8.13;

import "@openzeppelin/token/ERC20/IERC20.sol";

import { Bytes32Lib } from "src/libraries/Bytes32.sol";
import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";

import { IPair } from "src/interfaces/IPair.sol";

import { GenericFactory } from "src/GenericFactory.sol";
import { UniswapV2ERC20 } from "src/UniswapV2ERC20.sol";

abstract contract Pair is IPair, UniswapV2ERC20 {
    using FactoryStoreLib for GenericFactory;
    using Bytes32Lib for bytes32;

    bytes4 private constant SELECTOR        = bytes4(keccak256("transfer(address,uint256)"));
    uint public constant MINIMUM_LIQUIDITY  = 10**3;

    uint256 public constant FEE_ACCURACY  = 1_000_000; // 100%
    uint public constant MAX_PLATFORM_FEE = 500_000;   //  50%
    uint public constant MAX_SWAP_FEE     = 20_000;    //   2%

    GenericFactory public immutable factory;
    address public immutable token0;
    address public immutable token1;

    uint112 internal reserve0;
    uint112 internal reserve1;
    uint32  internal blockTimestampLast;

    uint public swapFee;
    uint public customSwapFee = type(uint).max;

    uint public platformFee;
    uint public customPlatformFee = type(uint).max;

    modifier onlyFactory() {
        require(msg.sender == address(factory), "P: FORBIDDEN");
        _;
    }

    constructor(address aToken0, address aToken1) {
        factory = GenericFactory(msg.sender);
        token0  = aToken0;
        token1  = aToken1;

        swapFee = uint256(factory.get(keccak256("ConstantProductPair::swapFee")));
        platformFee = uint256(factory.get(keccak256("ConstantProductPair::platformFee")));

        require(_swapFee <= MAX_SWAP_FEE, "P: INVALID_SWAP_FEE");
        require(_platformFee <= MAX_PLATFORM_FEE, "P: INVALID_PLATFORM_FEE");
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function setCustomSwapFee(uint _customSwapFee) external onlyFactory {
        // we assume the factory won't spam events, so no early check & return
        emit CustomSwapFeeChanged(customSwapFee, _customSwapFee);
        customSwapFee = _customSwapFee;

        updateSwapFee();
    }

    function setCustomPlatformFee(uint _customPlatformFee) external onlyFactory {
        emit CustomPlatformFeeChanged(customPlatformFee, _customPlatformFee);
        customPlatformFee = _customPlatformFee;

        updatePlatformFee();
    }

    function updateSwapFee() public {
        uint256 _swapFee = customSwapFee != type(uint).max
            ? customSwapFee
            : uint256(factory.get(keccak256("ConstantProductPair::swapFee")));
        if (_swapFee == swapFee) { return; }

        require(_swapFee <= MAX_SWAP_FEE, "P: INVALID_SWAP_FEE");

        emit SwapFeeChanged(swapFee, _swapFee);
        swapFee = _swapFee;
    }

    function updatePlatformFee() public {
        uint256 _platformFee = customPlatformFee != type(uint).max
            ? customPlatformFee
            : uint256(factory.get(keccak256("ConstantProductPair::platformFee")));
        if (_platformFee == platformFee) { return; }

        require(_platformFee <= MAX_PLATFORM_FEE, "P: INVALID_PLATFORM_FEE");

        emit PlatformFeeChanged(platformFee, _platformFee);
        platformFee = _platformFee;
    }

    function recoverToken(address token) external {
        address _recoverer = address(uint160(uint256(factory.get(keccak256("ConstantProductPair::defaultRecoverer")))));
        require(token != token0, "P: INVALID_TOKEN_TO_RECOVER");
        require(token != token1, "P: INVALID_TOKEN_TO_RECOVER");
        require(_recoverer != address(0), "P: RECOVERER_ZERO_ADDRESS");

        uint _amountToRecover = IERC20(token).balanceOf(address(this));

        _safeTransfer(token, _recoverer, _amountToRecover);
    }

    function _safeTransfer(address token, address to, uint value) internal {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "P: TRANSFER_FAILED");
    }

    function _update(uint256 aTotalToken0, uint256 aTotalToken1, uint112 aReserve0, uint112 aReserve1) internal virtual;
}
