import math

import pytest
from brownie.test import given, strategy
from tests.constants import (
    CASH_GROUP_PARAMETERS,
    MARKETS,
    NORMALIZED_RATE_TIME,
    RATE_PRECISION,
    SECONDS_IN_DAY,
    START_TIME,
)
from tests.helpers import get_market_state, impliedRateStrategy, timeToMaturityStrategy


@pytest.fixture(scope="module", autouse=True)
def market(MockMarket, accounts):
    market = accounts[0].deploy(MockMarket)
    return market


@pytest.fixture(scope="module", autouse=True)
def marketWithCToken(MockMarket, MockCToken, cTokenAggregator, accounts):
    market = accounts[0].deploy(MockMarket)
    ctoken = accounts[0].deploy(MockCToken, 8)
    # This is the identity rate
    ctoken.setAnswer(1e18)
    aggregator = cTokenAggregator.deploy(ctoken.address, {"from": accounts[0]})

    rateStorage = (aggregator.address, 8)
    market.setAssetRateMapping(1, rateStorage)
    cgParams = list(CASH_GROUP_PARAMETERS)
    market.setCashGroup(1, cgParams)

    return market


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@given(proportion=strategy("int256", min_value=0.01 * RATE_PRECISION, max_value=RATE_PRECISION))
def test_log_proportion(market, proportion):
    (lnProportion, success) = market.logProportion(proportion)

    assert success
    assert lnProportion == math.log((proportion * RATE_PRECISION) / (RATE_PRECISION - proportion))


def test_log_proportion_negative(market):
    (lnProportion, success) = market.logProportion(-RATE_PRECISION)
    assert not success


@given(
    proportion=strategy(
        "uint256", min_value=0.001 * RATE_PRECISION, max_value=0.999 * RATE_PRECISION
    )
)
def test_exchange_rate_proportion(market, proportion):
    # Tests exchange rate proportion while holding rateAnchor and rateScalar constant
    totalfCash = 1e18
    totalCashUnderlying = totalfCash * (RATE_PRECISION - proportion) / proportion
    rateAnchor = 1.05 * RATE_PRECISION
    rateScalar = 100

    (exchangeRate, success) = market.getExchangeRate(
        totalfCash, totalCashUnderlying, rateScalar, rateAnchor, 0
    )

    assert success
    assert (
        pytest.approx(math.trunc(math.log(proportion) / rateScalar + rateAnchor), abs=1)
        == exchangeRate
    )


@given(initRate=impliedRateStrategy, timeToMaturity=timeToMaturityStrategy)
def test_implied_rate_stability_on_maturity_rolldown(market, initRate, timeToMaturity):
    # Implied rates must stay constant as the maturity rolls down or else there will be arbitrage
    totalfCash = 1e18
    totalCashUnderlying = 1e18
    rateAnchor = initRate + RATE_PRECISION
    rateScalar = 100
    initialTimeToMaturity = timeToMaturity * SECONDS_IN_DAY

    (rateAnchor, _) = market.getRateAnchor(
        totalfCash, initRate, totalCashUnderlying, rateScalar, initialTimeToMaturity
    )

    impliedRate = market.getImpliedRate(
        totalfCash, totalCashUnderlying, rateScalar, rateAnchor, initialTimeToMaturity
    )

    approxImpliedRate = math.trunc(
        math.log(rateAnchor / RATE_PRECISION)
        * RATE_PRECISION
        * NORMALIZED_RATE_TIME
        / initialTimeToMaturity
    )
    assert pytest.approx(approxImpliedRate, abs=10) == impliedRate

    # Ensure that the implied rate for given proportion remains the same as we roll down. The
    # rate anchor should be updated every time. The max roll down is over the course of a 90
    # day period.
    rollDownMaturities = [initialTimeToMaturity - i * 10 * SECONDS_IN_DAY for i in range(1, 9)]
    for newTimeToMaturity in rollDownMaturities:
        (rateAnchor, _) = market.getRateAnchor(
            totalfCash, impliedRate, totalCashUnderlying, rateScalar, newTimeToMaturity
        )

        newImpliedRate = market.getImpliedRate(
            totalfCash, totalCashUnderlying, rateScalar, rateAnchor, newTimeToMaturity
        )

        # The implied rate does decay on roll down do a small degree
        assert pytest.approx(newImpliedRate, abs=100) == impliedRate


@given(
    timeToMaturity=timeToMaturityStrategy,
    proportion=strategy(
        "uint256", min_value=0.33 * RATE_PRECISION, max_value=0.66 * RATE_PRECISION
    ),
)
def test_slippage_decrease_on_rolldown(marketWithCToken, timeToMaturity, proportion):
    totalfCash = 1e18
    totalCashUnderlying = totalfCash * (RATE_PRECISION - proportion) / proportion
    initialTimeToMaturity = timeToMaturity * SECONDS_IN_DAY
    (cashGroup, _) = marketWithCToken.buildCashGroupView(1)
    marketIndex = 1

    marketState = get_market_state(
        MARKETS[0],
        totalfCash=totalfCash,
        totalCurrentCash=totalCashUnderlying,
        lastImpliedRate=0.06e9,
    )
    fCashAmount = 1e12

    # Ensure that slippage for a given trade size at the proportion will decrease as we roll down to
    # maturity
    rollDownMaturities = [initialTimeToMaturity - i * 10 * SECONDS_IN_DAY for i in range(1, 9)]
    (_, lastLendAssetCash, _) = marketWithCToken.calculateTrade(
        marketState, cashGroup, fCashAmount, initialTimeToMaturity, marketIndex
    )
    (_, lastBorrowAssetCash, _) = marketWithCToken.calculateTrade(
        marketState, cashGroup, -fCashAmount, initialTimeToMaturity, marketIndex
    )

    for newTimeToMaturity in rollDownMaturities:
        (_, lendAssetCash, _) = marketWithCToken.calculateTrade(
            marketState, cashGroup, fCashAmount, newTimeToMaturity, marketIndex
        )
        (_, borrowAssetCash, _) = marketWithCToken.calculateTrade(
            marketState, cashGroup, -fCashAmount, newTimeToMaturity, marketIndex
        )

        assert lendAssetCash != 0
        assert borrowAssetCash != 0

        # Requires less cash to lend as you get closer to maturity
        assert lendAssetCash < lastLendAssetCash
        # Borrow less cash as you get closer to maturity
        assert borrowAssetCash > lastBorrowAssetCash
        lastLendAssetCash = lendAssetCash
        lastBorrowAssetCash = borrowAssetCash


@given(
    marketIndex=strategy("uint8", min_value=1, max_value=9),
    proportion=strategy(
        "uint256", min_value=0.33 * RATE_PRECISION, max_value=0.66 * RATE_PRECISION
    ),
    impliedRate=impliedRateStrategy,
    initialCashAmount=strategy("int88", min_value=-1e16, max_value=1e16),
)
@pytest.mark.only
def test_fcash_convergence(
    marketWithCToken, marketIndex, proportion, impliedRate, initialCashAmount
):
    totalfCash = 1e18
    totalCashUnderlying = totalfCash * (RATE_PRECISION - proportion) / proportion
    (cashGroup, _) = marketWithCToken.buildCashGroupView(1)
    if initialCashAmount == 0:
        return

    marketState = get_market_state(
        MARKETS[marketIndex - 1],
        totalfCash=totalfCash,
        totalCurrentCash=totalCashUnderlying,
        lastImpliedRate=impliedRate,
    )

    fCashAmount = marketWithCToken.getfCashAmountGivenCashAmount(
        marketState, cashGroup, initialCashAmount, marketIndex, marketState[1] - START_TIME, 0
    )

    (_, cashAmount, _) = marketWithCToken.calculateTrade(
        marketState, cashGroup, fCashAmount, marketState[1] - START_TIME, marketIndex
    )

    assert pytest.approx(cashAmount, abs=2) == initialCashAmount
