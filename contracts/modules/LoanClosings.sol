/**
 * Copyright 2017-2020, bZeroX, LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0.
 */

pragma solidity 0.5.17;
pragma experimental ABIEncoderV2;

import "../core/State.sol";
import "../events/LoanClosingsEvents.sol";
import "../mixins/VaultController.sol";
import "../mixins/InterestUser.sol";
import "../mixins/LiquidationHelper.sol";
import "../mixins/GasTokenUser.sol";
import "../swaps/SwapsUser.sol";


contract LoanClosings is State, LoanClosingsEvents, VaultController, InterestUser, GasTokenUser, SwapsUser, LiquidationHelper {

    constructor() public {}

    function()
        external
    {
        revert("fallback not allowed");
    }

    function initialize(
        address target)
        external
        onlyOwner
    {
        _setTarget(this.liquidate.selector, target);
        _setTarget(this.closeWithDeposit.selector, target);
        _setTarget(this.closeWithSwap.selector, target);
    }

    function liquidate(
        bytes32 loanId,
        address receiver,
        uint256 closeAmount) // denominated in loanToken
        external
        payable
        //usesGasToken
        nonReentrant
        returns (
            uint256 loanCloseAmount,
            uint256 seizedAmount,
            address seizedToken
        )
    {
        require(closeAmount != 0, "closeAmount == 0");

        Loan storage loanLocal = loans[loanId];
        LoanParams storage loanParamsLocal = loanParams[loanLocal.loanParamsId];

        require(loanLocal.active, "loan is closed");
        require(loanParamsLocal.id != 0, "loanParams not exists");

        (uint256 currentMargin, uint256 collateralToLoanRate) = IPriceFeeds(priceFeeds).getCurrentMargin(
            loanParamsLocal.loanToken,
            loanParamsLocal.collateralToken,
            loanLocal.principal,
            loanLocal.collateral
        );
        require(
            currentMargin <= loanParamsLocal.maintenanceMargin,
            "healthy position"
        );

        loanCloseAmount = closeAmount;

        (uint256 maxLiquidatable, uint256 maxSeizable,) = _getLiquidationAmounts(
            loanLocal.principal,
            loanLocal.collateral,
            currentMargin,
            loanParamsLocal.maintenanceMargin,
            collateralToLoanRate
        );

        if (loanCloseAmount < maxLiquidatable) {
            seizedAmount = SafeMath.div(
                SafeMath.mul(maxSeizable, loanCloseAmount),
                maxLiquidatable
            );
        } else if (loanCloseAmount > maxLiquidatable) {
            // adjust down the close amount to the max
            loanCloseAmount = maxLiquidatable;
            seizedAmount = maxSeizable;
        }

        uint256 loanCloseAmountLessInterest = _getPrincipalAmountNeeded(
            loanLocal,
            loanParamsLocal,
            loanCloseAmount,
            loanLocal.borrower
        );
        if (loanCloseAmount > loanCloseAmountLessInterest) {
            // full interest refund goes to borrower
            _withdrawAsset(
                loanParamsLocal.loanToken,
                loanLocal.borrower,
                loanCloseAmount - loanCloseAmountLessInterest
            );
        }

        if (loanCloseAmount != 0) {
            _returnPrincipalWithDeposit(
                loanParamsLocal.loanToken,
                loanLocal.lender,
                loanCloseAmount
            );

        }

        seizedToken = loanParamsLocal.collateralToken;

        if (seizedAmount != 0) {
            loanLocal.collateral = loanLocal.collateral
                .sub(seizedAmount);

            _withdrawAsset(
                seizedToken,
                receiver,
                seizedAmount
            );
        }

        _closeLoan(
            loanLocal,
            loanCloseAmount
        );

        _emitClosingEvents(
            loanParamsLocal,
            loanLocal,
            loanCloseAmount,
            seizedAmount,
            collateralToLoanRate,
            currentMargin,
            3 // closeType
        );
    }

    function closeWithDeposit(
        bytes32 loanId,
        address receiver,
        uint256 depositAmount) // denominated in loanToken
        external
        payable
        //usesGasToken
        nonReentrant
        returns (
            uint256 loanCloseAmount,
            uint256 withdrawAmount,
            address withdrawToken
        )
    {
        require(depositAmount != 0, "depositAmount == 0");

        Loan storage loanLocal = loans[loanId];
        LoanParams storage loanParamsLocal = loanParams[loanLocal.loanParamsId];
        _checkAuthorized(
            loanLocal,
            loanParamsLocal
        );

        // can't close more than the full principal
        loanCloseAmount = depositAmount > loanLocal.principal ?
            loanLocal.principal :
            depositAmount;

        uint256 principalNeeded = _getPrincipalAmountNeeded(
            loanLocal,
            loanParamsLocal,
            loanCloseAmount,
            receiver
        );

        if (principalNeeded != 0) {
            _returnPrincipalWithDeposit(
                loanParamsLocal.loanToken,
                loanLocal.lender,
                principalNeeded
            );
        }

        if (loanCloseAmount == loanLocal.principal) {
            withdrawAmount = loanLocal.collateral;
        } else {
            withdrawAmount = SafeMath.div(
                SafeMath.mul(loanLocal.collateral, loanCloseAmount),
                loanLocal.principal
            );
        }

        withdrawToken = loanParamsLocal.collateralToken;

        if (withdrawAmount != 0) {
            _withdrawAsset(
                withdrawToken,
                receiver,
                withdrawAmount
            );
        }

        _closeLoan(
            loanLocal,
            loanCloseAmount
        );

        _finalizeClose(
            loanLocal,
            loanParamsLocal,
            loanCloseAmount,
            withdrawAmount, // collateralCloseAmount,
            1 // closeType
        );
    }

    function closeWithSwap(
        bytes32 loanId,
        address receiver,
        uint256 swapAmount, // denominated in collateralToken
        bool returnTokenIsCollateral, // true: withdraws collateralToken, false: withdraws loanToken
        bytes memory loanDataBytes)
        public
        //usesGasToken
        nonReentrant
        returns (
            uint256 loanCloseAmount,
            uint256 withdrawAmount,
            address withdrawToken
        )
    {
        require(swapAmount != 0, "swapAmount == 0");

        Loan storage loanLocal = loans[loanId];
        LoanParams storage loanParamsLocal = loanParams[loanLocal.loanParamsId];
        _checkAuthorized(
            loanLocal,
            loanParamsLocal
        );

        swapAmount = swapAmount > loanLocal.collateral ?
            loanLocal.collateral :
            swapAmount;

        if (swapAmount < loanLocal.collateral) {
            // determine about of loan to payback by converting from collateral to principal
            (uint256 currentMargin, uint256 collateralToLoanRate) = IPriceFeeds(priceFeeds).getCurrentMargin(
                loanParamsLocal.loanToken,
                loanParamsLocal.collateralToken,
                loanLocal.principal,
                loanLocal.collateral
            );
            // convert from collateral to principal
            /*loanCloseAmount = swapAmount
                .mul(10**20)
                .div(currentMargin)
                .mul(collateralToLoanRate)
                .div(10**18);*/
            loanCloseAmount = swapAmount
                .mul(collateralToLoanRate)
                .mul(100)
                .div(currentMargin);

            // can't close more than the full principal
            loanCloseAmount = loanCloseAmount > loanLocal.principal ?
                loanLocal.principal :
                loanCloseAmount;
        } else {
            loanCloseAmount = loanLocal.principal;
        }
        require(loanCloseAmount != 0, "loanCloseAmount == 0");

        uint256 principalNeeded = _getPrincipalAmountNeeded(
            loanLocal,
            loanParamsLocal,
            loanCloseAmount,
            receiver
        );

        withdrawAmount = _returnPrincipalWithSwap(
            loanLocal,
            loanParamsLocal,
            swapAmount,
            principalNeeded,
            returnTokenIsCollateral,
            loanDataBytes
        );

        loanLocal.collateral = loanLocal.collateral
            .sub(swapAmount);

        withdrawToken = returnTokenIsCollateral ?
            loanParamsLocal.collateralToken :
            loanParamsLocal.loanToken;

        if (withdrawAmount != 0) {
            _withdrawAsset(
                withdrawToken,
                receiver,
                withdrawAmount
            );
        }

        _closeLoan(
            loanLocal,
            loanCloseAmount
        );

        _finalizeClose(
            loanLocal,
            loanParamsLocal,
            loanCloseAmount,
            swapAmount, // collateralCloseAmount,
            2 // closeType
        );
    }

    function _checkAuthorized(
        Loan memory loanLocal,
        LoanParams memory loanParamsLocal)
        internal
    {
        require(loanLocal.active, "loan is closed");
        require(
            msg.sender == loanLocal.borrower ||
            delegatedManagers[loanLocal.id][msg.sender],
            "unauthorized"
        );
        require(loanParamsLocal.id != 0, "loanParams not exists");
    }

    function _getPrincipalAmountNeeded(
        Loan memory loanLocal,
        LoanParams memory loanParamsLocal,
        uint256 loanCloseAmount,
        address receiver)
        internal
        returns (uint256)
    {
        uint256 principalNeeded = loanCloseAmount;

        uint256 interestRefundToBorrower = _settleInterest(
            loanParamsLocal,
            loanLocal,
            principalNeeded
        );

        uint256 interestAppliedToPrincipal;
        if (principalNeeded >= interestRefundToBorrower) {
            // apply all of borrower interest refund torwards principal
            interestAppliedToPrincipal = interestRefundToBorrower;

            // principal needed is reduced by this amount
            principalNeeded -= interestRefundToBorrower;

            // no interest refund remaining
            interestRefundToBorrower = 0;
        } else {
            // principal fully covered by excess interest
            interestAppliedToPrincipal = principalNeeded;

            // amount refunded is reduced by this amount
            interestRefundToBorrower -= principalNeeded;

            // principal fully covered by excess interest
            principalNeeded = 0;
        }

        if (interestRefundToBorrower != 0) {
            // refund overage
            _withdrawAsset(
                loanParamsLocal.loanToken,
                receiver,
                interestRefundToBorrower
            );
        }

        if (interestAppliedToPrincipal != 0) {
            vaultWithdraw(
                loanParamsLocal.loanToken,
                loanLocal.lender,
                interestAppliedToPrincipal
            );
        }

        return principalNeeded;
    }

    // repays principal to lender
    function _returnPrincipalWithDeposit(
        address loanToken,
        address lender,
        uint256 principalNeeded)
        internal
    {
        if (principalNeeded != 0) {
            if (msg.value == 0) {
                vaultTransfer(
                    loanToken,
                    msg.sender,
                    lender,
                    principalNeeded
                );
            } else {
                require(loanToken == address(wethToken), "wrong asset sent");
                require(msg.value >= principalNeeded, "not enough ether");
                wethToken.deposit.value(principalNeeded)();
                vaultTransfer(
                    loanToken,
                    address(this),
                    lender,
                    principalNeeded
                );
                if (msg.value > principalNeeded) {
                    // refund overage
                    Address.sendValue(
                        msg.sender,
                        msg.value - principalNeeded
                    );
                }
            }
        } else {
            require(msg.value == 0, "wrong asset sent");
        }
    }

    function _returnPrincipalWithSwap(
        Loan storage loanLocal,
        LoanParams storage loanParamsLocal,
        uint256 swapAmount,
        uint256 principalNeeded,
        bool returnTokenIsCollateral,
        bytes memory loanDataBytes)
        internal
        returns (uint256 withdrawAmount)
    {
        (uint256 destTokenAmountReceived, uint256 sourceTokenAmountUsed) = _loanSwap(
            loanLocal.id,
            loanParamsLocal.collateralToken,
            loanParamsLocal.loanToken,
            loanLocal.borrower,
            swapAmount,
            returnTokenIsCollateral ? // requiredDestTokenAmount
                principalNeeded :
                0,
            0, // minConversionRate
            false, // isLiquidation
            loanDataBytes
        );
        require(destTokenAmountReceived >= principalNeeded, "insufficient dest amount");
        require(sourceTokenAmountUsed <= swapAmount, "excessive source amount");

        // repays principal to lender
        vaultWithdraw(
            loanParamsLocal.loanToken,
            loanLocal.lender,
            principalNeeded
        );

        if (returnTokenIsCollateral) {
            if (destTokenAmountReceived > principalNeeded) {
                // better fill than expected, so send excess to borrower
                vaultWithdraw(
                    loanParamsLocal.loanToken,
                    loanLocal.borrower,
                    destTokenAmountReceived - principalNeeded
                );
            }
            withdrawAmount = swapAmount - sourceTokenAmountUsed;
        } else {
            require(sourceTokenAmountUsed == swapAmount, "swap error");
            withdrawAmount = destTokenAmountReceived - principalNeeded;
        }
    }

    // withdraws asset to receiver
    function _withdrawAsset(
        address assetToken,
        address receiver,
        uint256 assetAmount)
        internal
    {
        if (assetAmount != 0) {
            if (assetToken == address(wethToken)) {
                vaultEtherWithdraw(
                    receiver,
                    assetAmount
                );
            } else {
                vaultWithdraw(
                    assetToken,
                    receiver,
                    assetAmount
                );
            }
        }
    }

    function _finalizeClose(
        Loan storage loanLocal,
        LoanParams storage loanParamsLocal,
        uint256 loanCloseAmount,
        uint256 collateralCloseAmount,
        uint256 closeType)
        internal
    {
        (uint256 currentMargin, uint256 collateralToLoanRate) = IPriceFeeds(priceFeeds).getCurrentMargin(
            loanParamsLocal.loanToken,
            loanParamsLocal.collateralToken,
            loanLocal.principal,
            loanLocal.collateral
        );
        require(
            loanLocal.principal == 0 ||
            currentMargin > loanParamsLocal.maintenanceMargin,
            "unhealthy position"
        );

        _emitClosingEvents(
            loanParamsLocal,
            loanLocal,
            loanCloseAmount,
            collateralCloseAmount,
            collateralToLoanRate,
            currentMargin,
            closeType
        );
    }

    function _closeLoan(
        Loan storage loanLocal,
        uint256 loanCloseAmount)
        internal
        returns (uint256)
    {
        require(loanCloseAmount != 0, "nothing to close");

        if (loanCloseAmount == loanLocal.principal) {
            loanLocal.principal = 0;
            loanLocal.active = false;
            loanLocal.endTimestamp = block.timestamp;
            loanLocal.pendingTradesId = 0;
            activeLoansSet.remove(loanLocal.id);
            lenderLoanSets[loanLocal.lender].remove(loanLocal.id);
            borrowerLoanSets[loanLocal.borrower].remove(loanLocal.id);
        } else {
            loanLocal.principal = loanLocal.principal
                .sub(loanCloseAmount);
        }
    }

    function _settleInterest(
        LoanParams memory loanParamsLocal,
        Loan memory loanLocal,
        uint256 closePrincipal)
        internal
        returns (uint256)
    {
        uint256 interestRefundToBorrower;

        LoanInterest storage loanInterestLocal = loanInterest[loanLocal.id];
        LenderInterest storage lenderInterestLocal = lenderInterest[loanLocal.lender][loanParamsLocal.loanToken];

        // pay outstanding interest to lender
        _payInterest(
            lenderInterestLocal,
            loanLocal.lender,
            loanParamsLocal.loanToken
        );

        uint256 owedPerDayRefund;
        if (closePrincipal < loanLocal.principal) {
            owedPerDayRefund = SafeMath.div(
                SafeMath.mul(closePrincipal, loanInterestLocal.owedPerDay),
                loanLocal.principal
            );
        } else {
            owedPerDayRefund = loanInterestLocal.owedPerDay;
        }

        // update stored owedPerDay
        loanInterestLocal.owedPerDay = loanInterestLocal.owedPerDay
            .sub(owedPerDayRefund);
        lenderInterestLocal.owedPerDay = lenderInterestLocal.owedPerDay
            .sub(owedPerDayRefund);

        // update borrower interest
        uint256 interestTime = block.timestamp;
        if (interestTime > loanLocal.endTimestamp) {
            interestTime = loanLocal.endTimestamp;
        }

        interestRefundToBorrower = loanLocal.endTimestamp
            .sub(interestTime);
        interestRefundToBorrower = interestRefundToBorrower
            .mul(owedPerDayRefund);
        interestRefundToBorrower = interestRefundToBorrower
            .div(86400);

        if (closePrincipal < loanLocal.principal) {
            loanInterestLocal.depositTotal = loanInterestLocal.depositTotal
                .sub(interestRefundToBorrower);
        } else {
            loanInterestLocal.depositTotal = 0;
        }
        loanInterestLocal.updatedTimestamp = interestTime;

        // update remaining lender interest values
        lenderInterestLocal.principalTotal = lenderInterestLocal.principalTotal
            .sub(closePrincipal);
        lenderInterestLocal.owedTotal = lenderInterestLocal.owedTotal
            .sub(interestRefundToBorrower);

        return interestRefundToBorrower;
    }

    function _emitClosingEvents(
        LoanParams memory loanParamsLocal,
        Loan memory loanLocal,
        uint256 loanCloseAmount,
        uint256 collateralCloseAmount,
        uint256 collateralToLoanRate,
        uint256 currentMargin,
        uint256 closeType)
        internal
    {
        if (closeType == 0) {
            emit CloseWithDeposit(
                loanLocal.id,
                loanLocal.borrower,
                loanLocal.lender,
                loanParamsLocal.loanToken,
                loanParamsLocal.collateralToken,
                loanCloseAmount,
                collateralCloseAmount,
                collateralToLoanRate,
                currentMargin
            );
        } else if (closeType == 1) {
            // exitPrice = 1 / collateralToLoanRate
            collateralToLoanRate = SafeMath.div(10**36, collateralToLoanRate);

            // currentLeverage = 100 / currentMargin
            currentMargin = SafeMath.div(10**38, currentMargin);

            emit CloseWithSwap(
                loanLocal.borrower,                             // trader
                loanParamsLocal.collateralToken,                // baseToken
                loanParamsLocal.loanToken,                      // quoteToken
                loanLocal.lender,                               // lender
                loanLocal.id,                                   // loanId
                collateralCloseAmount,                          // positionCloseSize
                loanCloseAmount,                                // loanCloseAmount
                collateralToLoanRate,                           // exitPrice
                currentMargin                                   // currentLeverage
            );
        } else { // closeType == 3
            emit Liquidate(
                loanLocal.id,
                loanLocal.borrower,
                loanLocal.lender,
                loanParamsLocal.loanToken,
                loanParamsLocal.collateralToken,
                loanCloseAmount,
                collateralCloseAmount,
                collateralToLoanRate,
                currentMargin
            );
        }
    }
}