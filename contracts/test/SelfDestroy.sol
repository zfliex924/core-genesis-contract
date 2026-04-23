// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.24;

contract SelfDestroy {
    function destruct(address payable target) public{
        selfdestruct(target);
    }

    receive() external payable{}
}
