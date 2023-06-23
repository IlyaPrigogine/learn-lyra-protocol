//SPDX-License-Identifier: ISC
pragma solidity 0.8.16;
import "./synthetix/DecimalMath.sol";
import "./libraries/ConvertDecimals.sol";
import "./synthetix/OwnedUpgradeable.sol";
import "./interfaces/IERC20Decimals.sol";
abstract contract BaseExchangeAdapter is OwnedUpgradeable {
  enum PriceType {
    MIN_PRICE,
    MAX_PRICE,
    REFERENCE,
    FORCE_MIN,
    FORCE_MAX
  }
  mapping(address => bool) public isMarketPaused;
  bool public isGlobalPaused;
  uint[48] private __gap;
  function initialize() external initializer {
    __Ownable_init();
  }
  // settings
  function setMarketPaused(address optionMarket, bool isPaused) external onlyOwner {
    if (optionMarket == address(0)) {
      revert InvalidAddress(address(this), optionMarket);
    }
    isMarketPaused[optionMarket] = isPaused;
    emit MarketPausedSet(optionMarket, isPaused);
  }
  function setGlobalPaused(bool isPaused) external onlyOwner {
    isGlobalPaused = isPaused;
    emit GlobalPausedSet(isPaused);
  }
  // views
  function requireNotGlobalPaused(address optionMarket) external view {
    _checkNotGlobalPaused();
  }
  function requireNotMarketPaused(address optionMarket) external view notPaused(optionMarket) {}
  function rateAndCarry(address) external view virtual returns (int) {
    revert NotImplemented(address(this));
  }
  function getSpotPriceForMarket(address optionMarket, PriceType pricing) external view virtual notPaused(optionMarket) returns (uint spotPrice) {
    revert NotImplemented(address(this));
  }
  function getSettlementPriceForMarket(address optionMarket, uint expiry) external view virtual notPaused(optionMarket) returns (uint spotPrice) {
    revert NotImplemented(address(this));
  }
  function estimateExchangeToExactQuote(address optionMarket, uint amountQuote) external view virtual returns (uint baseNeeded) {
    revert NotImplemented(address(this));
  }
  function estimateExchangeToExactBase(address optionMarket, uint amountBase) external view virtual returns (uint quoteNeeded) {
    revert NotImplemented(address(this));
  }

  // func
  function exchangeFromExactBase(address optionMarket, uint amountBase) external virtual returns (uint quoteReceived) {
    revert NotImplemented(address(this));
  }
  function exchangeFromExactQuote(address optionMarket, uint amountQuote) external virtual returns (uint baseReceived) {
    revert NotImplemented(address(this));
  }
  function exchangeToExactBaseWithLimit(address optionMarket, uint amountBase, uint quoteLimit) external virtual returns (uint quoteSpent, uint baseReceived) {
    revert NotImplemented(address(this));
  }
  function exchangeToExactBase(address optionMarket, uint amountBase) external virtual returns (uint quoteSpent, uint baseReceived) {
    revert NotImplemented(address(this));
  }
  function exchangeToExactQuoteWithLimit(address optionMarket, uint amountQuote, uint baseLimit) external virtual returns (uint quoteSpent, uint baseReceived) {
    revert NotImplemented(address(this));
  }
  function exchangeToExactQuote(address optionMarket, uint amountQuote) external virtual returns (uint baseSpent, uint quoteReceived) {
    revert NotImplemented(address(this));
  }

  // internal
  function _receiveAsset(IERC20Decimals asset, uint amount) internal returns (uint convertedAmount) {
    convertedAmount = ConvertDecimals.convertFrom18(amount, asset.decimals());
    if (!asset.transferFrom(msg.sender, address(this), convertedAmount)) {
      revert AssetTransferFailed(address(this), asset, msg.sender, address(this), convertedAmount);
    }
  }
  function _transferAsset(IERC20Decimals asset, address recipient, uint amount) internal {
    uint convertedAmount = ConvertDecimals.convertFrom18(amount, asset.decimals());
    if (!asset.transfer(recipient, convertedAmount)) {
      revert AssetTransferFailed(address(this), asset, address(this), recipient, convertedAmount);
    }
  }
  function _checkNotGlobalPaused() internal view {
    if (isGlobalPaused) {
      revert AllMarketsPaused(address(this));
    }
  }
  function _checkNotMarketPaused(address contractAddress) internal view {
    if (isMarketPaused[contractAddress]) {
      revert MarketIsPaused(address(this), contractAddress);
    }
  }
  modifier notPaused(address contractAddress) {
    _checkNotGlobalPaused();
    _checkNotMarketPaused(contractAddress);
    _;
  }

  event GlobalPausedSet(bool isPaused);
  event MarketPausedSet(address indexed contractAddress, bool isPaused);
  event BaseSwappedForQuote(address indexed marketAddress, address indexed exchanger, uint baseSwapped, uint quoteReceived);
  event QuoteSwappedForBase(address indexed marketAddress, address indexed exchanger, uint quoteSwapped, uint baseReceived);
  error InvalidAddress(address thrower, address inputAddress);
  error NotImplemented(address thrower);
  error AllMarketsPaused(address thrower);
  error MarketIsPaused(address thrower, address marketAddress);
  error AssetTransferFailed(address thrower, IERC20Decimals asset, address sender, address receiver, uint amount);
  error TransferFailed(address thrower, IERC20Decimals asset, address from, address to, uint amount);
  error InsufficientSwap(address thrower, uint amountOut, uint minAcceptedOut, IERC20Decimals tokenIn, IERC20Decimals tokenOut, address receiver);
  error QuoteBaseExchangeExceedsLimit(address thrower, uint amountBaseRequested, uint quoteToSpend, uint quoteLimit, uint spotPrice, bytes32 quoteKey, bytes32 baseKey);
  error BaseQuoteExchangeExceedsLimit(address thrower, uint amountQuoteRequested, uint baseToSpend, uint baseLimit, uint spotPrice, bytes32 baseKey, bytes32 quoteKey);
}
