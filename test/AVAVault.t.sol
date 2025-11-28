// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AVAVault} from "../src/AVAVault.sol";
import {MockWAVAX} from "../src/Mocks/MockWAVAX.sol";
import {AAVEStrategy} from "../src/Stratagies/AAVEStrategy.sol";
import {ERC20} from "../lib/solmate/src/tokens/ERC20.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";

contract AVAXVaultTest is Test {
    AVAVault public vault;
    MockWAVAX public wavax;
    AAVEStrategy public strategy;
    AAVEStrategy public strategySecondary;

    address public user = address(0xABCD);
    address public owner = address(this); // Test contract is owner

    function setUp() public {
        // 1. Deploy Asset
        wavax = new MockWAVAX();

        // 2. Deploy Vault
        vault = new AVAVault(
            ERC20(address(wavax)),
            "Liquid Staked AVAX",
            "lsAVAX"
        );

        // 3. Deploy Strategy
        strategy = new AAVEStrategy(address(wavax), address(vault));
        strategySecondary = new AAVEStrategy(address(wavax), address(vault));

        // 4. Register Strategy in Vault
        vault.addStrategy(strategy);
        vault.updateActiveStrategy(strategy);

        // 5. Fund User
        wavax.mint(user, 1000 ether);

        // 6. Label addresses for clearer traces
        vm.label(user, "User");
        vm.label(address(vault), "Vault");
        vm.label(address(strategy), "StrategyPrimary");
        vm.label(address(wavax), "WAVAX");
    }

    function test_Initialization() public view {
        assertEq(vault.name(), "Liquid Staked AVAX");
        assertEq(address(vault.asset()), address(wavax));
        assertEq(address(vault.activeStrategy()), address(strategy));
    }

    function test_DepositMovesFundsToStrategy() public {
        uint256 depositAmount = 100 ether;

        vm.startPrank(user);
        wavax.approve(address(vault), depositAmount);

        // Action: Deposit
        uint256 shares = vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Checks:
        // 1. User has shares
        assertEq(shares, depositAmount, "Shares should be 1:1 initially");
        assertEq(vault.balanceOf(user), depositAmount);

        // 2. Vault should hold 0 float (it moves everything to strategy immediately)
        assertEq(
            wavax.balanceOf(address(vault)),
            0,
            "Vault should have moved funds"
        );

        // 3. Strategy should hold the funds
        assertEq(
            wavax.balanceOf(address(strategy)),
            depositAmount,
            "Strategy should hold funds"
        );

        // 4. Vault totalAssets should account for strategy balance
        assertEq(vault.totalAssets(), depositAmount);
    }

    function test_WithdrawPullsFromStrategy() public {
        // Setup: User deposits 100
        uint256 amount = 100 ether;
        vm.startPrank(user);
        wavax.approve(address(vault), amount);
        vault.deposit(amount, user);

        // Action: Withdraw 50
        uint256 withdrawAmount = 50 ether;
        vault.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        // Checks:
        // 1. User got WAVAX back
        assertEq(wavax.balanceOf(user), 1000 ether - amount + withdrawAmount);

        // 2. Strategy balance decreased
        assertEq(wavax.balanceOf(address(strategy)), 50 ether);

        // 3. Shares burned
        assertEq(vault.balanceOf(user), 50 ether);
    }

    function test_StrategyAccruesYield() public {
        uint256 depositAmount = 100 ether;

        // 1. Deposit
        vm.startPrank(user);
        wavax.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // 2. Simulate Yield: Directly mint tokens to the strategy
        // (Simulating Aave interest or staking rewards)
        uint256 yieldAmount = 10 ether;
        wavax.mint(address(strategy), yieldAmount);

        // 3. Check Accounting
        // Total Assets should be 110
        assertEq(vault.totalAssets(), 110 ether);

        // 4. Check Share Price
        // 1 share should now be worth 1.1 assets
        // convertToAssets(1 share)
        uint256 oneShareValue = vault.convertToAssets(1 ether);
        assertGt(oneShareValue, 1 ether);
    }

    function test_Rebalance() public {
        // Setup: Deposit 100 into Strategy 1
        uint256 depositAmount = 100 ether;
        vm.startPrank(user);
        wavax.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Add secondary strategy
        vault.addStrategy(strategySecondary);

        // Prepare Rebalance Data
        // Move 60% to Secondary, Leave 40% in Vault (or put back in primary)
        // Let's move 100% to Secondary
        IStrategy[] memory targets = new IStrategy[](1);
        targets[0] = strategySecondary;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = depositAmount;

        // Action: Rebalance
        vault.rebalance(targets, amounts);

        // Checks:
        // Strategy 1 should be empty
        assertEq(wavax.balanceOf(address(strategy)), 0);
        // Strategy 2 should have funds
        assertEq(wavax.balanceOf(address(strategySecondary)), depositAmount);
    }

    function test_AddInvalidStrategy_Reverts() public {
        // Should fail because MockWAVAX is not the asset for a random strategy
        // Or if we try to add address(0)
        vm.expectRevert("ZERO_ADDRESS");
        vault.addStrategy(IStrategy(address(0)));
    }
}
