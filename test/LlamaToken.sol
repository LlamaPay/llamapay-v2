// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.17;

import {ERC20} from "solmate/tokens/ERC20.sol";

contract LlamaToken is ERC20("LlamaToken", "LLAMA", 18) {
    function mint(address _to, uint256 _amount) public {
        _mint(_to, _amount);
    }

    function burn(address _from, uint256 _amount) public {
        _burn(_from, _amount);
    }
}