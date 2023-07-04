//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {SafeCastI256, SafeCastU256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {INodeModule} from "@synthetixio/oracle-manager/contracts/interfaces/INodeModule.sol";
import {Error} from "./Error.sol";
import {Order} from "./Order.sol";
import {PerpMarket} from "./PerpMarket.sol";
import {PerpMarketFactoryConfiguration} from "./PerpMarketFactoryConfiguration.sol";
import {PerpCollateral} from "./PerpCollateral.sol";
import {MathUtil} from "../utils/MathUtil.sol";

/**
 * @dev An open position on a specific perp market within bfp-market.
 */
library Position {
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;
    using PerpMarket for PerpMarket.Data;

    // --- Structs --- //

    struct TradeParams {
        int128 sizeDelta;
        uint256 oraclePrice;
        uint256 fillPrice;
        uint128 makerFee;
        uint128 takerFee;
        uint256 limitPrice;
    }

    // --- Storage --- //

    struct Data {
        // Owner of position.
        uint128 accountId;
        // Market this position belongs to (e.g. wstETHPERP)
        uint128 marketId;
        // Size (in native units e.g. wstETH)
        int128 size;
        // The market's accumulated accrued funding at position open.
        int256 entryFundingValue;
        // The fill price at which this position was opened with.
        uint256 entryPrice;
        // Cost in USD to open this positions (e.g. keeper + order fees).
        uint256 feesIncurredUsd;
    }

    /**
     * @dev Given an open position (same account) and trade params return the subsequent position.
     *
     * Keeping this as postTradeDetails (same as perps v2) until I can figure out a better name.
     */
    function postTradeDetails(
        uint128 accountId,
        uint128 marketId,
        Position.Data storage currentPosition,
        TradeParams memory params
    ) internal returns (Position.Data memory newPosition, uint256 fee, uint256 keeperFee) {
        if (params.sizeDelta == 0) {
            revert Error.NilOrder();
        }

        // TODO: Check if the `currentPosition` can be immediately liquidated, if so, revert.

        PerpMarket.Data storage market = PerpMarket.exists(marketId);
        fee = Order.orderFee(params.sizeDelta, params.fillPrice, market.skew, params.makerFee, params.takerFee);
        keeperFee = Order.keeperFee(market.minKeeperFeeUsd, market.maxKeeperFeeUsd);

        // Assuming there is an existing position (no open position will be a noop), determine if they have enough
        // margin to continue this operation. Ensuring we do not allow them to place an open position into instant
        // liquidation. This can be done by inferring their "remainingMargin".
        //
        // We do this by inferring the `remainingMargin = (sum(collateral * price)) + pnl + fundingAcrrued - fee` such that
        // if remainingMargin < minMarginThreshold then this must revert.
        //
        // NOTE: The use of fillPrice and not oraclePrice to perform calculations below. Also consider this is the
        // "raw" remaining margin which does not account for fees (liquidation fees, penalties, liq premium fees etc.).
        int256 _remainingMargin = remainingMargin(currentPosition, params.fillPrice);
        if (_remainingMargin < 0) {
            revert Error.InsufficientMargin();
        }

        uint256 absSize = MathUtil.abs(currentPosition.size);

        // Checks whether the current position's margin (if above 0), doesn't fall below min margin for liqudations.
        uint256 _liquidationMargin = liquidationMargin(currentPosition, params.fillPrice);
        if (absSize != 0 && _remainingMargin.toUint() <= _liquidationMargin) {
            revert Error.CanLiquidatePosition(accountId);
        }

        newPosition = Position.Data({
            accountId: accountId,
            marketId: marketId,
            size: currentPosition.size + params.sizeDelta,
            entryFundingValue: market.fundingAccruedLastComputed,
            entryPrice: params.fillPrice,
            feesIncurredUsd: fee + keeperFee
        });

        // Check if the new position is safe... but why not just perform the update to newPosition and perform
        // all checks on `newPosition`? :thinking:

        // TODO: V2 checks if the min margin is met. If not throw, however we may not need this.

        // TODO: Check that the resulting new postion's margin is above liquidationMargin + liqPremium

        // TODO: Check new position hasn't hit max leverage.

        // TODO: Check new position hasn't hit max oi on either side.
    }

    // --- Memebr --- //

    /**
     * @dev Returns a position's accrued funding.
     */
    function accruedFunding(Position.Data storage self, uint256 price) internal view returns (int256) {
        if (self.size == 0) {
            return 0;
        }

        PerpMarket.Data storage market = PerpMarket.load(self.marketId);
        int256 netFundingPerUnit = market.nextFunding(price) - self.entryFundingValue;
        return self.size * netFundingPerUnit;
    }

    /**
     * @dev Returns the `sum(p.collaterals.map(c => c.amount * c.price))`.
     */
    function collateralUsd(Position.Data storage self) internal view returns (uint256) {
        PerpMarketFactoryConfiguration.Data storage config = PerpMarketFactoryConfiguration.load();

        uint256 collateralValueUsd = 0;
        uint256 length = config.supportedCollateral.length;
        PerpCollateral.Data storage collaterals = PerpCollateral.load(self.accountId, self.marketId);

        PerpMarketFactoryConfiguration.Collateral memory currentCollateral;
        for (uint256 i = 0; i < length; ) {
            currentCollateral = config.supportedCollateral[i];

            uint256 price = INodeModule(config.oracleManager).process(currentCollateral.oracleNodeId).price.toUint();
            collateralValueUsd += collaterals.collateral[currentCollateral.collateral] * price;

            unchecked {
                i++;
            }
        }

        return collateralValueUsd;
    }

    /**
     * @dev Return a position's remaining margin.
     *
     * The remaining margin is defined as sum(collateral * price) + PnL + funding in USD.
     *
     * We return an `int` here as after all fees and PnL, this can be negative. The caller should verify that this
     * is positive before proceeding with further operations.
     */
    function remainingMargin(Position.Data storage self, uint256 price) internal view returns (int256) {
        int256 margin = collateralUsd(self).toInt();
        int256 funding = accruedFunding(self, price);

        // Calculcate this position's PnL
        int256 priceDelta = price.toInt() - self.entryPrice.toInt();
        int256 pnl = self.size * priceDelta;

        return margin + pnl + funding;
    }

    /**
     * @dev Returns a number in USD which if a position's remaining margin is lte then position can be liquidated.
     */
    function liquidationMargin(Position.Data storage self, uint256 price) internal view returns (uint256) {
        PerpMarket.Data storage market = PerpMarket.load(self.marketId);
        uint256 absSize = MathUtil.abs(self.size);

        // Calculcates the liquidation buffer (penalty).
        //
        // e.g. 3 * 1800 * 0.0075 = 40.5
        uint256 liquidationBuffer = absSize * price * market.liquidationBufferRatio;

        // Calculcates the liquidation fee.
        //
        // This is a fee charged against the margin on liquidation and paid to LPers. The fee is proportional to
        // the position size and bounded by `min >= liqFee <= max`. This proportion is based on each market's
        // configured liquidation fee ratio.
        //
        // e.g. 3 * 1800 * 0.0002 = 1.08
        uint256 proportionalFee = absSize * price * market.liquidationFeeRatio;
        uint256 maxKeeperFee = market.maxKeeperFeeUsd;
        uint256 boundedProportionalFee = proportionalFee > maxKeeperFee ? maxKeeperFee : proportionalFee;
        uint256 minKeeperFee = market.minKeeperFeeUsd;
        uint256 boundedLiquidationFee = boundedProportionalFee > minKeeperFee ? boundedProportionalFee : minKeeperFee;

        // If the remainingMargin is <= this number then position can be liquidated.
        //
        // e.g. 40.5 + 1.08 + 2 = 43.58
        return liquidationBuffer + boundedLiquidationFee + market.keeperLiquidationFee;
    }
}
