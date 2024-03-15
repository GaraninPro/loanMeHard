/* SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { BaseTest, ThunderLoan } from "./BaseTest.t.sol";
import { AssetToken } from "../../src/protocol/AssetToken.sol";
import { MockFlashLoanReceiver } from "../mocks/MockFlashLoanReceiver.sol";

contract ThunderLoanTest is BaseTest {
    uint256 constant AMOUNT = 10e18;
    uint256 constant DEPOSIT_AMOUNT = AMOUNT * 100;
    address liquidityProvider = address(123);
    address user = address(456);
    MockFlashLoanReceiver mockFlashLoanReceiver;

    function setUp() public override {
        super.setUp();
        vm.prank(user);
        mockFlashLoanReceiver = new MockFlashLoanReceiver(address(thunderLoan));
    }
    //////////////////////////////////////////////////////////

    modifier setAllowedToken() {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        _;
    }

    modifier hasDeposits() {
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, DEPOSIT_AMOUNT);
        tokenA.approve(address(thunderLoan), DEPOSIT_AMOUNT);
        thunderLoan.deposit(tokenA, DEPOSIT_AMOUNT);
        vm.stopPrank();
        _;
    }
    ////////////////////////////////////////////////////////////

    function testInitializationOwner() public {
        assertEq(thunderLoan.owner(), address(this));
    }

    function testSetAllowedTokens() public {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        assertEq(thunderLoan.isAllowedToken(tokenA), true);
    }

    function testOnlyOwnerCanSetTokens() public {
        vm.prank(liquidityProvider);
        vm.expectRevert();
        thunderLoan.setAllowedToken(tokenA, true);
    }

    function testSettingTokenCreatesAsset() public {
        vm.prank(thunderLoan.owner());
        AssetToken assetToken = thunderLoan.setAllowedToken(tokenA, true);
        assertEq(address(thunderLoan.getAssetFromToken(tokenA)), address(assetToken));
    }

    function testCantDepositUnapprovedTokens() public {
        tokenA.mint(liquidityProvider, AMOUNT);
        tokenA.approve(address(thunderLoan), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(ThunderLoan.ThunderLoan__NotAllowedToken.selector, address(tokenA)));
        thunderLoan.deposit(tokenA, AMOUNT);
    }

    function testDepositMintsAssetAndUpdatesBalance() public setAllowedToken {
        tokenA.mint(liquidityProvider, AMOUNT);

        vm.startPrank(liquidityProvider);
        tokenA.approve(address(thunderLoan), AMOUNT);
        thunderLoan.deposit(tokenA, AMOUNT);
        vm.stopPrank();

        AssetToken asset = thunderLoan.getAssetFromToken(tokenA);
        assertEq(tokenA.balanceOf(address(asset)), AMOUNT);
        console.log("balance of asset contract", tokenA.balanceOf(address(asset)) / 1e18, "tokens");
        console.log(
            "balance of liqiProvider contract", asset.balanceOf(address(liquidityProvider)) / 1e18, " LP tokens"
        );

        assertEq(asset.balanceOf(liquidityProvider), AMOUNT);
    }

    function testFlashLoan() public setAllowedToken hasDeposits {
        uint256 amountToBorrow = AMOUNT * 10;
        uint256 calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        vm.startPrank(user);
        uint256 fee2 = thunderLoan.getCalculatedFee2(amountToBorrow);
        ///////////////////////////////////////////////////////////
        console.log("Amount of fee in loaned tokens with bad calculation", calculatedFee);
        console.log("Amount of fee in loaned tokens with good calculation", fee2);

        tokenA.mint(address(mockFlashLoanReceiver), AMOUNT);
        thunderLoan.flashloan(address(mockFlashLoanReceiver), tokenA, amountToBorrow, "");
        vm.stopPrank();

        assertEq(mockFlashLoanReceiver.getBalanceDuring(), amountToBorrow + AMOUNT);
        assertEq(mockFlashLoanReceiver.getBalanceAfter(), AMOUNT - calculatedFee);
    }

    function testRedeem() public setAllowedToken hasDeposits {
        AssetToken asset = thunderLoan.getAssetFromToken(tokenA);
        console.log("balance of asset contract after deposit = ", tokenA.balanceOf(address(asset)) / 1e18, "tokens");
        console.log(
            "balance of liqiProvider contract after deposit = ",
            asset.balanceOf(address(liquidityProvider)) / 1e18,
            " LP tokens"
        );
        console.log("Exchangerate after deposit is", asset.getExchangeRate(), "or 1.003"); // 1.003
        ////////////////////////////////////////////////////////////////////////////////////////

        uint256 amountToBorrow = AMOUNT * 10; //100 tokens
        uint256 calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        vm.startPrank(user);
        console.log("Amount of fee in loaned tokens with bad calculation", calculatedFee, "or 0.3 tokens"); //0.3

        tokenA.mint(address(mockFlashLoanReceiver), AMOUNT); // 10 tokens
        thunderLoan.flashloan(address(mockFlashLoanReceiver), tokenA, amountToBorrow, "");
        console.log(
            "balance of asset contract after flashloan",
            tokenA.balanceOf(address(asset)) / 1e16,
            "tokens or 1000,3 tokens"
        ); // 1000,3 tokens

        console.log("Exchangerate after flashloan is", asset.getExchangeRate(), "or higher than 1.003");
        console.log("So to reedeem 1000 lp tokens will be :", 1000 * asset.getExchangeRate());
        vm.stopPrank();
        //////////////////////////////////////////////////////////////////////////////////////////
        vm.startPrank(liquidityProvider);
        vm.expectRevert();
        thunderLoan.redeem(tokenA, type(uint256).max);

        vm.stopPrank();
    }
}
*/
