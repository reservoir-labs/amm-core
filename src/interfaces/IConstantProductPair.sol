pragma solidity 0.8.13;

import { IAssetManager } from "src/interfaces/IAssetManager.sol";
import { IAssetManagedPair } from "src/interfaces/IAssetManagedPair.sol";
import { GenericFactory } from "src/GenericFactory.sol";

interface IConstantProductPair is IAssetManagedPair {
    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    // solhint-disable-next-line func-name-mixedcase
    function MINIMUM_LIQUIDITY() external pure returns (uint);
    function factory() external view returns (GenericFactory);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function kLast() external view returns (uint224);

    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    function swapFee() external view returns (uint);
    function platformFee() external view returns (uint);
    function platformFeeOn() external view returns (bool);

    function setCustomSwapFee(uint _customSwapFee) external;
    function setCustomPlatformFee(uint _customPlatformFee) external;

    function assetManager() external returns (IAssetManager);
    function setManager(IAssetManager manager) external;
}
