pragma solidity 0.8.13;

import { ERC20 } from "@openzeppelin/token/ERC20/ERC20.sol";

import { Bytes32Lib } from "src/libraries/Bytes32.sol";
import { FactoryStoreLib } from "src/libraries/FactoryStore.sol";

import { IPair } from "src/interfaces/IPair.sol";

import { GenericFactory } from "src/GenericFactory.sol";
import { UniswapV2ERC20 } from "src/UniswapV2ERC20.sol";

abstract contract Pair is IPair, UniswapV2ERC20 {
    using FactoryStoreLib for GenericFactory;
    using Bytes32Lib for bytes32;

    string  internal    constant PLATFORM_FEE_TO_NAME   = "Shared::platformFeeTo";
    string  private     constant PLATFORM_FEE_NAME      = "Shared::platformFee";
    string  private     constant RECOVERER_NAME         = "Shared::defaultRecoverer";
    bytes4  private     constant SELECTOR               = bytes4(keccak256("transfer(address,uint256)"));

    uint256 public constant MINIMUM_LIQUIDITY   = 10**3;
    uint256 public constant FEE_ACCURACY        = 1_000_000;  // 100%
    uint256 public constant MAX_PLATFORM_FEE    = 500_000;    //  50%
    uint256 public constant MAX_SWAP_FEE        = 20_000;     //   2%

    GenericFactory public immutable factory;
    address public immutable token0;
    address public immutable token1;

    /// @dev Multipliers for each pooled token's precision to get to POOL_PRECISION_DECIMALS.
    /// For example, TBTC has 18 decimals, so the multiplier should be 1. WBTC
    /// has 8, so the multiplier should be 10 ** 18 / 10 ** 8 => 10 ** 10.
    // perf: can we use a smaller type?
    uint128 internal immutable token0PrecisionMultiplier;
    uint128 internal immutable token1PrecisionMultiplier;

    uint112 internal reserve0;
    uint112 internal reserve1;
    uint32  internal blockTimestampLast;

    uint public swapFee;
    uint public customSwapFee = type(uint).max;
    bytes32 internal immutable swapFeeName;

    uint public platformFee;
    uint public customPlatformFee = type(uint).max;

    modifier onlyFactory() {
        require(msg.sender == address(factory), "P: FORBIDDEN");
        _;
    }

    constructor(address aToken0, address aToken1, string memory aSwapFeeName) {
        factory = GenericFactory(msg.sender);
        token0  = aToken0;
        token1  = aToken1;

        swapFeeName = keccak256(abi.encodePacked(aSwapFeeName));
        swapFee     = factory.get(swapFeeName).toUint256();
        platformFee = factory.read(PLATFORM_FEE_NAME).toUint256();

        token0PrecisionMultiplier = uint128(10)**(18 - ERC20(aToken0).decimals());
        token1PrecisionMultiplier = uint128(10)**(18 - ERC20(aToken1).decimals());

        require(swapFee <= MAX_SWAP_FEE, "P: INVALID_SWAP_FEE");
        require(platformFee <= MAX_PLATFORM_FEE, "P: INVALID_PLATFORM_FEE");
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
            : factory.get(swapFeeName).toUint256();
        if (_swapFee == swapFee) { return; }

        require(_swapFee <= MAX_SWAP_FEE, "P: INVALID_SWAP_FEE");

        emit SwapFeeChanged(swapFee, _swapFee);
        swapFee = _swapFee;
    }

    function updatePlatformFee() public {
        uint256 _platformFee = customPlatformFee != type(uint).max
            ? customPlatformFee
            : factory.read(PLATFORM_FEE_NAME).toUint256();
        if (_platformFee == platformFee) { return; }

        require(_platformFee <= MAX_PLATFORM_FEE, "P: INVALID_PLATFORM_FEE");

        emit PlatformFeeChanged(platformFee, _platformFee);
        platformFee = _platformFee;
    }

    function recoverToken(address token) external {
        address _recoverer = factory.read(RECOVERER_NAME).toAddress();
        require(token != token0, "P: INVALID_TOKEN_TO_RECOVER");
        require(token != token1, "P: INVALID_TOKEN_TO_RECOVER");
        require(_recoverer != address(0), "P: RECOVERER_ZERO_ADDRESS");

        uint _amountToRecover = ERC20(token).balanceOf(address(this));

        _safeTransfer(token, _recoverer, _amountToRecover);
    }

    function _safeTransfer(address token, address to, uint value) internal returns (bool) {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        return success && (data.length == 0 || abi.decode(data, (bool)));
    }

    function _update(uint256 aTotalToken0, uint256 aTotalToken1, uint112 aReserve0, uint112 aReserve1) internal virtual;
}
