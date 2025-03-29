// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

// Nomis Simulator Contract
contract NomisSimulator is ERC721 {
    struct ScoreEntry {
        uint256 score;
        uint16 calcModel;
        uint256 chainId;
    }

    mapping(address => ScoreEntry) public addressScores;
    uint256 private _tokenIdCounter;

    constructor() ERC721("NomisSimulator", "NOMIS") {}

    function setScore(
        address user,
        uint256 score,
        uint16 calcModel,
        uint256 chainId
    ) external {
        addressScores[user] = ScoreEntry({
            score: score,
            calcModel: calcModel,
            chainId: chainId
        });

        // Mint a token to the user for tracking
        _tokenIdCounter++;
        _safeMint(user, _tokenIdCounter);
    }

    function getScore(
        address addr,
        uint256 blockchainId,
        uint16 calcModel
    ) external view returns (uint256) {
        ScoreEntry memory entry = addressScores[addr];

        // Validate parameters
        require(
            entry.chainId == blockchainId && entry.calcModel == calcModel,
            "Invalid score parameters"
        );

        return entry.score;
    }
}

contract POHMultiProviderHook is BaseHook {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    // Nomis Simulator Contract
    NomisSimulator public nomisSimulator;

    // Hardcoded Arbitrum chain-specific parameters
    uint256 public constant ARBITRUM_BLOCKCHAIN_ID = 11101011;
    uint16 public constant NOMIS_CALC_MODEL = 12;

    // Enum to represent providers
    enum POHProvider {
        NOMIS
    }

    // Struct to define POH configuration for a pool
    struct POHConfig {
        bool isEnabled;
        uint256 minimumNomisScore;
    }

    // Mapping of pool configurations
    mapping(PoolId => POHConfig) public poolConfigurations;

    constructor(
        IPoolManager _poolManager,
        NomisSimulator _nomisSimulator
    ) BaseHook(_poolManager) {
        nomisSimulator = _nomisSimulator;
    }

    // Hook permissions with detailed configuration
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // Updated: Use _beforeInitialize with internal override
    function _beforeInitialize(
        address, // sender
        PoolKey calldata key,
        uint160 // sqrtPriceX96
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();

        // Default configuration - disabled
        poolConfigurations[poolId] = POHConfig({
            isEnabled: false,
            minimumNomisScore: 50 // Example minimum score
        });

        return BaseHook.beforeInitialize.selector;
    }

    // Updated: Use _beforeSwap with internal override and added view modifier
    function _beforeSwap(
        address, // sender
        PoolKey calldata key,
        IPoolManager.SwapParams calldata, // params
        bytes calldata hookData
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        POHConfig memory config = poolConfigurations[poolId];

        // Skip if POH verification is disabled
        if (!config.isEnabled) {
            return (
                BaseHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }

        // Extract the swap initiator from hookData
        address swapInitiator = abi.decode(hookData, (address));

        // Nomis Score Verification
        uint256 nomisScore = nomisSimulator.getScore(
            swapInitiator,
            ARBITRUM_BLOCKCHAIN_ID,
            NOMIS_CALC_MODEL
        );

        require(
            nomisScore >= config.minimumNomisScore,
            "POH: Swap initiator does not meet Nomis score requirement"
        );

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    // Configuration function remains unchanged
    function configurePOHForPool(
        PoolKey calldata key,
        bool isEnabled,
        uint256 minimumNomisScore
    ) external {
        PoolId poolId = key.toId();

        poolConfigurations[poolId] = POHConfig({
            isEnabled: isEnabled,
            minimumNomisScore: minimumNomisScore
        });
    }

    // Wrapper function for swap with POH verification remains unchanged
    function swapWithPOHVerification(
        IPoolManager poolManager,
        PoolKey calldata key,
        IPoolManager.SwapParams memory params
    ) external returns (BalanceDelta) {
        // Encode the actual swap initiator (msg.sender) as hookData
        bytes memory hookData = abi.encode(msg.sender);

        return poolManager.swap(key, params, hookData);
    }
}
