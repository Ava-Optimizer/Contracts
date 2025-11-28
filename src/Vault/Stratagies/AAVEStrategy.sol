// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IStrategy} from "../interfaces/IStrategy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract AAVEStrategy is IStrategy {
    ERC20 public immutable assetToken;
    address public immutable vault;

    constructor(address _asset, address _vault) {
        assetToken = ERC20(_asset);
        vault = _vault;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }


    function deposit(uint256 amount) external {
        require(msg.sender == vault, "Only vault");
        assetToken.transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) external {
        require(msg.sender == vault, "Only vault");
        assetToken.transfer(vault, amount);
    }

    function balance() external view returns (uint256) {
        return assetToken.balanceOf(address(this));
    }
}