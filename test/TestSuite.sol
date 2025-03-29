// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {POHMultiProviderHook} from "../src/POHHook.sol";
import {NomisSimulator} from "../src/POHService.sol";

contract POHMultiProviderHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Test accounts
    address public deployer = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public user3 = address(0x4);

    // Test parameters
    uint256 public constant HIGH_SCORE = 12000;
    uint256 public constant MEDIUM_SCORE = 9000;
    uint256 public constant LOW_SCORE = 5000;
    uint256 public constant MINIMUM_SCORE = 10000;

    // Core contracts
    NomisSimulator public nomisSimulator;
    POHMultiProviderHook public pohHook;

    // Test tokens
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    Currency public tokenACurrency;
    Currency public tokenBCurrency;

    // Pool details
    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        // Change to the deployer address before doing any setup
        vm.startPrank(deployer);

        // Deploy manager and routers
        deployFreshManagerAndRouters();

        // Deploy mock tokens
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);

        // Ensure tokenA address is less than tokenB for pool key creation
        if (address(tokenA) > address(tokenB)) {
            MockERC20 temp = tokenA;
            tokenA = tokenB;
            tokenB = temp;
        }

        // Wrap tokens in Currency
        tokenACurrency = Currency.wrap(address(tokenA));
        tokenBCurrency = Currency.wrap(address(tokenB));

        // Deploy Nomis simulator
        nomisSimulator = new NomisSimulator();

        // Create hook address with the correct flags
        // The flags must match the permissions in the POHMultiProviderHook contract
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        );

        // Compute a valid hook address with the required flags
        address hookAddr = address(flags);

        // Deploy the contract directly to this computed address using vm.deployCodeTo
        vm.etch(
            hookAddr,
            address(
                new POHMultiProviderHook(
                    IPoolManager(address(manager)),
                    nomisSimulator
                )
            ).code
        );

        // Now we can cast the deployed address to our contract type
        pohHook = POHMultiProviderHook(hookAddr);

        // Set up pool key with the correct hook address and parameters
        poolKey = PoolKey({
            currency0: tokenACurrency,
            currency1: tokenBCurrency,
            fee: 3000, // 0.3%
            tickSpacing: 60,
            hooks: IHooks(address(pohHook))
        });

        poolId = poolKey.toId();

        // Initialize pool with sqrt price 1:1
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Initialize dummy scores in Nomis simulator
        nomisSimulator.setScore(
            user1,
            HIGH_SCORE,
            pohHook.NOMIS_CALC_MODEL(),
            pohHook.ARBITRUM_BLOCKCHAIN_ID()
        );

        nomisSimulator.setScore(
            user2,
            MEDIUM_SCORE,
            pohHook.NOMIS_CALC_MODEL(),
            pohHook.ARBITRUM_BLOCKCHAIN_ID()
        );

        nomisSimulator.setScore(
            user3,
            LOW_SCORE,
            pohHook.NOMIS_CALC_MODEL(),
            pohHook.ARBITRUM_BLOCKCHAIN_ID()
        );

        // Mint test tokens to users
        tokenA.mint(user1, 1000 ether);
        tokenB.mint(user1, 1000 ether);
        tokenA.mint(user2, 1000 ether);
        tokenB.mint(user2, 1000 ether);
        tokenA.mint(user3, 1000 ether);
        tokenB.mint(user3, 1000 ether);

        // Add liquidity to the pool
        tokenA.mint(address(this), 1000 ether);
        tokenB.mint(address(this), 1000 ether);

        tokenA.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenB.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Add initial liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ""
        );

        vm.stopPrank();
    }

    /************************************************************
     *                  HELPER FUNCTIONS                         *
     ************************************************************/

    function modifyPOHConfiguration(
        bool isEnabled,
        uint256 minimumScore
    ) internal {
        vm.prank(deployer);
        pohHook.configurePOHForPool(poolKey, isEnabled, minimumScore);
    }

    function performSwap(
        address user,
        bool zeroForOne,
        int256 amountSpecified
    ) internal returns (BalanceDelta) {
        vm.startPrank(user);

        // Approve tokens for the hook
        if (zeroForOne) {
            tokenA.approve(address(pohHook), type(uint256).max);
        } else {
            tokenB.approve(address(pohHook), type(uint256).max);
        }

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = pohHook.swapWithPOHVerification(
            manager,
            poolKey,
            params
        );

        vm.stopPrank();
        return delta;
    }

    /************************************************************
     *                  TEST CASES                               *
     ************************************************************/

    // Test 1: Swap should succeed when POH verification is disabled
    function testSwapWithPOHVerificationDisabled() public {
        // Ensure POH verification is disabled (default)
        modifyPOHConfiguration(false, MINIMUM_SCORE);

        // Even low-score user should be able to swap
        BalanceDelta delta = performSwap(user3, true, 1 ether);

        // Verify swap was successful
        assert(delta.amount0() > 0 || delta.amount1() > 0);
    }

    // Test 2: Swap should succeed for user with high score when POH is enabled
    function testSwapWithHighScoreUser() public {
        // Enable POH verification with minimum score
        modifyPOHConfiguration(true, MINIMUM_SCORE);

        // User1 has HIGH_SCORE which is above MINIMUM_SCORE
        BalanceDelta delta = performSwap(user1, true, 1 ether);

        // Verify swap was successful
        assert(delta.amount0() > 0 || delta.amount1() > 0);
    }

    // Test 3: Swap should fail for user with medium score below threshold
    function testSwapWithMediumScoreUser() public {
        // Enable POH verification with minimum score
        modifyPOHConfiguration(true, MINIMUM_SCORE);

        // User2 has MEDIUM_SCORE which is below MINIMUM_SCORE
        vm.expectRevert(
            "POH: Swap initiator does not meet Nomis score requirement"
        );
        performSwap(user2, true, 1 ether);
    }

    // Test 4: Swap should fail for user with low score
    function testSwapWithLowScoreUser() public {
        // Enable POH verification with minimum score
        modifyPOHConfiguration(true, MINIMUM_SCORE);

        // User3 has LOW_SCORE which is well below MINIMUM_SCORE
        vm.expectRevert(
            "POH: Swap initiator does not meet Nomis score requirement"
        );
        performSwap(user3, true, 1 ether);
    }
}
