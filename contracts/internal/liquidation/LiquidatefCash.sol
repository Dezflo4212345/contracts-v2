// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "./LiquidationHelpers.sol";
import "../AccountContextHandler.sol";
import "../valuation/AssetHandler.sol";
import "../markets/CashGroup.sol";
import "../markets/AssetRate.sol";
import "../valuation/ExchangeRate.sol";
import "../portfolio/PortfolioHandler.sol";
import "../portfolio/BitmapAssetsHandler.sol";
import "../../external/FreeCollateralExternal.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library LiquidatefCash {
    using SafeMath for uint256;
    using SafeInt256 for int256;
    using ExchangeRate for ETHRate;
    using AssetHandler for PortfolioAsset;
    using CashGroup for CashGroupParameters;
    using AssetRate for AssetRateParameters;
    using AccountContextHandler for AccountContext;
    using PortfolioHandler for PortfolioState;

    /// @notice Calculates the risk adjusted and liquidation discount factors used when liquidating fCash. The
    /// The risk adjusted discount factor is used to value fCash, the liquidation discount factor is used to 
    /// calculate the price of the fCash asset at a discount to the risk adjusted factor.
    function _calculatefCashDiscounts(
        LiquidationFactors memory factors,
        uint256 maturity,
        uint256 blockTime,
        bool isNotionalPositive
    ) private view returns (int256 riskAdjustedDiscountFactor, int256 liquidationDiscountFactor) {
        uint256 oracleRate = factors.cashGroup.calculateOracleRate(maturity, blockTime);
        uint256 timeToMaturity = maturity.sub(blockTime);

        if (isNotionalPositive) {
            // This is the discount factor used to calculate the fCash present value during free collateral
            riskAdjustedDiscountFactor = AssetHandler.getDiscountFactor(
                timeToMaturity,
                oracleRate.add(factors.cashGroup.getfCashHaircut())
            );

            // This is the discount factor that liquidators get to purchase fCash at, will be larger than
            // the risk adjusted discount factor.
            liquidationDiscountFactor = AssetHandler.getDiscountFactor(
                timeToMaturity,
                oracleRate.add(factors.cashGroup.getLiquidationfCashHaircut())
            );
        } else {
            uint256 buffer = factors.cashGroup.getDebtBuffer();
            riskAdjustedDiscountFactor = AssetHandler.getDiscountFactor(
                timeToMaturity,
                oracleRate < buffer ? 0 : oracleRate.sub(buffer)
            );

            buffer = factors.cashGroup.getLiquidationDebtBuffer();
            liquidationDiscountFactor = AssetHandler.getDiscountFactor(
                timeToMaturity,
                oracleRate < buffer ? 0 : oracleRate.sub(buffer)
            );
        }
    }

    /// @notice Returns the fCashNotional for a given account, currency and maturity.
    /// @return the notional amount
    function _getfCashNotional(
        address liquidateAccount,
        fCashContext memory context,
        uint256 currencyId,
        uint256 maturity
    ) private view returns (int256) {
        if (context.accountContext.bitmapCurrencyId == currencyId) {
            return
                BitmapAssetsHandler.getifCashNotional(liquidateAccount, currencyId, maturity);
        }

        PortfolioAsset[] memory portfolio = context.portfolio.storedAssets;
        for (uint256 i = 0; i < portfolio.length; i++) {
            PortfolioAsset memory asset = portfolio[i];
            if (
                asset.currencyId == currencyId &&
                asset.assetType == Constants.FCASH_ASSET_TYPE &&
                asset.maturity == maturity
            ) {
                return asset.notional;
            }
        }

        // If asset is not found then we return zero instead of failing in the case that a previous
        // liquidation has already liquidated the specified fCash asset. This liquidation can continue
        // to the next specified fCash asset.
        return 0;
    }

    struct fCashContext {
        AccountContext accountContext;
        LiquidationFactors factors;
        PortfolioState portfolio;
        int256 localCashBalanceUnderlying;
        int256 underlyingBenefitRequired;
        int256 localAssetCashFromLiquidator;
        int256 liquidationDiscount;
        int256[] fCashNotionalTransfers;
    }

    /// @notice Allows the liquidator to purchase fCash in the same currency that a debt is denominated in. It's
    /// also possible that there is no debt in the local currency, in that case the liquidated account will gain the
    /// benefit of the difference between the discounted fCash value and the cash
    function liquidatefCashLocal(
        address liquidateAccount,
        uint256 localCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts,
        fCashContext memory c,
        uint256 blockTime
    ) internal view {
        if (c.factors.localAssetAvailable > 0) {
            require(c.factors.localETHRate.haircut > 0);
            // If local available is positive then we can bring it down to zero, this can occur when the
            // account is undercollateralized and there is value in trading it's fCash for cash. The value
            // will be in the difference between the risk adjusted haircut value and the resulting cash it
            // receives from the liquidator. This will likely be a very small amount.

            // Formula here: convertToLocal(netETHFCShortfall) = localRequired * haircut
            // localRequired = convertToLocal(netETHFCShortfall) / haircut
            // haircut is used because localAssetAvailable > 0

            // prettier-ignore
            c.underlyingBenefitRequired = c.factors.localETHRate
                .convertETHTo(c.factors.netETHValue.neg())
                .mul(Constants.PERCENTAGE_DECIMALS)
                .div(c.factors.localETHRate.haircut);
        } else {
            // If local available is negative then we can bring it up to zero. In this case positive
            // local collateral (either cash or fCash) will be exchanged for either removing debt (transfer
            // of negative fCash) or purchasing positive fCash for cash (removing the haircut on fCash).
            c.underlyingBenefitRequired = c.factors.localAssetRate.convertToUnderlying(
                c.factors.localAssetAvailable.neg()
            );
        }

        for (uint256 i = 0; i < fCashMaturities.length; i++) {
            int256 notional =
                _getfCashNotional(liquidateAccount, c, localCurrency, fCashMaturities[i]);
            // If a notional balance is negative, ensure that there is some local cash balance to
            // purchase for the liquidation. Allow a zero cash balance so that the loop continues even if
            // all of the cash balance has been transferred.
            if (notional < 0) require(c.localCashBalanceUnderlying >= 0); // dev: insufficient cash balance
            if (notional == 0) continue;

            // If notional > 0 then liquidation discount > risk adjusted discount
            //    this is because the liquidation oracle rate < risk adjusted oracle rate
            // If notional < 0 then liquidation discount < risk adjusted discount
            //    this is because the liquidation oracle rate > risk adjusted oracle rate
            (int256 riskAdjustedDiscountFactor, int256 liquidationDiscountFactor) =
                _calculatefCashDiscounts(c.factors, fCashMaturities[i], blockTime, notional > 0);

            // The benefit to the liquidated account is the difference between the liquidation discount factor
            // and the risk adjusted discount factor:
            // localCurrencyBenefit = fCash * (liquidationDiscountFactor - riskAdjustedDiscountFactor)
            // fCash = localCurrencyBenefit / (liquidationDiscountFactor - riskAdjustedDiscountFactor)
            // abs is used here to ensure positive values
            c.fCashNotionalTransfers[i] = c.underlyingBenefitRequired
            // NOTE: Governance should be set such that these discount factors are unlikely to be zero. It's
            // possible that the interest rates are so low that this situation can occur.
                .divInRatePrecision(liquidationDiscountFactor.sub(riskAdjustedDiscountFactor).abs());

            // fCashNotionalTransfers[i] is always positive at this point. The max liquidate amount is
            // calculated using the absolute value of the notional amount to ensure that the inequalities
            // operate properly inside calculateLiquidationAmount.
            c.fCashNotionalTransfers[i] = LiquidationHelpers.calculateLiquidationAmount(
                c.fCashNotionalTransfers[i], // liquidate amount required
                notional.abs(), // max total balance
                SafeInt256.toInt(maxfCashLiquidateAmounts[i]) // user specified maximum
            );

            // This is the price the liquidator pays of the fCash that has been liquidated
            int256 fCashLiquidationValueUnderlying =
                c.fCashNotionalTransfers[i].mulInRatePrecision(liquidationDiscountFactor);

            if (notional < 0) {
                // In the case of negative notional amounts, limit the amount of liquidation to the local cash
                // balance in underlying so that the liquidated account does not incur a negative cash balance.
                if (fCashLiquidationValueUnderlying > c.localCashBalanceUnderlying) {
                    // We know that all these values are positive at this point.
                    c.fCashNotionalTransfers[i] = c.fCashNotionalTransfers[i]
                        .mul(c.localCashBalanceUnderlying)
                        .div(fCashLiquidationValueUnderlying);
                    fCashLiquidationValueUnderlying = c.localCashBalanceUnderlying;
                }

                // Flip the sign when the notional is negative
                c.fCashNotionalTransfers[i] = c.fCashNotionalTransfers[i].neg();
                // When the notional is negative, cash balance will be transferred to the liquidator instead of
                // being provided by the liquidator.
                fCashLiquidationValueUnderlying = fCashLiquidationValueUnderlying.neg();
            }

            // NOTE: localAssetCashFromLiquidator is actually in underlying terms during this loop, it is converted to asset terms just once
            // at the end of the loop to limit loss of precision
            c.localAssetCashFromLiquidator = c.localAssetCashFromLiquidator.add(
                fCashLiquidationValueUnderlying
            );
            c.localCashBalanceUnderlying = c.localCashBalanceUnderlying.add(
                fCashLiquidationValueUnderlying
            );

            // Deduct the total benefit gained from liquidating this fCash position
            c.underlyingBenefitRequired = c.underlyingBenefitRequired.sub(
                c.fCashNotionalTransfers[i]
                    .mulInRatePrecision(liquidationDiscountFactor.sub(riskAdjustedDiscountFactor).abs())
                    .abs()
            );

            if (c.underlyingBenefitRequired <= Constants.LIQUIDATION_DUST) break;
        }

        // Convert local to purchase to asset terms for transfers
        c.localAssetCashFromLiquidator = c.factors.localAssetRate.convertFromUnderlying(
            c.localAssetCashFromLiquidator
        );
    }

    /// @notice Allows the liquidator to purchase fCash in a different currency that a debt is denominated in.
    function liquidatefCashCrossCurrency(
        address liquidateAccount,
        uint256 collateralCurrency,
        uint256[] calldata fCashMaturities,
        uint256[] calldata maxfCashLiquidateAmounts,
        fCashContext memory c,
        uint256 blockTime
    ) internal view {
        require(c.factors.localAssetAvailable < 0); // dev: no local debt
        require(c.factors.collateralAssetAvailable > 0); // dev: no collateral assets

        c.fCashNotionalTransfers = new int256[](fCashMaturities.length);
        {
            // NOTE: underlying benefit is return in asset terms from this function, convert it to underlying
            // for the purposes of this method
            (c.underlyingBenefitRequired, c.liquidationDiscount) = LiquidationHelpers
                .calculateCrossCurrencyBenefitAndDiscount(c.factors);
            c.underlyingBenefitRequired = c.factors.cashGroup.assetRate.convertToUnderlying(
                c.underlyingBenefitRequired
            );
        }

        for (uint256 i = 0; i < fCashMaturities.length; i++) {
            int256 notional =
                _getfCashNotional(liquidateAccount, c, collateralCurrency, fCashMaturities[i]);
            if (notional == 0) continue;
            require(notional > 0); // dev: invalid fcash asset

            c.fCashNotionalTransfers[i] = _calculateCrossCurrencyfCashToLiquidate(
                c,
                fCashMaturities[i],
                blockTime,
                SafeInt256.toInt(maxfCashLiquidateAmounts[i]),
                notional
            );

            if (
                c.underlyingBenefitRequired <= Constants.LIQUIDATION_DUST ||
                c.factors.collateralAssetAvailable == 0
            ) break;
        }
    }

    function _calculateCrossCurrencyfCashToLiquidate(
        fCashContext memory c,
        uint256 maturity,
        uint256 blockTime,
        int256 maxfCashLiquidateAmount,
        int256 notional
    ) private view returns (int256) {
        (int256 riskAdjustedDiscountFactor, int256 liquidationDiscountFactor) =
            _calculatefCashDiscounts(c.factors, maturity, blockTime, true);

        // collateralPurchased = fCashToLiquidate * fCashDiscountFactor
        // (see: _calculateCollateralToRaise)
        // collateralBenefit = collateralPurchased * (localBuffer / liquidationDiscount - collateralHaircut)
        // totalBenefit = fCashBenefit + collateralBenefit
        // totalBenefit = fCashToLiquidate * (liquidationDiscountFactor - riskAdjustedDiscountFactor) +
        //      fCashToLiquidate * liquidationDiscountFactor * (localBuffer / liquidationDiscount - collateralHaircut)
        // totalBenefit = fCashToLiquidate * [
        //      (liquidationDiscountFactor - riskAdjustedDiscountFactor) +
        //      (liquidationDiscountFactor * (localBuffer / liquidationDiscount - collateralHaircut))
        // ]
        // fCashToLiquidate = totalBenefit / [
        //      (liquidationDiscountFactor - riskAdjustedDiscountFactor) +
        //      (liquidationDiscountFactor * (localBuffer / liquidationDiscount - collateralHaircut))
        // ]
        int256 benefitDivisor;
        {
            // -ok
            // prettier-ignore
            int256 termTwo = (
                    c.factors.localETHRate.buffer.mul(Constants.PERCENTAGE_DECIMALS).div(
                        c.liquidationDiscount
                    )
                ).sub(c.factors.collateralETHRate.haircut);
            termTwo = liquidationDiscountFactor.mul(termTwo).div(Constants.PERCENTAGE_DECIMALS);
            int256 termOne = liquidationDiscountFactor.sub(riskAdjustedDiscountFactor);
            benefitDivisor = termOne.add(termTwo);
        }

        int256 fCashToLiquidate =
            c.underlyingBenefitRequired.divInRatePrecision(benefitDivisor);

        fCashToLiquidate = LiquidationHelpers.calculateLiquidationAmount(
            fCashToLiquidate,
            notional,
            maxfCashLiquidateAmount
        );

        // Ensures that local available does not go above zero and collateral available does not go below zero
        int256 localAssetCashFromLiquidator;
        (fCashToLiquidate, localAssetCashFromLiquidator) = _limitPurchaseByAvailableAmounts(
            c,
            liquidationDiscountFactor,
            riskAdjustedDiscountFactor,
            fCashToLiquidate
        );

        // inverse of initial fCashToLiquidate calculation above
        // totalBenefit = fCashToLiquidate * [
        //      (liquidationDiscountFactor - riskAdjustedDiscountFactor) +
        //      (liquidationDiscountFactor * (localBuffer / liquidationDiscount - collateralHaircut))
        // ]
        int256 benefitGainedUnderlying = fCashToLiquidate.mulInRatePrecision(benefitDivisor);

        c.underlyingBenefitRequired = c.underlyingBenefitRequired.sub(benefitGainedUnderlying);
        c.localAssetCashFromLiquidator = c.localAssetCashFromLiquidator.add(
            localAssetCashFromLiquidator
        );

        return fCashToLiquidate;
    }

    /// @dev Limits the fCash purchase to ensure that collateral available and local available do not go below zero,
    /// in both those cases the liquidated account would incur debt
    function _limitPurchaseByAvailableAmounts(
        fCashContext memory c,
        int256 liquidationDiscountFactor,
        int256 riskAdjustedDiscountFactor,
        int256 fCashToLiquidate
    ) private pure returns (int256, int256) {
        // The collateral value of the fCash is discounted back to PV given the liquidation discount factor,
        // this is the discounted value that the liquidator will purchase it at.
        int256 fCashLiquidationUnderlyingPV = fCashToLiquidate.mulInRatePrecision(liquidationDiscountFactor);
        int256 fCashRiskAdjustedUnderlyingPV = fCashToLiquidate.mulInRatePrecision(riskAdjustedDiscountFactor);

        // Ensures that collateralAssetAvailable does not go below zero
        int256 collateralUnderlyingAvailable =
            c.factors.cashGroup.assetRate.convertToUnderlying(c.factors.collateralAssetAvailable);
        if (fCashRiskAdjustedUnderlyingPV > collateralUnderlyingAvailable) {
            // If inside this if statement then all collateralAssetAvailable should be coming from fCashRiskAdjustedPV
            // collateralAssetAvailable = fCashRiskAdjustedPV
            // collateralAssetAvailable = fCashToLiquidate * riskAdjustedDiscountFactor
            // fCashToLiquidate = collateralAssetAvailable / riskAdjustedDiscountFactor
            fCashToLiquidate = collateralUnderlyingAvailable.divInRatePrecision(riskAdjustedDiscountFactor);

            fCashRiskAdjustedUnderlyingPV = collateralUnderlyingAvailable;

            // Recalculate the PV at the new liquidation amount
            fCashLiquidationUnderlyingPV = fCashToLiquidate.mulInRatePrecision(liquidationDiscountFactor);
        }

        int256 localAssetCashFromLiquidator;
        (fCashToLiquidate, localAssetCashFromLiquidator) = LiquidationHelpers.calculateLocalToPurchase(
            c.factors,
            c.liquidationDiscount,
            fCashLiquidationUnderlyingPV,
            fCashToLiquidate
        );

        // As we liquidate here the local available and collateral available will change. Update values accordingly so
        // that the limits will be hit on subsequent iterations.
        c.factors.collateralAssetAvailable = c.factors.collateralAssetAvailable.subNoNeg(
            c.factors.cashGroup.assetRate.convertFromUnderlying(fCashRiskAdjustedUnderlyingPV)
        );
        // Cannot have a negative value here, local asset available should always increase as a result of
        // cross currency liquidation.
        require(localAssetCashFromLiquidator >= 0);
        c.factors.localAssetAvailable = c.factors.localAssetAvailable.add(
            localAssetCashFromLiquidator
        );

        return (fCashToLiquidate, localAssetCashFromLiquidator);
    }

    /// @dev Finalizes fCash liquidation for both local and cross currency liquidation
    function finalizefCashLiquidation(
        address liquidateAccount,
        address liquidator,
        uint16 localCurrency,
        uint16 fCashCurrency,
        uint256[] calldata fCashMaturities,
        fCashContext memory c
    ) internal returns (int256[] memory, int256) {
        // Liquidator deposits or receives cash to the liquidated account.
        AccountContext memory liquidatorContext =
            LiquidationHelpers.finalizeLiquidatorLocal(
                liquidator,
                localCurrency,
                c.localAssetCashFromLiquidator,
                0
            );

        // Liquidated account gets the cash from the liquidator
        LiquidationHelpers.finalizeLiquidatedLocalBalance(
            liquidateAccount,
            localCurrency,
            c.accountContext,
            c.localAssetCashFromLiquidator
        );

        bool liquidatorIncursDebt;
        (liquidatorIncursDebt, liquidatorContext) =
            _transferAssets(
                liquidateAccount,
                liquidator,
                liquidatorContext,
                fCashCurrency,
                fCashMaturities,
                c
            );

        liquidatorContext.setAccountContext(liquidator);
        c.accountContext.setAccountContext(liquidateAccount);

        // If the liquidator takes on debt as a result of the liquidation and has debt in their portfolio
        // then they must have a free collateral check. It's possible for the liquidator to skip this if the
        // negative fCash incurred from the liquidation nets off against an existing fCash position.
        if (liquidatorIncursDebt && liquidatorContext.hasDebt != 0x00) {
            FreeCollateralExternal.checkFreeCollateralAndRevert(liquidator);
        }

        return (c.fCashNotionalTransfers, c.localAssetCashFromLiquidator);
    }

    function _transferAssets(
        address liquidateAccount,
        address liquidator,
        AccountContext memory liquidatorContext,
        uint256 fCashCurrency,
        uint256[] calldata fCashMaturities,
        fCashContext memory c
    ) private returns (bool, AccountContext memory) {
        (PortfolioAsset[] memory assets, bool liquidatorIncursDebt) =
            _makeAssetArray(fCashCurrency, fCashMaturities, c.fCashNotionalTransfers);

        // NOTE: if the liquidator has assets that need to be settled this will fail, automatic
        // settlement is not done here due to the bytecode limit
        liquidatorContext = TransferAssets.placeAssetsInAccount(
            liquidator,
            liquidatorContext,
            assets
        );
        TransferAssets.invertNotionalAmountsInPlace(assets);

        if (c.accountContext.isBitmapEnabled()) {
            BitmapAssetsHandler.addMultipleifCashAssets(liquidateAccount, c.accountContext, assets);
        } else {
            // Don't use the placeAssetsInAccount method here since we already have the
            // portfolio state.
            c.portfolio.addMultipleAssets(assets);
            AccountContextHandler.storeAssetsAndUpdateContext(
                c.accountContext,
                liquidateAccount,
                c.portfolio,
                false // Although this is liquidation, we should not allow past max assets here
            );
        }

        return (liquidatorIncursDebt, liquidatorContext);
    }

    function _makeAssetArray(
        uint256 fCashCurrency,
        uint256[] calldata fCashMaturities,
        int256[] memory fCashNotionalTransfers
    ) private pure returns (PortfolioAsset[] memory, bool) {
        require(fCashMaturities.length == fCashNotionalTransfers.length);

        PortfolioAsset[] memory assets = new PortfolioAsset[](fCashMaturities.length);
        bool liquidatorIncursDebt = false;
        for (uint256 i = 0; i < fCashMaturities.length; i++) {
            PortfolioAsset memory asset = assets[i];
            asset.currencyId = fCashCurrency;
            asset.assetType = Constants.FCASH_ASSET_TYPE;
            asset.notional = fCashNotionalTransfers[i];
            asset.maturity = fCashMaturities[i];

            if (asset.notional < 0) liquidatorIncursDebt = true;
        }

        return (assets, liquidatorIncursDebt);
    }
}
