pragma solidity 0.8.13;

import { GenericFactory } from "src/GenericFactory.sol";

interface IConstantProductPair {
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
}
