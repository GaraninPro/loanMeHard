// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IThunderLoan {
    function repay(address token, uint256 amount) external;
    //@audit-issue in Thunderloan contract we need to pass IERC20 token NOt address token
}
