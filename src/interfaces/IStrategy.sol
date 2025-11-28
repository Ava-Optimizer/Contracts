//SPDX-License-Identitifier: MIT
pragma solidity 0.8.30;

interface IStrategy {
    /**
     * @notice Deposit ETH into the strategy.
     * @dev MUST be payable.
     * @dev MUST revert if caller is not the vault.
     */
    function deposit() external payable;

    /**
     * @notice Withdraw ETH from the strategy.
     * @param amount The amount of ETH to withdraw.
     * @dev MUST revert if caller is not the vault.
     * @dev MUST send the ETH to the vault.
     */
    function withdraw(uint256 amount) external;

    /**
     * @notice Reports the total ETH balance of the strategy.
     * @dev This should include any rewards earned.
     * @return balance The total ETH held by the strategy.
     */
    function balance() external view returns (uint256);
}