// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC4626} from "../../lib/solmate/src/tokens/ERC4626.sol"; // The abstract file you provided
import {ERC20} from "../../lib/solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "../../lib/solmate/src/utils/SafeTransferLib.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/*//////////////////////////////////////////////////////////////
//
// AVALANCHE WAVAX LIQUID STAKING VAULT
//
//////////////////////////////////////////////////////////////*/

/**
 * @title AvaxLiquidStakingVault
 * @notice An ERC4626 vault for WAVAX.
 * @dev Inherits from the standard ERC4626 abstract contract provided.
 */
contract AVAVault is ERC4626 {
    using SafeTransferLib for ERC20;

    // --- State Variables ---

    address public immutable owner;

    /// @notice The list of all approved strategies.
    IStrategy[] public strategies;

    /// @notice Mapping to quickly check if a strategy is registered.
    mapping(address => bool) public isStrategy;

    /// @notice The default strategy to which new deposits are sent.
    IStrategy public activeStrategy;

    // --- Events ---

    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event ActiveStrategyUpdated(address indexed strategy);
    event Rebalanced(
        address indexed sender,
        IStrategy[] strategies,
        uint256[] amounts
    );

    // --- Modifiers ---

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    // --- Constructor ---

    /**
     * @param _asset The WAVAX contract address (0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7 on C-Chain)
     */
    constructor(
        ERC20 _asset,
        string memory _name,
        string memory _symbol
    ) ERC4626(_asset, _name, _symbol) {
        owner = msg.sender;
    }

    // --- ERC4626 Implementation ---

    /**
     * @notice Calculates the total WAVAX managed by the vault.
     * @dev Sum of WAVAX held in this contract + WAVAX equivalent in strategies.
     */
    function totalAssets() public view override returns (uint256) {
        uint256 totalInvested = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            totalInvested += strategies[i].balance();
        }
        // asset.balanceOf(address(this)) is the idle float
        return asset.balanceOf(address(this)) + totalInvested;
    }

    // --- Internal Hooks Implementation ---

    /**
     * @notice Hook called after a deposit.
     * @dev Moves the deposited WAVAX into the active strategy.
     */
    function afterDeposit(
        uint256 assets,
        uint256 /*shares*/
    ) internal override {
        if (address(activeStrategy) != address(0)) {
            // Approve the strategy to pull tokens, or transfer them.
            // Here we assume the strategy pulls via transferFrom or we push.
            // To be safe and compatible with most patterns:
            // We approve the strategy and call deposit.

            asset.safeApprove(address(activeStrategy), assets);
            activeStrategy.deposit(assets);

            // Reset approval to zero to be safe (optional but good practice)
            asset.safeApprove(address(activeStrategy), 0);
        }
    }

    /**
     * @notice Hook called before a withdrawal.
     * @dev Ensures the vault has enough idle WAVAX. Pulls from strategies if needed.
     */
    function beforeWithdraw(
        uint256 assets,
        uint256 /*shares*/
    ) internal override {
        uint256 float = asset.balanceOf(address(this));

        if (float < assets) {
            uint256 needed = assets - float;

            // Iterate backwards (LIFO)
            for (uint256 i = strategies.length; i > 0; i--) {
                uint256 strategyIndex = i - 1;
                IStrategy strategy = strategies[strategyIndex];
                uint256 strategyBal = strategy.balance();

                if (strategyBal == 0) continue;

                if (needed <= strategyBal) {
                    strategy.withdraw(needed);
                    needed = 0;
                    break;
                } else {
                    // Drain this strategy completely
                    strategy.withdraw(strategyBal);
                    needed -= strategyBal;
                }
            }
            require(needed == 0, "INSUFFICIENT_LIQUIDITY");
        }
    }

    // --- Strategy Management (Owner Only) ---

    function addStrategy(IStrategy _strategy) external onlyOwner {
        address strategyAddr = address(_strategy);
        require(strategyAddr != address(0), "ZERO_ADDRESS");
        require(!isStrategy[strategyAddr], "ALREADY_REGISTERED");
        require(_strategy.asset() == address(asset), "INVALID_ASSET"); // Ensure strategy uses WAVAX

        strategies.push(_strategy);
        isStrategy[strategyAddr] = true;
        emit StrategyAdded(strategyAddr);
    }

    function removeStrategy(IStrategy _strategy) external onlyOwner {
        address strategyAddr = address(_strategy);
        require(isStrategy[strategyAddr], "NOT_REGISTERED");

        // 1. Pull all funds back to Vault
        uint256 bal = _strategy.balance();
        if (bal > 0) {
            _strategy.withdraw(bal);
        }

        // 2. Clear active strategy if matching
        if (activeStrategy == _strategy) {
            activeStrategy = IStrategy(address(0));
            emit ActiveStrategyUpdated(address(0));
        }

        // 3. Remove from array (swap and pop)
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i] == _strategy) {
                strategies[i] = strategies[strategies.length - 1];
                strategies.pop();
                break;
            }
        }

        isStrategy[strategyAddr] = false;
        emit StrategyRemoved(strategyAddr);
    }

    function updateActiveStrategy(IStrategy _strategy) external onlyOwner {
        address strategyAddr = address(_strategy);
        if (strategyAddr != address(0)) {
            require(isStrategy[strategyAddr], "NOT_REGISTERED");
        }
        activeStrategy = _strategy;
        emit ActiveStrategyUpdated(strategyAddr);
    }

    /**
     * @notice Rebalances assets across strategies.
     * @param _targetStrategies The strategies to invest in.
     * @param _targetAmounts The amount of WAVAX to put in each.
     */
    function rebalance(
        IStrategy[] calldata _targetStrategies,
        uint256[] calldata _targetAmounts
    ) external onlyOwner {
        require(
            _targetStrategies.length == _targetAmounts.length,
            "ARRAY_LENGTH_MISMATCH"
        );

        // 1. Withdraw EVERYTHING to Vault first
        for (uint256 i = 0; i < strategies.length; i++) {
            IStrategy strategy = strategies[i];
            uint256 bal = strategy.balance();
            if (bal > 0) {
                strategy.withdraw(bal);
            }
        }

        uint256 totalBalance = asset.balanceOf(address(this));
        uint256 totalAllocated = 0;

        // 2. Distribute to targets
        for (uint256 i = 0; i < _targetStrategies.length; i++) {
            uint256 amount = _targetAmounts[i];
            if (amount == 0) continue;

            require(
                isStrategy[address(_targetStrategies[i])],
                "TARGET_NOT_REGISTERED"
            );

            uint256 newTotalAllocated = totalAllocated + amount;
            require(
                totalBalance >= newTotalAllocated,
                "INSUFFICIENT_FUNDS_FOR_REBALANCE"
            );

            totalAllocated = newTotalAllocated;

            // Approve and Deposit
            IStrategy target = _targetStrategies[i];
            asset.safeApprove(address(target), amount);
            target.deposit(amount);
            asset.safeApprove(address(target), 0);
        }

        emit Rebalanced(msg.sender, _targetStrategies, _targetAmounts);
    }
}
