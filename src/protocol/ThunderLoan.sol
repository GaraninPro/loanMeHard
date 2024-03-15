// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.20;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AssetToken } from "./AssetToken.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { OracleUpgradeable } from "./OracleUpgradeable.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IFlashLoanReceiver } from "../interfaces/IFlashLoanReceiver.sol";

//SafeERC20 It’s a helper to make safe the interaction with someone else’s ERC20 token, in your contracts.

contract ThunderLoan is Initializable, OwnableUpgradeable, UUPSUpgradeable, OracleUpgradeable {
    error ThunderLoan__NotAllowedToken(IERC20 token);
    error ThunderLoan__CantBeZero();
    error ThunderLoan__NotPaidBack(uint256 expectedEndingBalance, uint256 endingBalance);
    error ThunderLoan__NotEnoughTokenBalance(uint256 startingBalance, uint256 amount);
    error ThunderLoan__CallerIsNotContract();
    error ThunderLoan__AlreadyAllowed();
    error ThunderLoan__ExhangeRateCanOnlyIncrease();
    error ThunderLoan__NotCurrentlyFlashLoaning();
    error ThunderLoan__BadNewFee();

    using SafeERC20 for IERC20;
    using Address for address;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    mapping(IERC20 => AssetToken) public s_tokenToAssetToken;

    // The fee in WEI, it should have 18 decimals. Each flash loan takes a flat fee of the token price.
    uint256 private s_feePrecision; //slot2
    uint256 private s_flashLoanFee; // 0.3% ETH fee

    mapping(IERC20 token => bool currentlyFlashLoaning) private s_currentlyFlashLoaning;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event Deposit(address indexed account, IERC20 indexed token, uint256 amount);
    event AllowedTokenSet(IERC20 indexed token, AssetToken indexed asset, bool allowed);
    event Redeemed(
        address indexed account, IERC20 indexed token, uint256 amountOfAssetToken, uint256 amountOfUnderlying
    );
    event FlashLoan(address indexed receiverAddress, IERC20 indexed token, uint256 amount, uint256 fee, bytes params);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier revertIfZero(uint256 amount) {
        if (amount == 0) {
            revert ThunderLoan__CantBeZero();
        }
        _;
    }

    modifier revertIfNotAllowedToken(IERC20 token) {
        if (!isAllowedToken(token)) {
            revert ThunderLoan__NotAllowedToken(token);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function initialize(address tswapAddress) external initializer {
        //@audit-issue we need poolfactory address, not tswapAddress
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __Oracle_init(tswapAddress);
        s_feePrecision = 1e18; //@audit-issue magic numbers
        s_flashLoanFee = 3e15; // 0.3% ETH fee
    }
    /*////////////////////////////////////////////////////////////// 
                           DEPOSIT
    //     Using IERC20 instead of address for token parameters in Solidity functions is a best practice for interacting
    with ERC20 tokens. It provides type safety, improves code readability, and allows for direct interaction with the
    ERC20 standard functions.
                    
    //////////////////////////////////////////////////////////////*/

    function deposit(IERC20 token, uint256 amount) external revertIfZero(amount) revertIfNotAllowedToken(token) {
        AssetToken assetToken = s_tokenToAssetToken[token];
        uint256 exchangeRate = assetToken.getExchangeRate();
        uint256 mintAmount = (amount * assetToken.EXCHANGE_RATE_PRECISION()) / exchangeRate;
        emit Deposit(msg.sender, token, amount);
        assetToken.mint(msg.sender, mintAmount);

        //calculates the fee of borrowing this amount of tokens in flashloan
        uint256 calculatedFee = getCalculatedFee(token, amount);
        // uint256 valueOfDepositedToken = (amount * getPriceInWeth(address(token))) / s_feePrecision;
        //@audit-issue we must update exchangeRate with amount deposited  in weth not calculatedFee
        assetToken.updateExchangeRate(calculatedFee);
        token.safeTransferFrom(msg.sender, address(assetToken), amount);
    }

    /// @notice Withdraws the underlying token from the asset token
    /// @param token The token they want to withdraw from
    /// @param amountOfAssetToken The amount of the underlying they want to withdraw
    /*//////////////////////////////////////////////////////////////
                           REDEEM
    //////////////////////////////////////////////////////////////*/
    function redeem(
        IERC20 token,
        uint256 amountOfAssetToken
    )
        external
        revertIfZero(amountOfAssetToken)
        revertIfNotAllowedToken(token)
    {
        //@audit-issue why we do not update exchange-rate
        AssetToken assetToken = s_tokenToAssetToken[token];
        uint256 exchangeRate = assetToken.getExchangeRate();
        if (amountOfAssetToken == type(uint256).max) {
            amountOfAssetToken = assetToken.balanceOf(msg.sender);
        }
        uint256 amountUnderlying = (amountOfAssetToken * exchangeRate) / assetToken.EXCHANGE_RATE_PRECISION();
        emit Redeemed(msg.sender, token, amountOfAssetToken, amountUnderlying);
        assetToken.burn(msg.sender, amountOfAssetToken);
        assetToken.transferUnderlyingTo(msg.sender, amountUnderlying);
    }
    /*//////////////////////////////////////////////////////////////
                           FLASHLOAN
    //////////////////////////////////////////////////////////////*/

    function flashloan(
        address receiverAddress,
        IERC20 token,
        uint256 amount,
        bytes calldata params
    )
        external
        revertIfZero(amount)
        revertIfNotAllowedToken(token)
    {
        AssetToken assetToken = s_tokenToAssetToken[token];
        //uint256 startingBalance = IERC20(token).balanceOf(address(assetToken));
        uint256 startingBalance = token.balanceOf(address(assetToken));

        if (amount > startingBalance) {
            revert ThunderLoan__NotEnoughTokenBalance(startingBalance, amount);
        }

        if (receiverAddress.code.length == 0) {
            revert ThunderLoan__CallerIsNotContract();
        }

        uint256 fee = getCalculatedFee(token, amount);
        // slither-disable-next-line reentrancy-vulnerabilities-2 reentrancy-vulnerabilities-3
        assetToken.updateExchangeRate(fee);
        //@audit-issue
        emit FlashLoan(receiverAddress, token, amount, fee, params);

        s_currentlyFlashLoaning[token] = true;
        assetToken.transferUnderlyingTo(receiverAddress, amount);
        // slithtokenA.balanceOf(address(receiver3))er-disable-next-line unused-return reentrancy-vulnerabilities-2
        //@audit-issue
        ////////////////////////////////////////////////////s
        //receiverAddress.functionCall is target  in functionCall
        //
        receiverAddress.functionCall(
            abi.encodeCall(
                IFlashLoanReceiver.executeOperation,
                (
                    address(token),
                    amount,
                    fee,
                    msg.sender, // initiator
                    params
                )
            ) // external call to function of  another contract and now waits its finish
        );
        /**
         * receiverAddress.functionCall(
         * abi.encodeWithSignature(
         *     "IFlashLoanReceivers.executeOperation(address,uint256,uint256,address,bytes)",
         *     address(token),
         *     amount,
         *     fee,
         *     msg.sender, // initiator
         *     params
         * )
         * );
         */
        /**
         * receiverAddress.functionCall(
         * abi.encodeWithSelector(
         *     IFlashLoanReceiver.executeOperation.selector,
         *     address(token),
         *     amount,
         *     fee,
         *     msg.sender, // initiator
         *     params
         * )
         * );
         */
        uint256 endingBalance = token.balanceOf(address(assetToken));
        if (endingBalance < startingBalance + fee) {
            revert ThunderLoan__NotPaidBack(startingBalance + fee, endingBalance);
        }
        s_currentlyFlashLoaning[token] = false;
    }
    /*//////////////////////////////////////////////////////////////
                           REPAY FUNCTION
    //////////////////////////////////////////////////////////////*/

    function repay(IERC20 token, uint256 amount) public {
        if (!s_currentlyFlashLoaning[token]) {
            revert ThunderLoan__NotCurrentlyFlashLoaning();
        }
        AssetToken assetToken = s_tokenToAssetToken[token];
        token.safeTransferFrom(msg.sender, address(assetToken), amount);
    }
    /*//////////////////////////////////////////////////////////////
                     setAllowedToken      FUNCTION
    //////////////////////////////////////////////////////////////*/

    function setAllowedToken(IERC20 token, bool allowed) external onlyOwner returns (AssetToken) {
        if (allowed) {
            if (address(s_tokenToAssetToken[token]) != address(0)) {
                revert ThunderLoan__AlreadyAllowed();
            }
            string memory name = string.concat("ThunderLoan ", IERC20Metadata(address(token)).name());
            string memory symbol = string.concat("tl", IERC20Metadata(address(token)).symbol());
            AssetToken assetToken = new AssetToken(address(this), token, name, symbol);
            s_tokenToAssetToken[token] = assetToken;
            emit AllowedTokenSet(token, assetToken, allowed);
            return assetToken;
        } else {
            AssetToken assetToken = s_tokenToAssetToken[token];
            delete s_tokenToAssetToken[token];
            emit AllowedTokenSet(token, assetToken, allowed);
            return assetToken;
        }
    }
    /*//////////////////////////////////////////////////////////////
                           getCalculatedFee FUNCTION
    //////////////////////////////////////////////////////////////*/

    function getCalculatedFee(IERC20 token, uint256 amount) public view returns (uint256 fee) {
        //slither-disable-next-line divide-before-multiply
        uint256 valueOfBorrowedToken = (amount * getPriceInWeth(address(token))) / s_feePrecision;
        //@audit-issue the value will be less than it really are because of getPriceInWeth function
        //slither-disable-next-line divide-before-multiply
        fee = (valueOfBorrowedToken * s_flashLoanFee) / s_feePrecision;
    }

    function getCalculatedFee2(uint256 amount) public view returns (uint256 fee) {
        //slither-disable-next-line divide-before-multiply
        //@audit-issue the value will be less than it really are because of getPriceInWeth function
        //slither-disable-next-line divide-before-multiply
        fee = (amount * s_flashLoanFee) / s_feePrecision;
    }
    /*//////////////////////////////////////////////////////////////
                           updateFlashLoanFee FUNCTION
    //////////////////////////////////////////////////////////////*/

    function updateFlashLoanFee(uint256 newFee) external onlyOwner {
        if (newFee > s_feePrecision) {
            revert ThunderLoan__BadNewFee();
        }
        //@audit-issue no event emited
        s_flashLoanFee = newFee;
    }
    ///////////////////////////////////////////////////////////////////////////
    //////////////////////////////////////////////////////////////////////////

    function isAllowedToken(IERC20 token) public view returns (bool) {
        return address(s_tokenToAssetToken[token]) != address(0);
    }

    function getAssetFromToken(IERC20 token) public view returns (AssetToken) {
        return s_tokenToAssetToken[token];
    }

    function isCurrentlyFlashLoaning(IERC20 token) public view returns (bool) {
        return s_currentlyFlashLoaning[token];
    }

    function getFee() external view returns (uint256) {
        return s_flashLoanFee;
    }

    function getFeePrecision() external view returns (uint256) {
        return s_feePrecision;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner { }
}
