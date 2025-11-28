// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {AVAVault} from "../src/AVAVault.sol";
import {ERC20} from "../lib/solmate/src/tokens/ERC20.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {AAVEStrategy as MockStrategy} from "../src/Stratagies/AAVEStrategy.sol";
import {MockWAVAX} from "../src/Mocks/MockWAVAX.sol";
// ---------------------------------------------------------
// MOCKS
// ---------------------------------------------------------

// contract MockWAVAX is ERC20 {
//     constructor() ERC20("Wrapped AVAX", "WAVAX", 18) {}
//     function mint(address to, uint256 amount) external {
//         _mint(to, amount);
//     }
// }

// contract MockStrategy is IStrategy {
//     ERC20 public immutable assetToken;
//     address public immutable vault;

//     constructor(address _asset, address _vault) {
//         assetToken = ERC20(_asset);
//         vault = _vault;
//     }

//     function asset() external view returns (address) {
//         return address(assetToken);
//     }

//     function deposit(uint256 amount) external {
//         require(msg.sender == vault, "Only vault");
//         assetToken.transferFrom(msg.sender, address(this), amount);
//     }

//     function withdraw(uint256 amount) external {
//         require(msg.sender == vault, "Only vault");
//         assetToken.transfer(vault, amount);
//     }

//     function balance() external view returns (uint256) {
//         return assetToken.balanceOf(address(this));
//     }
// }

// ---------------------------------------------------------
// TEST SUITE
// ---------------------------------------------------------

contract AVAXVaultTest is Test {
    AVAVault public vault;
    MockWAVAX public wavax;
    MockStrategy public strategy1;
    MockStrategy public strategy2;
    MockStrategy public strategy3;

    address public owner = address(this);
    address public user = address(0x1);
    address public attacker = address(0xBAD);

    function setUp() public {
        wavax = new MockWAVAX();
        
        vault = new AVAVault(
            ERC20(address(wavax)), 
            "Liquid Staked AVAX", 
            "lsAVAX"
        );

        strategy1 = new MockStrategy(address(wavax), address(vault));
        strategy2 = new MockStrategy(address(wavax), address(vault));
        strategy3 = new MockStrategy(address(wavax), address(vault));

        wavax.mint(user, 1000 ether);
        wavax.mint(attacker, 1000 ether);

        vm.label(user, "User");
        vm.label(attacker, "Attacker");
        vm.label(address(vault), "Vault");
        vm.label(address(strategy1), "Strat 1");
        vm.label(address(strategy2), "Strat 2");
    }

    // =========================================================
    // 1. ACCESS CONTROL TESTS
    // =========================================================

    function test_AccessControl_AddStrategy() public {
        vm.prank(attacker);
        vm.expectRevert("NOT_OWNER");
        vault.addStrategy(strategy1);
    }

    function test_AccessControl_RemoveStrategy() public {
        vault.addStrategy(strategy1);
        
        vm.prank(attacker);
        vm.expectRevert("NOT_OWNER");
        vault.removeStrategy(strategy1);
    }

    function test_AccessControl_UpdateActiveStrategy() public {
        vault.addStrategy(strategy1);

        vm.prank(attacker);
        vm.expectRevert("NOT_OWNER");
        vault.updateActiveStrategy(strategy1);
    }

    function test_AccessControl_Rebalance() public {
        vault.addStrategy(strategy1);
        
        IStrategy[] memory targets = new IStrategy[](1);
        targets[0] = strategy1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        vm.prank(attacker);
        vm.expectRevert("NOT_OWNER");
        vault.rebalance(targets, amounts);
    }

    // =========================================================
    // 2. STRATEGY MANAGEMENT EDGE CASES
    // =========================================================

    function test_CannotAddDuplicateStrategy() public {
        vault.addStrategy(strategy1);
        vm.expectRevert("ALREADY_REGISTERED");
        vault.addStrategy(strategy1);
    }

    function test_CannotAddZeroAddressStrategy() public {
        vm.expectRevert("ZERO_ADDRESS");
        vault.addStrategy(IStrategy(address(0)));
    }

    function test_CannotAddWrongAssetStrategy() public {
        // Create strategy with different asset
        MockWAVAX otherToken = new MockWAVAX();
        MockStrategy wrongStrat = new MockStrategy(address(otherToken), address(vault));
        
        vm.expectRevert("INVALID_ASSET");
        vault.addStrategy(wrongStrat);
    }

    function test_RemoveStrategy_PullsFundsAndResetsActive() public {
        vault.addStrategy(strategy1);
        vault.updateActiveStrategy(strategy1);

        // User deposits
        vm.startPrank(user);
        wavax.approve(address(vault), 100 ether);
        vault.deposit(100 ether, user);
        vm.stopPrank();

        assertEq(strategy1.balance(), 100 ether);

        // Remove the strategy
        vault.removeStrategy(strategy1);

        // Checks:
        // 1. Funds should be back in Vault (Idle)
        assertEq(wavax.balanceOf(address(vault)), 100 ether);
        assertEq(strategy1.balance(), 0);
        
        // 2. Active Strategy should be 0x0
        assertEq(address(vault.activeStrategy()), address(0));
        
        // 3. Strategy should be marked unregistered
        assertFalse(vault.isStrategy(address(strategy1)));
    }

    function test_UpdateActiveStrategy_MustBeRegistered() public {
        // Try to set strategy1 as active without adding it first
        vm.expectRevert("NOT_REGISTERED");
        vault.updateActiveStrategy(strategy1);
    }

    // =========================================================
    // 3. LIFO WITHDRAWAL LOGIC (COMPLEX)
    // =========================================================

    function test_Withdrawal_LIFO_Order() public {
        // Register 2 strategies
        vault.addStrategy(strategy1);
        vault.addStrategy(strategy2);

        // 1. Deposit 100 into Strat 1
        vault.updateActiveStrategy(strategy1);
        vm.startPrank(user);
        wavax.approve(address(vault), 300 ether);
        vault.deposit(100 ether, user);
        
        // 2. Deposit 200 into Strat 2
        vm.stopPrank();
        vault.updateActiveStrategy(strategy2);
        vm.prank(user);
        vault.deposit(200 ether, user);

        // State Check: S1=100, S2=200, Total=300
        assertEq(strategy1.balance(), 100 ether);
        assertEq(strategy2.balance(), 200 ether);

        // 3. Withdraw 250
        // Expected Logic: 
        // - Vault has 0 float.
        // - Check S2 (latest): Has 200. Take all 200. Needed = 50.
        // - Check S1 (previous): Has 100. Take 50. Needed = 0.
        vm.prank(user);
        vault.withdraw(250 ether, user, user);

        // Checks
        assertEq(strategy2.balance(), 0, "Strategy 2 should be empty");
        assertEq(strategy1.balance(), 50 ether, "Strategy 1 should have remainder");
        assertEq(wavax.balanceOf(user), 950 ether); // Started with 1000, dep 300, with 250
    }

    function test_Withdrawal_SkipsEmptyStrategies() public {
        vault.addStrategy(strategy1);
        vault.addStrategy(strategy2); // Empty strategy in the middle
        vault.addStrategy(strategy3);

        // Deposit into Strat 1 and Strat 3
        vault.updateActiveStrategy(strategy1);
        vm.startPrank(user);
        wavax.approve(address(vault), 200 ether);
        vault.deposit(100 ether, user);
        vm.stopPrank();

        vault.updateActiveStrategy(strategy3);
        vm.prank(user);
        vault.deposit(100 ether, user);

        // State: S1=100, S2=0, S3=100
        
        // Withdraw 150
        // Should drain S3 (100), skip S2 (0), take 50 from S1
        vm.prank(user);
        vault.withdraw(150 ether, user, user);

        assertEq(strategy3.balance(), 0);
        assertEq(strategy2.balance(), 0);
        assertEq(strategy1.balance(), 50 ether);
    }

    // =========================================================
    // 4. REBALANCE EDGE CASES
    // =========================================================

    function test_Rebalance_Validation() public {
        vault.addStrategy(strategy1);
        
        IStrategy[] memory targets = new IStrategy[](1);
        targets[0] = strategy1;
        uint256[] memory amounts = new uint256[](0); // Mismatch length

        vm.expectRevert("ARRAY_LENGTH_MISMATCH");
        vault.rebalance(targets, amounts);
    }

    function test_Rebalance_InsufficientFunds() public {
        vault.addStrategy(strategy1);
        // Vault has 0 funds
        
        IStrategy[] memory targets = new IStrategy[](1);
        targets[0] = strategy1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 ether; // Trying to allocate 100 when we have 0

        vm.expectRevert("INSUFFICIENT_FUNDS_FOR_REBALANCE");
        vault.rebalance(targets, amounts);
    }

    function test_Rebalance_UnregisteredTarget() public {
        // Strategy 1 is registered, Strategy 2 is NOT
        vault.addStrategy(strategy1);
        
        // Fund the vault
        vm.startPrank(user);
        wavax.approve(address(vault), 100 ether);
        vault.deposit(100 ether, user); // Funds go to Active (or idle if none active)
        vm.stopPrank();

        IStrategy[] memory targets = new IStrategy[](1);
        targets[0] = strategy2; // Unregistered
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 ether;

        vm.expectRevert("TARGET_NOT_REGISTERED");
        vault.rebalance(targets, amounts);
    }

    function test_Rebalance_LeavesRemainderInVault() public {
        vault.addStrategy(strategy1);
        vault.updateActiveStrategy(strategy1);

        // Deposit 100
        vm.startPrank(user);
        wavax.approve(address(vault), 100 ether);
        vault.deposit(100 ether, user);
        vm.stopPrank();

        // Rebalance: only allocate 80 back to Strategy 1
        IStrategy[] memory targets = new IStrategy[](1);
        targets[0] = strategy1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 80 ether;

        vault.rebalance(targets, amounts);

        // Check:
        // Strategy has 80
        assertEq(strategy1.balance(), 80 ether);
        // Vault has 20 (Float)
        assertEq(wavax.balanceOf(address(vault)), 20 ether);
        // Total assets still 100
        assertEq(vault.totalAssets(), 100 ether);
    }

    // =========================================================
    // 5. MISC / ZERO CHECKS
    // =========================================================

    function test_DepositZero() public {
        // ERC4626 standard usually reverts or allows 0 shares. 
        // Your implementation: require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");
        vm.startPrank(user);
        wavax.approve(address(vault), 0);
        
        vm.expectRevert("ZERO_SHARES");
        vault.deposit(0, user);
        vm.stopPrank();
    }
    
    function test_WithdrawWithInsufficientLiquidity() public {
        // User deposits 100
        vault.addStrategy(strategy1);
        vault.updateActiveStrategy(strategy1);
        
        vm.startPrank(user);
        wavax.approve(address(vault), 100 ether);
        vault.deposit(100 ether, user);
        vm.stopPrank();

        // Simulate strategy somehow losing funds (slashing/hack)
        // Or simply trying to withdraw more than exists
        // Here we try to withdraw 101 shares (costing 101 assets)
        // But user only has 100 shares. 
        // Note: standard ERC20 burn will fail first, but let's test liquidity logic
        
        // We simulate a state where user HAS shares, but underlying is gone.
        // Manually burn funds from strategy to simulate loss
        vm.prank(address(strategy1));
        wavax.transfer(address(0xdead), 50 ether); 
        
        // Now total assets = 50. User has 100 shares.
        // User tries to redeem 100 shares (expecting 50 assets back).
        // This should actually work because redeem calculates assets based on current totalAssets.
        vm.prank(user);
        vault.redeem(100 ether, user, user);
        
        assertEq(wavax.balanceOf(user), 950 ether); // 1000 - 100 + 50
    }
}