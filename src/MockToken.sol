// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";


/**
* @title Mock Token
* @dev Mock ERC20 token to test yield farming
*/
contract MockToken is ERC20, Ownable {

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupplyWithoutDecimals_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        _mint(msg.sender, initialSupplyWithoutDecimals_ * 10**decimals())
    }

    function mint(address to_, uint256 amount_) external onlyOwner {
        _mint(to_, amount_);
    }

    function burn(uint256 amount_) external {
        _burn(msg.sender, amount_);
    }

}