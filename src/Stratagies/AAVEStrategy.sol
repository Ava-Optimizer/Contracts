//SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IStrategy} from "../interfaces/IStrategy.sol";

contract AAVEStrategy is IStrategy {
    
    /// @notice The vault contract that controls this strategy.
    address public immutable vault;

    /**
     * @dev Sets the vault address on deployment.
     * The vault admin would deploy this, passing the vault's address.
     */
    constructor(address _vault) {
        require(_vault != address(0), "ZERO_ADDRESS");
        vault = _vault;
    }

    /**
     * @notice Accept ETH deposits *only* from the vault.
     */
    function deposit() external payable override {
        require(msg.sender == vault, "NOT_VAULT");
    }

    /**
     * @notice Withdraw ETH *only* to the vault.
     */
    function withdraw(uint256 amount) external override {
        require(msg.sender == vault, "NOT_VAULT");
        require(address(this).balance >= amount, "INSUFFICIENT_FUNDS");
        
        // Send ETH back to the vault
        (bool success, ) = vault.call{value: amount}("");
        require(success, "ETH_TRANSFER_FAILED");
    }

    /**
     * @notice Report the total ETH balance held by this contract.
     * @dev A real strategy would query its underlying protocol.
     */
    function balance() external view override returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Allow receiving ETH via .deposit{value: ...}
     * We also need a receive() function to accept the ETH.
     */
    receive() external payable {
        // This payable receive is necessary for the vault's
        // `strategy.deposit{value: assets}()` call.
        require(msg.sender == vault, "NOT_VAULT");
    }
}