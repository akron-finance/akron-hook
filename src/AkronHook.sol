// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {IUniswapV2Pair} from "./interfaces/external/IUniswapV2Pair.sol";
import {IWETH} from "./interfaces/external/IWETH.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

contract AkronHook is BaseHook {
    using Hooks for IHooks;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    
    /// @notice Thrown when trying to interact with a non-initialized pool
    error MustAddLiquidityToAkronswap();

    IPoolManager public immutable manager;
    address public immutable factory;
    address public immutable WETH;

    constructor(IPoolManager _manager, address _factory, address _WETH) BaseHook(_manager) {
        manager = _manager;
        factory = _factory;
        WETH = _WETH;
    }

    modifier onlyManager() {
        require(msg.sender == address(manager));
        _;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
    
    struct StepComputations {
        bool exactInput;
        bool specifiedTokenIs0;
        Currency specified;
        Currency unspecified;
        uint256 specifiedAmount;
        uint256 unspecifiedAmount;
        address pair;
        uint112 _reserve0;
        uint112 _reserve1;
        BeforeSwapDelta returnDelta;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        StepComputations memory step;
        step.exactInput = params.amountSpecified < 0;
        step.specifiedTokenIs0 = (step.exactInput == params.zeroForOne);
        (step.specified, step.unspecified) =
            step.specifiedTokenIs0 ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        step.specifiedAmount = step.exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        step.pair = _pairFor(
            Currency.unwrap(key.currency0.isNative() ? Currency.wrap(WETH) : key.currency0), Currency.unwrap(key.currency1)
        );
        (step._reserve0, step._reserve1, ) = IUniswapV2Pair(step.pair).getReserves();
        
        if (step.exactInput) {
            // in exact-input swaps, the specified token is a debt that gets paid down by the swapper
            // the unspecified token is credited to the PoolManager, that is claimed by the swapper
            if (step.specifiedTokenIs0) {
                step.unspecifiedAmount = _getAmountOut(step.specifiedAmount, uint256(step._reserve0), uint256(step._reserve1));
                _take(step.specified, step.pair, step.specifiedAmount);
                IUniswapV2Pair(step.pair).swap(0, step.unspecifiedAmount, address(this), new bytes(0));
                manager.sync(step.unspecified);
                IERC20Minimal(Currency.unwrap(step.unspecified)).transfer(address(manager), step.unspecifiedAmount);
                manager.settle();
            } else {
                step.unspecifiedAmount = _getAmountOut(step.specifiedAmount, uint256(step._reserve1), uint256(step._reserve0));
                manager.take(step.specified, step.pair, step.specifiedAmount);
                IUniswapV2Pair(step.pair).swap(step.unspecifiedAmount, 0, address(this), new bytes(0));
                _settle(step.unspecified, step.unspecifiedAmount);
            }
            step.returnDelta = toBeforeSwapDelta(step.specifiedAmount.toInt128(), -step.unspecifiedAmount.toInt128());
        } else {
            // in exact-output swaps, the unspecified token is a debt that gets paid down by the swapper
            // the specified token is credited to the PoolManager, that is claimed by the swapper
            if (step.specifiedTokenIs0) {
                step.unspecifiedAmount = _getAmountIn(step.specifiedAmount, uint256(step._reserve1), uint256(step._reserve0));
                manager.take(step.unspecified, step.pair, step.unspecifiedAmount);
                IUniswapV2Pair(step.pair).swap(step.specifiedAmount, 0, address(this), new bytes(0));
                _settle(step.specified, step.specifiedAmount);
            } else {
                step.unspecifiedAmount = _getAmountIn(step.specifiedAmount, uint256(step._reserve0), uint256(step._reserve1));
                _take(step.unspecified, step.pair, step.unspecifiedAmount);
                IUniswapV2Pair(step.pair).swap(0, step.specifiedAmount, address(this), new bytes(0));
                manager.sync(step.specified);
                IERC20Minimal(Currency.unwrap(step.specified)).transfer(address(manager), step.specifiedAmount);
                manager.settle();
            }
            
            step.returnDelta = toBeforeSwapDelta(-step.specifiedAmount.toInt128(), step.unspecifiedAmount.toInt128());
        }
        
        return (BaseHook.beforeSwap.selector, step.returnDelta, 0);

    }


    function beforeAddLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata
    ) external view override onlyPoolManager returns (bytes4) {
        revert MustAddLiquidityToAkronswap();
    }


    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint amountOut) {
        amountOut = reserveOut * amountIn / ((amountIn * 2) + reserveIn);
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function _getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint amountIn) {
        amountIn = (reserveIn * amountOut / (reserveOut - (amountOut * 2))) + 1;
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function _pairFor(address tokenA, address tokenB) internal view returns (address pair) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair = address(uint160(uint256((keccak256(abi.encodePacked(
                hex'ff',
                factory,
                keccak256(abi.encodePacked(token0, token1)),
                hex'207e00cb099b76f581c479b9e20c11280ed52e93ab7003d58600ec82fb71b23b' // init code hash 
            ))))));
    }

    function _settle(Currency currency, uint256 amount) internal {
        // for native currencies, calling sync is not required
        if (currency.isNative()) {
            manager.settle{value: amount}();
        } else {
            manager.sync(currency);
            IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), amount);
            manager.settle();
        }
    }

    function _take(Currency currency, address recipient, uint256 amount) internal {
        if (currency.isNative()) {
            manager.take(currency, address(this), amount);
            IWETH(WETH).deposit{value: amount}();
            IWETH(WETH).transfer(Currency.unwrap(currency), amount);
        } else {
            manager.take(currency, recipient, amount);
        }
    }

    receive() external payable {}
}
