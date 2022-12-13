//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Spot Market Wrapper Interface
interface IWrapper {
    error InsufficientFunds();
    error InsufficientAllowance(uint expected, uint current);

    event WrapperInitialized(uint indexed synthMarketId, address collateralType);
    event SynthWrapped(uint indexed synthMarketId, uint amountWrapped, uint feesCollected);
    event SynthUnwrapped(uint indexed synthMarketId, uint amountUnwrapped, uint feesCollected);

    function initializeWrapper(uint128 marketId, address collateralType) external;

    function wrap(uint128 marketId, uint wrapAmount) external returns (uint);

    function unwrap(uint128 marketId, uint unwrapAmount) external returns (uint);

    function getWrapQuote(uint128 marketId, uint wrapAmount) external view returns (uint, uint);

    function getUnwrapQuote(uint128 marketId, uint unwrapAmount) external view returns (uint, uint);
}
