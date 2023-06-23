//SPDX-License-Identifier: ISC
pragma solidity 0.8.16;
import "openzeppelin-contracts-4.4.1/utils/math/SafeCast.sol";
import "openzeppelin-contracts-4.4.1/security/ReentrancyGuard.sol";
import "./libraries/SimpleInitializable.sol";
import "./libraries/ConvertDecimals.sol";
import "./synthetix/Owned.sol";
import "./synthetix/DecimalMath.sol";
import "./interfaces/IERC20Decimals.sol";

import "./BaseExchangeAdapter.sol";
import "./LiquidityPool.sol";
import "./OptionToken.sol";
import "./OptionGreekCache.sol";
import "./ShortCollateral.sol";
import "./OptionMarketPricer.sol";

contract OptionMarket is Owned, SimpleInitializable, ReentrancyGuard {
  using DecimalMath for uint;
  enum TradeDirection {
    OPEN,
    CLOSE,
    LIQUIDATE
  }
  enum OptionType {
    LONG_CALL,
    LONG_PUT,
    SHORT_CALL_BASE,
    SHORT_CALL_QUOTE,
    SHORT_PUT_QUOTE
  }
  enum NonZeroValues {
    BASE_IV,
    SKEW,
    STRIKE_PRICE,
    ITERATIONS,
    STRIKE_ID
  }
  struct Strike {
    uint id;
    uint strikePrice;
    uint skew;
    uint longCall;
    uint shortCallBase;
    uint shortCallQuote;
    uint longPut;
    uint shortPut;
    uint boardId;
  }
  struct OptionBoard {
    uint id;
    uint expiry;
    uint iv;
    bool frozen;
    uint[] strikeIds;
  }
  struct OptionMarketParameters {
    uint maxBoardExpiry;
    address securityModule;
    uint feePortionReserved;
    uint staticBaseSettlementFee;
  }
  struct TradeInputParameters {
    uint strikeId;
    uint positionId;
    uint iterations;
    OptionType optionType;
    uint amount;
    uint setCollateralTo;
    uint minTotalCost;
    uint maxTotalCost;
    address referrer;
  }
  struct TradeParameters {
    bool isBuy;
    bool isForceClose;
    TradeDirection tradeDirection;
    OptionType optionType;
    uint amount;
    uint expiry;
    uint strikePrice;
    uint spotPrice;
    LiquidityPool.Liquidity liquidity;
  }
  struct TradeEventData {
    uint strikeId;
    uint expiry;
    uint strikePrice;
    OptionType optionType;
    TradeDirection tradeDirection;
    uint amount;
    uint setCollateralTo;
    bool isForceClose;
    uint spotPrice;
    uint reservedFee;
    uint totalCost;
  }
  struct LiquidationEventData {
    address rewardBeneficiary;
    address caller;
    uint returnCollateral;
    uint lpPremiums;
    uint lpFee;
    uint liquidatorFee;
    uint smFee;
    uint insolventAmount;
  }
  struct Result {
    uint positionId;
    uint totalCost;
    uint totalFee;
  }

  BaseExchangeAdapter internal exchangeAdapter;
  LiquidityPool internal liquidityPool;
  OptionMarketPricer internal optionPricer;
  OptionGreekCache internal greekCache;
  ShortCollateral internal shortCollateral;
  OptionToken internal optionToken;
  uint internal nextStrikeId = 1;
  uint internal nextBoardId = 1;
  uint[] internal liveBoards;
  OptionMarketParameters internal optionMarketParams;
  mapping(uint => OptionBoard) internal optionBoards;
  mapping(uint => Strike) internal strikes;
  mapping(uint => uint) internal strikeToBaseReturnedRatio;

  IERC20Decimals public quoteAsset;
  IERC20Decimals public baseAsset;
  mapping(uint => uint) public boardToPriceAtExpiry;
  mapping(uint => uint) public scaledLongsForBoard;
  constructor() Owned() {}

  // settings
  function init(BaseExchangeAdapter _exchangeAdapter, LiquidityPool _liquidityPool, OptionMarketPricer _optionPricer, OptionGreekCache _greekCache, ShortCollateral _shortCollateral, OptionToken _optionToken, IERC20Decimals _quoteAsset, IERC20Decimals _baseAsset) external onlyOwner initializer {
    exchangeAdapter = _exchangeAdapter;
    liquidityPool = _liquidityPool;
    optionPricer = _optionPricer;
    greekCache = _greekCache;
    shortCollateral = _shortCollateral;
    optionToken = _optionToken;
    quoteAsset = _quoteAsset;
    baseAsset = _baseAsset;
  }
  function createOptionBoard(uint expiry, uint baseIV, uint[] memory strikePrices, uint[] memory skews, bool frozen) external onlyOwner returns (uint boardId) {
    uint strikePricesLength = strikePrices.length;
    // strikePrice and skew length must match and must have at least 1
    if (strikePricesLength != skews.length || strikePricesLength == 0) {
      revert StrikeSkewLengthMismatch(address(this), strikePricesLength, skews.length);
    }

    if (expiry <= block.timestamp || expiry > block.timestamp + optionMarketParams.maxBoardExpiry) {
      revert InvalidExpiryTimestamp(address(this), block.timestamp, expiry, optionMarketParams.maxBoardExpiry);
    }

    if (baseIV == 0) {
      revert ExpectedNonZeroValue(address(this), NonZeroValues.BASE_IV);
    }

    boardId = nextBoardId++;
    OptionBoard storage board = optionBoards[boardId];
    board.id = boardId;
    board.expiry = expiry;
    board.iv = baseIV;
    board.frozen = frozen;

    liveBoards.push(boardId);

    emit BoardCreated(boardId, expiry, baseIV, frozen);

    Strike[] memory newStrikes = new Strike[](strikePricesLength);
    for (uint i = 0; i < strikePricesLength; ++i) {
      newStrikes[i] = _addStrikeToBoard(board, strikePrices[i], skews[i]);
    }

    greekCache.addBoard(board, newStrikes);

    return boardId;
  }
  function setBoardFrozen(uint boardId, bool frozen) external onlyOwner {
    OptionBoard storage board = optionBoards[boardId];
    if (board.id != boardId || board.id == 0) {
      revert InvalidBoardId(address(this), boardId);
    }
    optionBoards[boardId].frozen = frozen;
    emit BoardFrozen(boardId, frozen);
  }
  function setBoardBaseIv(uint boardId, uint baseIv) external onlyOwner {
    OptionBoard storage board = optionBoards[boardId];
    if (board.id != boardId || board.id == 0) {
      revert InvalidBoardId(address(this), boardId);
    }
    if (baseIv == 0) {
      revert ExpectedNonZeroValue(address(this), NonZeroValues.BASE_IV);
    }
    if (!board.frozen) {
      revert BoardNotFrozen(address(this), boardId);
    }

    board.iv = baseIv;
    greekCache.setBoardIv(boardId, baseIv);
    emit BoardBaseIvSet(boardId, baseIv);
  }
  function setStrikeSkew(uint strikeId, uint skew) external onlyOwner {
    Strike storage strike = strikes[strikeId];
    if (strike.id != strikeId) {
      revert InvalidStrikeId(address(this), strikeId);
    }
    if (skew == 0) {
      revert ExpectedNonZeroValue(address(this), NonZeroValues.SKEW);
    }

    OptionBoard memory board = optionBoards[strike.boardId];
    if (!board.frozen) {
      revert BoardNotFrozen(address(this), board.id);
    }

    strike.skew = skew;
    greekCache.setStrikeSkew(strikeId, skew);
    emit StrikeSkewSet(strikeId, skew);
  }
  function addStrikeToBoard(uint boardId, uint strikePrice, uint skew) external onlyOwner {
    OptionBoard storage board = optionBoards[boardId];
    if (board.id != boardId || board.id == 0) {
      revert InvalidBoardId(address(this), boardId);
    }
    Strike memory strike = _addStrikeToBoard(board, strikePrice, skew);
    greekCache.addStrikeToBoard(boardId, strike.id, strikePrice, skew);
  }
  function _addStrikeToBoard(OptionBoard storage board, uint strikePrice, uint skew) internal returns (Strike memory) {
    if (strikePrice == 0) {
      revert ExpectedNonZeroValue(address(this), NonZeroValues.STRIKE_PRICE);
    }
    if (skew == 0) {
      revert ExpectedNonZeroValue(address(this), NonZeroValues.SKEW);
    }

    uint strikeId = nextStrikeId++;
    strikes[strikeId] = Strike(strikeId, strikePrice, skew, 0, 0, 0, 0, 0, board.id);
    board.strikeIds.push(strikeId);
    emit StrikeAdded(board.id, strikeId, strikePrice, skew);
    return strikes[strikeId];
  }
  function forceSettleBoard(uint boardId) external onlyOwner {
    OptionBoard memory board = optionBoards[boardId];
    if (board.id != boardId || board.id == 0) {
      revert InvalidBoardId(address(this), boardId);
    }
    if (!board.frozen) {
      revert BoardNotFrozen(address(this), boardId);
    }
    _clearAndSettleBoard(board);
  }
  function setOptionMarketParams(OptionMarketParameters memory _optionMarketParams) external onlyOwner {
    if (_optionMarketParams.feePortionReserved > DecimalMath.UNIT) {
      revert InvalidOptionMarketParams(address(this), _optionMarketParams);
    }
    optionMarketParams = _optionMarketParams;
    emit OptionMarketParamsSet(optionMarketParams);
  }
  function smClaim() external notGlobalPaused {
    if (msg.sender != optionMarketParams.securityModule) {
      revert OnlySecurityModule(address(this), msg.sender, optionMarketParams.securityModule);
    }
    uint quoteBal = quoteAsset.balanceOf(address(this));
    if (quoteBal > 0 && !quoteAsset.transfer(msg.sender, quoteBal)) {
      revert QuoteTransferFailed(address(this), address(this), msg.sender, quoteBal);
    }
    emit SMClaimed(msg.sender, quoteBal);
  }
  function recoverFunds(IERC20Decimals token, address recipient) external onlyOwner {
    if (token == quoteAsset) {
      revert CannotRecoverQuote(address(this));
    }
    token.transfer(recipient, token.balanceOf(address(this)));
  }
  // views
  function getOptionMarketParams() external view returns (OptionMarketParameters memory) {
    return optionMarketParams;
  }
  function getLiveBoards() external view returns (uint[] memory _liveBoards) {
    uint liveBoardsLen = liveBoards.length;
    _liveBoards = new uint[](liveBoardsLen);
    for (uint i = 0; i < liveBoardsLen; ++i) {
      _liveBoards[i] = liveBoards[i];
    }
    return _liveBoards;
  }
  function getNumLiveBoards() external view returns (uint numLiveBoards) {
    return liveBoards.length;
  }
  function getStrikeAndExpiry(uint strikeId) external view returns (uint strikePrice, uint expiry) {
    return (strikes[strikeId].strikePrice, optionBoards[strikes[strikeId].boardId].expiry);
  }
  function getBoardStrikes(uint boardId) external view returns (uint[] memory strikeIds) {
    uint strikeIdsLen = optionBoards[boardId].strikeIds.length;
    strikeIds = new uint[](strikeIdsLen);
    for (uint i = 0; i < strikeIdsLen; ++i) {
      strikeIds[i] = optionBoards[boardId].strikeIds[i];
    }
    return strikeIds;
  }
  function getStrike(uint strikeId) external view returns (Strike memory) {
    return strikes[strikeId];
  }
  function getOptionBoard(uint boardId) external view returns (OptionBoard memory) {
    return optionBoards[boardId];
  }
  function getStrikeAndBoard(uint strikeId) external view returns (Strike memory, OptionBoard memory) {
    Strike memory strike = strikes[strikeId];
    return (strike, optionBoards[strike.boardId]);
  }
  function getBoardAndStrikeDetails(uint boardId) external view returns (OptionBoard memory, Strike[] memory, uint[] memory, uint, uint) {
    OptionBoard memory board = optionBoards[boardId];

    uint strikesLen = board.strikeIds.length;
    Strike[] memory boardStrikes = new Strike[](strikesLen);
    uint[] memory strikeToBaseReturnedRatios = new uint[](strikesLen);
    for (uint i = 0; i < strikesLen; ++i) {
      boardStrikes[i] = strikes[board.strikeIds[i]];
      strikeToBaseReturnedRatios[i] = strikeToBaseReturnedRatio[board.strikeIds[i]];
    }
    return (
      board,
      boardStrikes,
      strikeToBaseReturnedRatios,
      boardToPriceAtExpiry[boardId],
      scaledLongsForBoard[boardId]
    );
  }
  // user func
  function openPosition(TradeInputParameters memory params) external nonReentrant returns (Result memory result) {
    result = _openPosition(params);
    _checkCostInBounds(result.totalCost, params.minTotalCost, params.maxTotalCost);
  }
  function closePosition(TradeInputParameters memory params) external nonReentrant returns (Result memory result) {
    result = _closePosition(params, false);
    _checkCostInBounds(result.totalCost, params.minTotalCost, params.maxTotalCost);
  }
  function forceClosePosition(TradeInputParameters memory params) external nonReentrant returns (Result memory result) {
    result = _closePosition(params, true);
    _checkCostInBounds(result.totalCost, params.minTotalCost, params.maxTotalCost);
  }
  function addCollateral(uint positionId, uint amountCollateral) external nonReentrant notGlobalPaused {
    int pendingCollateral = SafeCast.toInt256(amountCollateral);
    OptionType optionType = optionToken.addCollateral(positionId, amountCollateral);
    _routeUserCollateral(optionType, pendingCollateral);
  }
  function liquidatePosition(uint positionId, address rewardBeneficiary) external nonReentrant {
    OptionToken.PositionWithOwner memory position = optionToken.getPositionWithOwner(positionId);

    (TradeParameters memory trade, Strike storage strike, OptionBoard storage board) = _composeTrade(
      position.strikeId,
      position.optionType,
      position.amount,
      TradeDirection.LIQUIDATE,
      1,
      true
    );

    // updating AMM but disregarding the spotCost
    (, uint totalCost, , OptionMarketPricer.TradeResult[] memory tradeResults) = _doTrade(
      strike,
      board,
      trade,
      1,
      position.amount
    );

    OptionToken.LiquidationFees memory liquidationFees = optionToken.liquidate(positionId, trade, totalCost);

    if (liquidationFees.insolventAmount > 0) {
      liquidityPool.updateLiquidationInsolvency(liquidationFees.insolventAmount);
    }

    shortCollateral.routeLiquidationFunds(position.owner, rewardBeneficiary, position.optionType, liquidationFees);
    liquidityPool.updateCBs();

    emit Trade(
      position.owner,
      positionId,
      address(0),
      TradeEventData({
        strikeId: position.strikeId,
        expiry: trade.expiry,
        strikePrice: trade.strikePrice,
        optionType: position.optionType,
        tradeDirection: TradeDirection.LIQUIDATE,
        amount: position.amount,
        setCollateralTo: 0,
        isForceClose: true,
        spotPrice: trade.spotPrice,
        reservedFee: 0,
        totalCost: totalCost
      }),
      tradeResults,
      LiquidationEventData({
        caller: msg.sender,
        rewardBeneficiary: rewardBeneficiary,
        returnCollateral: liquidationFees.returnCollateral,
        lpPremiums: liquidationFees.lpPremiums,
        lpFee: liquidationFees.lpFee,
        liquidatorFee: liquidationFees.liquidatorFee,
        smFee: liquidationFees.smFee,
        insolventAmount: liquidationFees.insolventAmount
      }),
      trade.liquidity.longScaleFactor,
      block.timestamp
    );
  }
  function _checkCostInBounds(uint totalCost, uint minCost, uint maxCost) internal view {
    if (totalCost < minCost || totalCost > maxCost) {
      revert TotalCostOutsideOfSpecifiedBounds(address(this), totalCost, minCost, maxCost);
    }
  }
  // internals
  function _openPosition(TradeInputParameters memory params) internal returns (Result memory result) {
    (TradeParameters memory trade, Strike storage strike, OptionBoard storage board) = _composeTrade(
      params.strikeId,
      params.optionType,
      params.amount,
      TradeDirection.OPEN,
      params.iterations,
      false
    );
    OptionMarketPricer.TradeResult[] memory tradeResults;
    (trade.amount, result.totalCost, result.totalFee, tradeResults) = _doTrade(
      strike,
      board,
      trade,
      params.iterations,
      params.amount
    );

    int pendingCollateral;
    // collateral logic happens within optionToken
    (result.positionId, pendingCollateral) = optionToken.adjustPosition(
      trade,
      params.strikeId,
      msg.sender,
      params.positionId,
      result.totalCost,
      params.setCollateralTo,
      true
    );

    uint reservedFee = result.totalFee.multiplyDecimal(optionMarketParams.feePortionReserved);

    _routeLPFundsOnOpen(trade, result.totalCost, reservedFee, params.strikeId);
    _routeUserCollateral(trade.optionType, pendingCollateral);
    liquidityPool.updateCBs();

    emit Trade(
      msg.sender,
      result.positionId,
      params.referrer,
      TradeEventData({
        strikeId: params.strikeId,
        expiry: trade.expiry,
        strikePrice: trade.strikePrice,
        optionType: params.optionType,
        tradeDirection: TradeDirection.OPEN,
        amount: trade.amount,
        setCollateralTo: params.setCollateralTo,
        isForceClose: false,
        spotPrice: trade.spotPrice,
        reservedFee: reservedFee,
        totalCost: result.totalCost
      }),
      tradeResults,
      LiquidationEventData(address(0), address(0), 0, 0, 0, 0, 0, 0),
      trade.liquidity.longScaleFactor,
      block.timestamp
    );
  }
  function _closePosition(TradeInputParameters memory params, bool forceClose) internal returns (Result memory result) {
    (TradeParameters memory trade, Strike storage strike, OptionBoard storage board) = _composeTrade(
      params.strikeId,
      params.optionType,
      params.amount,
      TradeDirection.CLOSE,
      params.iterations,
      forceClose
    );

    OptionMarketPricer.TradeResult[] memory tradeResults;
    (trade.amount, result.totalCost, result.totalFee, tradeResults) = _doTrade(
      strike,
      board,
      trade,
      params.iterations,
      params.amount
    );

    int pendingCollateral;
    // collateral logic happens within optionToken
    (result.positionId, pendingCollateral) = optionToken.adjustPosition(
      trade,
      params.strikeId,
      msg.sender,
      params.positionId,
      result.totalCost,
      params.setCollateralTo,
      false
    );

    uint reservedFee = result.totalFee.multiplyDecimal(optionMarketParams.feePortionReserved);

    _routeUserCollateral(trade.optionType, pendingCollateral);
    _routeLPFundsOnClose(trade, result.totalCost, reservedFee);
    liquidityPool.updateCBs();

    emit Trade(
      msg.sender,
      result.positionId,
      params.referrer,
      TradeEventData({
        strikeId: params.strikeId,
        expiry: trade.expiry,
        strikePrice: trade.strikePrice,
        optionType: params.optionType,
        tradeDirection: TradeDirection.CLOSE,
        amount: params.amount,
        setCollateralTo: params.setCollateralTo,
        isForceClose: forceClose,
        reservedFee: reservedFee,
        spotPrice: trade.spotPrice,
        totalCost: result.totalCost
      }),
      tradeResults,
      LiquidationEventData(address(0), address(0), 0, 0, 0, 0, 0, 0),
      trade.liquidity.longScaleFactor,
      block.timestamp
    );
  }
  function _composeTrade(uint strikeId, OptionType optionType, uint amount, TradeDirection _tradeDirection, uint iterations, bool isForceClose) internal view returns (TradeParameters memory trade, Strike storage strike, OptionBoard storage board) {
    if (strikeId == 0) {
      revert ExpectedNonZeroValue(address(this), NonZeroValues.STRIKE_ID);
    }
    if (iterations == 0) {
      revert ExpectedNonZeroValue(address(this), NonZeroValues.ITERATIONS);
    }

    strike = strikes[strikeId];
    if (strike.id != strikeId) {
      revert InvalidStrikeId(address(this), strikeId);
    }
    board = optionBoards[strike.boardId];

    if (boardToPriceAtExpiry[board.id] != 0) {
      revert BoardAlreadySettled(address(this), board.id);
    }

    bool isBuy = (_tradeDirection == TradeDirection.OPEN) ? _isLong(optionType) : !_isLong(optionType);

    BaseExchangeAdapter.PriceType pricing;
    if (_tradeDirection == TradeDirection.LIQUIDATE) {
      pricing = BaseExchangeAdapter.PriceType.REFERENCE;
    } else if (optionType == OptionType.LONG_CALL || optionType == OptionType.SHORT_PUT_QUOTE) {
      pricing = _tradeDirection == TradeDirection.OPEN
        ? BaseExchangeAdapter.PriceType.MAX_PRICE
        : (isForceClose ? BaseExchangeAdapter.PriceType.FORCE_MIN : BaseExchangeAdapter.PriceType.MIN_PRICE);
    } else {
      pricing = _tradeDirection == TradeDirection.OPEN
        ? BaseExchangeAdapter.PriceType.MIN_PRICE
        : (isForceClose ? BaseExchangeAdapter.PriceType.FORCE_MAX : BaseExchangeAdapter.PriceType.MAX_PRICE);
    }

    trade = TradeParameters({
      isBuy: isBuy,
      isForceClose: isForceClose,
      tradeDirection: _tradeDirection,
      optionType: optionType,
      amount: amount / iterations,
      expiry: board.expiry,
      strikePrice: strike.strikePrice,
      liquidity: liquidityPool.getLiquidity(), // NOTE: uses PriceType.REFERENCE
      spotPrice: exchangeAdapter.getSpotPriceForMarket(address(this), pricing)
    });
  }
  function _isLong(OptionType optionType) internal pure returns (bool) {
    return (optionType == OptionType.LONG_CALL || optionType == OptionType.LONG_PUT);
  }
  function _doTrade(Strike storage strike, OptionBoard storage board, TradeParameters memory trade, uint iterations, uint expectedAmount) internal returns (uint totalAmount, uint totalCost, uint totalFee, OptionMarketPricer.TradeResult[] memory tradeResults) {
    if (trade.amount == 0) {
      if (expectedAmount != 0) {
        revert TradeIterationsHasRemainder(address(this), iterations, expectedAmount, 0, 0);
      }
      return (0, 0, 0, new OptionMarketPricer.TradeResult[](0));
    }

    if (board.frozen) {
      revert BoardIsFrozen(address(this), board.id);
    }
    if (block.timestamp >= board.expiry) {
      revert BoardExpired(address(this), board.id, board.expiry, block.timestamp);
    }

    tradeResults = new OptionMarketPricer.TradeResult[](iterations);

    for (uint i = 0; i < iterations; ++i) {
      if (i == iterations - 1) {
        trade.amount = expectedAmount - totalAmount;
      }
      _updateExposure(trade.amount, trade.optionType, strike, trade.tradeDirection == TradeDirection.OPEN);

      OptionMarketPricer.TradeResult memory tradeResult = optionPricer.updateCacheAndGetTradeResult(
        strike,
        trade,
        board.iv,
        board.expiry
      );

      board.iv = tradeResult.newBaseIv;
      strike.skew = tradeResult.newSkew;

      totalCost += tradeResult.totalCost;
      totalFee += tradeResult.totalFee;
      totalAmount += trade.amount;

      tradeResults[i] = tradeResult;
    }

    return (totalAmount, totalCost, totalFee, tradeResults);
  }
  function _routeLPFundsOnOpen(TradeParameters memory trade, uint totalCost, uint feePortion, uint strikeId) internal {
    if (trade.amount == 0) {
      return;
    }

    if (trade.optionType == OptionType.LONG_CALL) {
      liquidityPool.lockCallCollateral(trade.amount, trade.spotPrice, trade.liquidity.freeLiquidity, strikeId);
      _transferFromQuote(msg.sender, address(liquidityPool), totalCost - feePortion);
      _transferFromQuote(msg.sender, address(this), feePortion);
    } else if (trade.optionType == OptionType.LONG_PUT) {
      liquidityPool.lockPutCollateral(
        trade.amount.multiplyDecimal(trade.strikePrice),
        trade.liquidity.freeLiquidity,
        strikeId
      );
      _transferFromQuote(msg.sender, address(liquidityPool), totalCost - feePortion);
      _transferFromQuote(msg.sender, address(this), feePortion);
    } else if (trade.optionType == OptionType.SHORT_CALL_BASE) {
      liquidityPool.sendShortPremium(
        msg.sender,
        trade.amount,
        totalCost,
        trade.liquidity.freeLiquidity,
        feePortion,
        true,
        strikeId
      );
    } else {
      // OptionType.SHORT_CALL_QUOTE || OptionType.SHORT_PUT_QUOTE
      liquidityPool.sendShortPremium(
        address(shortCollateral),
        trade.amount,
        totalCost,
        trade.liquidity.freeLiquidity,
        feePortion,
        trade.optionType == OptionType.SHORT_CALL_QUOTE,
        strikeId
      );
    }
  }
  function _routeLPFundsOnClose(TradeParameters memory trade, uint totalCost, uint reservedFee) internal {
    if (trade.amount == 0) {
      return;
    }

    if (trade.optionType == OptionType.LONG_CALL) {
      liquidityPool.freeCallCollateralAndSendPremium(
        trade.amount,
        msg.sender,
        totalCost,
        reservedFee,
        trade.liquidity.longScaleFactor
      );
    } else if (trade.optionType == OptionType.LONG_PUT) {
      liquidityPool.freePutCollateralAndSendPremium(
        trade.amount.multiplyDecimal(trade.strikePrice),
        msg.sender,
        totalCost,
        reservedFee,
        trade.liquidity.longScaleFactor
      );
    } else if (trade.optionType == OptionType.SHORT_CALL_BASE) {
      _transferFromQuote(msg.sender, address(liquidityPool), totalCost - reservedFee);
      _transferFromQuote(msg.sender, address(this), reservedFee);
    } else {
      // OptionType.SHORT_CALL_QUOTE || OptionType.SHORT_PUT_QUOTE
      shortCollateral.sendQuoteCollateral(address(liquidityPool), totalCost - reservedFee);
      shortCollateral.sendQuoteCollateral(address(this), reservedFee);
    }
  }
  function _routeUserCollateral(OptionType optionType, int pendingCollateral) internal {
    if (pendingCollateral == 0) {
      return;
    }

    if (optionType == OptionType.SHORT_CALL_BASE) {
      if (pendingCollateral > 0) {
        uint pendingCollateralConverted = ConvertDecimals.convertFrom18AndRoundUp(
          uint(pendingCollateral),
          baseAsset.decimals()
        );
        if (
          pendingCollateralConverted > 0 &&
          !baseAsset.transferFrom(msg.sender, address(shortCollateral), uint(pendingCollateralConverted))
        ) {
          revert BaseTransferFailed(
            address(this),
            msg.sender,
            address(shortCollateral),
            uint(pendingCollateralConverted)
          );
        }
      } else {
        shortCollateral.sendBaseCollateral(msg.sender, uint(-pendingCollateral));
      }
    } else {
      // quote collateral
      if (pendingCollateral > 0) {
        _transferFromQuote(msg.sender, address(shortCollateral), uint(pendingCollateral));
      } else {
        shortCollateral.sendQuoteCollateral(msg.sender, uint(-pendingCollateral));
      }
    }
  }
  function _updateExposure(uint amount, OptionType optionType, Strike storage strike, bool isOpen) internal {
    int exposure = isOpen ? SafeCast.toInt256(amount) : -SafeCast.toInt256(amount);

    if (optionType == OptionType.LONG_CALL) {
      exposure += SafeCast.toInt256(strike.longCall);
      strike.longCall = SafeCast.toUint256(exposure);
    } else if (optionType == OptionType.LONG_PUT) {
      exposure += SafeCast.toInt256(strike.longPut);
      strike.longPut = SafeCast.toUint256(exposure);
    } else if (optionType == OptionType.SHORT_CALL_BASE) {
      exposure += SafeCast.toInt256(strike.shortCallBase);
      strike.shortCallBase = SafeCast.toUint256(exposure);
    } else if (optionType == OptionType.SHORT_CALL_QUOTE) {
      exposure += SafeCast.toInt256(strike.shortCallQuote);
      strike.shortCallQuote = SafeCast.toUint256(exposure);
    } else {
      // OptionType.SHORT_PUT_QUOTE
      exposure += SafeCast.toInt256(strike.shortPut);
      strike.shortPut = SafeCast.toUint256(exposure);
    }
  }

  function settleExpiredBoard(uint boardId) external nonReentrant {
    OptionBoard memory board = optionBoards[boardId];
    if (board.id != boardId || board.id == 0) {
      revert InvalidBoardId(address(this), boardId);
    }
    if (block.timestamp < board.expiry) {
      revert BoardNotExpired(address(this), boardId);
    }
    _clearAndSettleBoard(board);
  }
  function _clearAndSettleBoard(OptionBoard memory board) internal {
    bool popped = false;
    uint liveBoardsLen = liveBoards.length;

    // Find and remove the board from the list of live boards
    for (uint i = 0; i < liveBoardsLen; ++i) {
      if (liveBoards[i] == board.id) {
        liveBoards[i] = liveBoards[liveBoardsLen - 1];
        liveBoards.pop();
        popped = true;
        break;
      }
    }
    // prevent old boards being liquidated
    if (!popped) {
      revert BoardAlreadySettled(address(this), board.id);
    }

    _settleExpiredBoard(board);
    greekCache.removeBoard(board.id);
  }
  function _settleExpiredBoard(OptionBoard memory board) internal {
    uint spotPrice = exchangeAdapter.getSettlementPriceForMarket(address(this), board.expiry);

    uint totalUserLongProfitQuote = 0;
    uint totalBoardLongCallCollateral = 0;
    uint totalBoardLongPutCollateral = 0;
    uint totalAMMShortCallProfitBase = 0;
    uint totalAMMShortCallProfitQuote = 0;
    uint totalAMMShortPutProfitQuote = 0;

    // Store the price now for when users come to settle their options
    boardToPriceAtExpiry[board.id] = spotPrice;

    for (uint i = 0; i < board.strikeIds.length; ++i) {
      Strike memory strike = strikes[board.strikeIds[i]];

      totalBoardLongCallCollateral += strike.longCall;
      totalBoardLongPutCollateral += strike.longPut.multiplyDecimal(strike.strikePrice);

      if (spotPrice > strike.strikePrice) {
        // For long calls
        totalUserLongProfitQuote += strike.longCall.multiplyDecimal(spotPrice - strike.strikePrice);

        // Per unit of shortCalls
        uint baseReturnedRatio = (spotPrice - strike.strikePrice).divideDecimal(spotPrice).divideDecimal(
          DecimalMath.UNIT - optionMarketParams.staticBaseSettlementFee
        );

        // This is impossible unless the baseAsset price has gone up ~900%+
        baseReturnedRatio = baseReturnedRatio > DecimalMath.UNIT ? DecimalMath.UNIT : baseReturnedRatio;

        totalAMMShortCallProfitBase += baseReturnedRatio.multiplyDecimal(strike.shortCallBase);
        totalAMMShortCallProfitQuote += (spotPrice - strike.strikePrice).multiplyDecimal(strike.shortCallQuote);
        strikeToBaseReturnedRatio[strike.id] = baseReturnedRatio;
      } else if (spotPrice < strike.strikePrice) {
        // if amount > 0 can be skipped as it will be multiplied by 0
        totalUserLongProfitQuote += strike.longPut.multiplyDecimal(strike.strikePrice - spotPrice);
        totalAMMShortPutProfitQuote += (strike.strikePrice - spotPrice).multiplyDecimal(strike.shortPut);
      }
    }

    (uint lpBaseInsolvency, uint lpQuoteInsolvency) = shortCollateral.boardSettlement(
      totalAMMShortCallProfitBase,
      totalAMMShortPutProfitQuote + totalAMMShortCallProfitQuote
    );

    // This will batch all base we want to convert to quote and sell it in one transaction
    uint longScaleFactor = liquidityPool.boardSettlement(
      lpQuoteInsolvency + lpBaseInsolvency.multiplyDecimal(spotPrice),
      totalBoardLongPutCollateral,
      totalUserLongProfitQuote,
      totalBoardLongCallCollateral
    );
    scaledLongsForBoard[board.id] = longScaleFactor;

    emit BoardSettled(
      board.id,
      spotPrice,
      totalUserLongProfitQuote,
      totalBoardLongCallCollateral,
      totalBoardLongPutCollateral,
      totalAMMShortCallProfitBase,
      totalAMMShortCallProfitQuote,
      totalAMMShortPutProfitQuote,
      longScaleFactor
    );
  }
  function getSettlementParameters(uint strikeId) external view returns (uint strikePrice, uint priceAtExpiry, uint strikeToBaseReturned, uint longScaleFactor) {
    return (
      strikes[strikeId].strikePrice,
      boardToPriceAtExpiry[strikes[strikeId].boardId],
      strikeToBaseReturnedRatio[strikeId],
      scaledLongsForBoard[strikes[strikeId].boardId]
    );
  }
  function _transferFromQuote(address from, address to, uint amount) internal {
    amount = ConvertDecimals.convertFrom18AndRoundUp(amount, quoteAsset.decimals());
    if (!quoteAsset.transferFrom(from, to, amount)) {
      revert QuoteTransferFailed(address(this), from, to, amount);
    }
  }
  modifier notGlobalPaused() {
    exchangeAdapter.requireNotGlobalPaused(address(this));
    _;
  }

  event BoardCreated(uint indexed boardId, uint expiry, uint baseIv, bool frozen);
  event BoardFrozen(uint indexed boardId, bool frozen);
  event BoardBaseIvSet(uint indexed boardId, uint baseIv);
  event StrikeSkewSet(uint indexed strikeId, uint skew);
  event StrikeAdded(uint indexed boardId, uint indexed strikeId, uint strikePrice, uint skew);
  event OptionMarketParamsSet(OptionMarketParameters optionMarketParams);
  event SMClaimed(address securityModule, uint quoteAmount);
  event Trade(address indexed trader, uint indexed positionId, address indexed referrer, TradeEventData trade, OptionMarketPricer.TradeResult[] tradeResults, LiquidationEventData liquidation, uint longScaleFactor, uint timestamp);
  event BoardSettled(uint indexed boardId, uint spotPriceAtExpiry, uint totalUserLongProfitQuote, uint totalBoardLongCallCollateral, uint totalBoardLongPutCollateral, uint totalAMMShortCallProfitBase, uint totalAMMShortCallProfitQuote, uint totalAMMShortPutProfitQuote, uint longScaleFactor);
  
  error ExpectedNonZeroValue(address thrower, NonZeroValues valueType);
  error InvalidOptionMarketParams(address thrower, OptionMarketParameters optionMarketParams);
  error CannotRecoverQuote(address thrower);
  error InvalidBoardId(address thrower, uint boardId);
  error InvalidExpiryTimestamp(address thrower, uint currentTime, uint expiry, uint maxBoardExpiry);
  error BoardNotFrozen(address thrower, uint boardId);
  error BoardAlreadySettled(address thrower, uint boardId);
  error BoardNotExpired(address thrower, uint boardId);
  error InvalidStrikeId(address thrower, uint strikeId);
  error StrikeSkewLengthMismatch(address thrower, uint strikesLength, uint skewsLength);
  error TotalCostOutsideOfSpecifiedBounds(address thrower, uint totalCost, uint minCost, uint maxCost);
  error BoardIsFrozen(address thrower, uint boardId);
  error BoardExpired(address thrower, uint boardId, uint boardExpiry, uint currentTime);
  error TradeIterationsHasRemainder(address thrower, uint iterations, uint expectedAmount, uint tradeAmount, uint totalAmount);
  error OnlySecurityModule(address thrower, address caller, address securityModule);
  error BaseTransferFailed(address thrower, address from, address to, uint amount);
  error QuoteTransferFailed(address thrower, address from, address to, uint amount);
}
