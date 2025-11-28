// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IStrategy {
    /**
     * @notice Deposit the underlying asset (WAVAX) into the strategy.
     * @dev The Vault will have approved the Strategy to spend 'amount' before calling this.
     * @dev The Strategy must use `asset.transferFrom(vault, address(this), amount)`.
     * @param amount The amount of WAVAX to deposit.
     */
    function deposit(uint256 amount) external;

    /**
     * @notice Withdraw the underlying asset (WAVAX) from the strategy to the Vault.
     * @dev The Strategy must unwrap/unstake enough funds and transfer 'amount' of WAVAX back to msg.sender (the Vault).
     * @param amount The amount of WAVAX to withdraw.
     */
    function withdraw(uint256 amount) external;

    /**
     * @notice Reports the total value managed by the strategy in terms of the underlying asset (WAVAX).
     * @dev This includes idle funds + staked funds + accrued rewards.
     * @return balance The total WAVAX value held by the strategy.
     */
    function balance() external view returns (uint256);

    /**
     * @notice Returns the address of the underlying asset (WAVAX).
     * @dev Used by the Vault to verify this strategy is compatible.
     */
    function asset() external view returns (address);
}