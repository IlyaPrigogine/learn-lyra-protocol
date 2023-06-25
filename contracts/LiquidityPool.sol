//SPDX-License-Identifier: ISC
pragma solidity 0.8.16;
import "openzeppelin-contracts-4.4.1/utils/math/SafeCast.sol";
import "openzeppelin-contracts-4.4.1/security/ReentrancyGuard.sol";
import "./synthetix/Owned.sol";
import "./synthetix/DecimalMath.sol";
import "./libraries/SimpleInitializable.sol";
import "./libraries/ConvertDecimals.sol";
import "./interfaces/IERC20Decimals.sol";

import "./LiquidityToken.sol";
import "./OptionGreekCache.sol";
import "./OptionMarket.sol";
import "./ShortCollateral.sol";
import "./libraries/PoolHedger.sol";
import "./BaseExchangeAdapter.sol";

contract LiquidityPool is Owned, SimpleInitializable, ReentrancyGuard {
  using DecimalMath for uint;
  struct Collateral {
    uint quote;
    uint base;
  }
  struct Liquidity {
    uint freeLiquidity;
    uint burnableLiquidity;
    uint reservedCollatLiquidity;
    uint pendingDeltaLiquidity;
    uint usedDeltaLiquidity;
    uint NAV;
    uint longScaleFactor;
  }
  struct QueuedDeposit {
    uint id;
    address beneficiary;
    uint amountLiquidity;
    uint mintedTokens;
    uint depositInitiatedTime;
  }
  struct QueuedWithdrawal {
    uint id;
    address beneficiary;
    uint amountTokens;
    uint quoteSent;
    uint withdrawInitiatedTime;
  }
  struct LiquidityPoolParameters {
    uint minDepositWithdraw;
    uint depositDelay;
    uint withdrawalDelay;
    uint withdrawalFee;
    address guardianMultisig;
    uint guardianDelay;
    uint adjustmentNetScalingFactor;
    uint callCollatScalingFactor;
    uint putCollatScalingFactor;
  }
  struct CircuitBreakerParameters {
    uint liquidityCBThreshold;
    uint liquidityCBTimeout;
    uint ivVarianceCBThreshold;
    uint skewVarianceCBThreshold;
    uint ivVarianceCBTimeout;
    uint skewVarianceCBTimeout;
    uint boardSettlementCBTimeout;
    uint contractAdjustmentCBTimeout;
  }

  BaseExchangeAdapter internal exchangeAdapter;
  OptionMarket internal optionMarket;
  LiquidityToken internal liquidityToken;
  ShortCollateral internal shortCollateral;
  OptionGreekCache internal greekCache;
  IERC20Decimals internal baseAsset;

  PoolHedger public poolHedger;
  IERC20Decimals public quoteAsset;
  mapping(uint => QueuedDeposit) public queuedDeposits;
  mapping(uint => QueuedWithdrawal) public queuedWithdrawals;
  uint public totalQueuedDeposits = 0;
  uint public queuedDepositHead = 1;
  uint public nextQueuedDepositId = 1;
  uint public totalQueuedWithdrawals = 0;
  uint public queuedWithdrawalHead = 1;
  uint public nextQueuedWithdrawalId = 1;
  uint public CBTimestamp = 0;
  LiquidityPoolParameters public lpParams;
  CircuitBreakerParameters public cbParams;
  Collateral public lockedCollateral;
  uint public totalOutstandingSettlements;
  uint public insolventSettlementAmount;
  uint public liquidationInsolventAmount;
  uint public protectedQuote;

  constructor() Owned() {}
  function init(BaseExchangeAdapter _exchangeAdapter, OptionMarket _optionMarket, LiquidityToken _liquidityToken, OptionGreekCache _greekCache, PoolHedger _poolHedger, ShortCollateral _shortCollateral, IERC20Decimals _quoteAsset, IERC20Decimals _baseAsset) external onlyOwner initializer {
    exchangeAdapter = _exchangeAdapter;
    optionMarket = _optionMarket;
    liquidityToken = _liquidityToken;
    greekCache = _greekCache;
    shortCollateral = _shortCollateral;
    poolHedger = _poolHedger;
    quoteAsset = _quoteAsset;
    baseAsset = _baseAsset;
  }
  function setLiquidityPoolParameters(LiquidityPoolParameters memory _lpParams) external onlyOwner {
    if (
      !(_lpParams.depositDelay < 365 days &&
        _lpParams.withdrawalDelay < 365 days &&
        _lpParams.withdrawalFee < 2e17 &&
        _lpParams.guardianDelay < 365 days)
    ) {
      revert InvalidLiquidityPoolParameters(address(this), _lpParams);
    }

    lpParams = _lpParams;

    emit LiquidityPoolParametersUpdated(lpParams);
  }
  function setCircuitBreakerParameters(CircuitBreakerParameters memory _cbParams) external onlyOwner {
    if (
      !(_cbParams.liquidityCBThreshold < DecimalMath.UNIT &&
        _cbParams.liquidityCBTimeout < 60 days &&
        _cbParams.ivVarianceCBTimeout < 60 days &&
        _cbParams.skewVarianceCBTimeout < 60 days &&
        _cbParams.boardSettlementCBTimeout < 10 days)
    ) {
      revert InvalidCircuitBreakerParameters(address(this), _cbParams);
    }

    cbParams = _cbParams;

    emit CircuitBreakerParametersUpdated(cbParams);
  }
  function setPoolHedger(PoolHedger newPoolHedger) external onlyOwner {
    poolHedger = newPoolHedger;
    emit PoolHedgerUpdated(poolHedger);
  }
  function recoverFunds(IERC20Decimals token, address recipient) external onlyOwner {
    if (token == quoteAsset || token == baseAsset) {
      revert CannotRecoverQuoteBase(address(this));
    }
    token.transfer(recipient, token.balanceOf(address(this)));
  }

  function initiateDeposit(address beneficiary, uint amountQuote) external nonReentrant {
    uint realQuote = amountQuote;

    // Convert to 18 dp for LP token minting
    amountQuote = ConvertDecimals.convertTo18(amountQuote, quoteAsset.decimals());

    if (beneficiary == address(0)) {
      revert InvalidBeneficiaryAddress(address(this), beneficiary);
    }
    if (amountQuote < lpParams.minDepositWithdraw) {
      revert MinimumDepositNotMet(address(this), amountQuote, lpParams.minDepositWithdraw);
    }
    // getLiquidity will also make deposits pause when the market/global system is paused
    Liquidity memory liquidity = getLiquidity();
    if (optionMarket.getNumLiveBoards() == 0) {
      uint tokenPrice = _getTokenPrice(liquidity.NAV, getTotalTokenSupply());

      uint amountTokens = amountQuote.divideDecimal(tokenPrice);
      liquidityToken.mint(beneficiary, amountTokens);

      // guaranteed to have long scaling factor of 1 when liv boards == 0
      protectedQuote = (liquidity.NAV + amountQuote).multiplyDecimal(
        DecimalMath.UNIT - lpParams.adjustmentNetScalingFactor
      );

      emit DepositProcessed(msg.sender, beneficiary, 0, amountQuote, tokenPrice, amountTokens, block.timestamp);
    } else {
      QueuedDeposit storage newDeposit = queuedDeposits[nextQueuedDepositId];

      newDeposit.id = nextQueuedDepositId++;
      newDeposit.beneficiary = beneficiary;
      newDeposit.amountLiquidity = amountQuote;
      newDeposit.depositInitiatedTime = block.timestamp;

      totalQueuedDeposits += amountQuote;

      emit DepositQueued(msg.sender, beneficiary, newDeposit.id, amountQuote, totalQueuedDeposits, block.timestamp);
    }

    if (!quoteAsset.transferFrom(msg.sender, address(this), realQuote)) {
      revert QuoteTransferFailed(address(this), msg.sender, address(this), realQuote);
    }
  }
  function initiateWithdraw(address beneficiary, uint amountLiquidityToken) external nonReentrant {
    if (beneficiary == address(0)) {
      revert InvalidBeneficiaryAddress(address(this), beneficiary);
    }

    Liquidity memory liquidity = getLiquidity();
    uint tokenPrice = _getTokenPrice(liquidity.NAV, getTotalTokenSupply());
    uint withdrawalValue = amountLiquidityToken.multiplyDecimal(tokenPrice);

    if (withdrawalValue < lpParams.minDepositWithdraw && amountLiquidityToken < lpParams.minDepositWithdraw) {
      revert MinimumWithdrawNotMet(address(this), withdrawalValue, lpParams.minDepositWithdraw);
    }

    if (optionMarket.getNumLiveBoards() == 0 && liquidity.longScaleFactor == DecimalMath.UNIT) {
      _transferQuote(beneficiary, withdrawalValue);

      protectedQuote = (liquidity.NAV - withdrawalValue).multiplyDecimal(
        DecimalMath.UNIT - lpParams.adjustmentNetScalingFactor
      );

      // quoteReceived in the event is in 18dp
      emit WithdrawProcessed(
        msg.sender,
        beneficiary,
        0,
        amountLiquidityToken,
        tokenPrice,
        withdrawalValue,
        totalQueuedWithdrawals,
        block.timestamp
      );
    } else {
      QueuedWithdrawal storage newWithdrawal = queuedWithdrawals[nextQueuedWithdrawalId];

      newWithdrawal.id = nextQueuedWithdrawalId++;
      newWithdrawal.beneficiary = beneficiary;
      newWithdrawal.amountTokens = amountLiquidityToken;
      newWithdrawal.withdrawInitiatedTime = block.timestamp;

      totalQueuedWithdrawals += amountLiquidityToken;

      emit WithdrawQueued(
        msg.sender,
        beneficiary,
        newWithdrawal.id,
        amountLiquidityToken,
        totalQueuedWithdrawals,
        block.timestamp
      );
    }
    liquidityToken.burn(msg.sender, amountLiquidityToken);
  }
  function processDepositQueue(uint limit) external nonReentrant {
    Liquidity memory liquidity = _getLiquidityAndUpdateCB();
    uint tokenPrice = _getTokenPrice(liquidity.NAV, getTotalTokenSupply());
    uint processedDeposits;

    for (uint i = 0; i < limit; ++i) {
      QueuedDeposit storage current = queuedDeposits[queuedDepositHead];
      if (!_canProcess(current.depositInitiatedTime, lpParams.depositDelay, queuedDepositHead)) {
        break;
      }

      uint amountTokens = current.amountLiquidity.divideDecimal(tokenPrice);
      liquidityToken.mint(current.beneficiary, amountTokens);
      current.mintedTokens = amountTokens;
      processedDeposits += current.amountLiquidity;

      emit DepositProcessed(
        msg.sender,
        current.beneficiary,
        queuedDepositHead,
        current.amountLiquidity,
        tokenPrice,
        amountTokens,
        block.timestamp
      );
      current.amountLiquidity = 0;

      queuedDepositHead++;
    }

    // only update if deposit processed to avoid changes when CB's are firing
    if (processedDeposits != 0) {
      totalQueuedDeposits -= processedDeposits;

      protectedQuote = (liquidity.NAV + processedDeposits).multiplyDecimal(
        DecimalMath.UNIT - lpParams.adjustmentNetScalingFactor
      );
    }
  }
  function processWithdrawalQueue(uint limit) external nonReentrant {
    uint oldQueuedWithdrawals = totalQueuedWithdrawals;
    for (uint i = 0; i < limit; ++i) {
      (uint totalTokensBurnable, uint tokenPriceWithFee) = _getBurnableTokensAndAddFee();

      QueuedWithdrawal storage current = queuedWithdrawals[queuedWithdrawalHead];

      if (!_canProcess(current.withdrawInitiatedTime, lpParams.withdrawalDelay, queuedWithdrawalHead)) {
        break;
      }

      if (totalTokensBurnable == 0) {
        break;
      }

      uint burnAmount = current.amountTokens;
      if (burnAmount > totalTokensBurnable) {
        burnAmount = totalTokensBurnable;
      }

      current.amountTokens -= burnAmount;
      totalQueuedWithdrawals -= burnAmount;

      uint quoteAmount = burnAmount.multiplyDecimal(tokenPriceWithFee);
      if (_tryTransferQuote(current.beneficiary, quoteAmount)) {
        // success
        current.quoteSent += quoteAmount;
      } else {
        // On unknown failure reason, return LP tokens and continue
        totalQueuedWithdrawals -= current.amountTokens;
        uint returnAmount = current.amountTokens + burnAmount;
        liquidityToken.mint(current.beneficiary, returnAmount);
        current.amountTokens = 0;
        emit WithdrawReverted(
          msg.sender,
          current.beneficiary,
          queuedWithdrawalHead,
          tokenPriceWithFee,
          totalQueuedWithdrawals,
          block.timestamp,
          returnAmount
        );
        queuedWithdrawalHead++;
        continue;
      }

      if (current.amountTokens > 0) {
        emit WithdrawPartiallyProcessed(
          msg.sender,
          current.beneficiary,
          queuedWithdrawalHead,
          burnAmount,
          tokenPriceWithFee,
          quoteAmount,
          totalQueuedWithdrawals,
          block.timestamp
        );
        break;
      }
      emit WithdrawProcessed(
        msg.sender,
        current.beneficiary,
        queuedWithdrawalHead,
        burnAmount,
        tokenPriceWithFee,
        quoteAmount,
        totalQueuedWithdrawals,
        block.timestamp
      );
      queuedWithdrawalHead++;
    }

    // only update if withdrawal processed to avoid changes when CB's are firing
    // getLiquidity() called again to account for withdrawal fee
    if (oldQueuedWithdrawals > totalQueuedWithdrawals) {
      Liquidity memory liquidity = getLiquidity();
      protectedQuote = liquidity.NAV.multiplyDecimal(DecimalMath.UNIT - lpParams.adjustmentNetScalingFactor);
    }
  }
  function updateCBs() external nonReentrant {
    _getLiquidityAndUpdateCB();
  }
  //  internals
  function _canProcess(uint initiatedTime, uint minimumDelay, uint entryId) internal returns (bool) {
    bool validEntry = initiatedTime != 0;
    // bypass circuit breaker and stale checks if the guardian is calling and their delay has passed
    bool guardianBypass = msg.sender == lpParams.guardianMultisig &&
      initiatedTime + lpParams.guardianDelay < block.timestamp;
    // if minimum delay or circuit breaker timeout hasn't passed, we can't process
    bool delaysExpired = initiatedTime + minimumDelay < block.timestamp && CBTimestamp < block.timestamp;

    // cannot process if greekCache stale
    uint spotPrice = exchangeAdapter.getSpotPriceForMarket(
      address(optionMarket),
      BaseExchangeAdapter.PriceType.REFERENCE
    );
    bool isStale = greekCache.isGlobalCacheStale(spotPrice);

    emit CheckingCanProcess(entryId, !isStale, validEntry, guardianBypass, delaysExpired);

    return validEntry && ((!isStale && delaysExpired) || guardianBypass);
  }
  function _getBurnableTokensAndAddFee() internal returns (uint burnableTokens, uint tokenPriceWithFee) {
    (uint tokenPrice, uint burnableLiquidity) = _getTokenPriceAndBurnableLiquidity();
    tokenPriceWithFee = (optionMarket.getNumLiveBoards() != 0)
      ? tokenPrice.multiplyDecimal(DecimalMath.UNIT - lpParams.withdrawalFee)
      : tokenPrice;

    return (burnableLiquidity.divideDecimal(tokenPriceWithFee), tokenPriceWithFee);
  }
  function _getTokenPriceAndBurnableLiquidity() internal returns (uint tokenPrice, uint burnableLiquidity) {
    Liquidity memory liquidity = _getLiquidityAndUpdateCB();
    uint totalTokenSupply = getTotalTokenSupply();
    tokenPrice = _getTokenPrice(liquidity.NAV, totalTokenSupply);

    return (tokenPrice, liquidity.burnableLiquidity);
  }
  function _updateCBs(Liquidity memory liquidity, uint maxIvVariance, uint maxSkewVariance, int optionValueDebt) internal {
    // don't trigger CBs if pool has no open options
    if (liquidity.reservedCollatLiquidity == 0 && optionValueDebt == 0) {
      return;
    }

    uint timeToAdd = 0;

    // if NAV == 0, openAmount will be zero too and _updateCB() won't be called.
    uint freeLiquidityPercent = liquidity.freeLiquidity.divideDecimal(liquidity.NAV);

    bool ivVarianceThresholdCrossed = maxIvVariance > cbParams.ivVarianceCBThreshold;
    bool skewVarianceThresholdCrossed = maxSkewVariance > cbParams.skewVarianceCBThreshold;
    bool liquidityThresholdCrossed = freeLiquidityPercent < cbParams.liquidityCBThreshold;
    bool contractAdjustmentEvent = liquidity.longScaleFactor != DecimalMath.UNIT;

    if (ivVarianceThresholdCrossed) {
      timeToAdd = cbParams.ivVarianceCBTimeout;
    }

    if (skewVarianceThresholdCrossed && cbParams.skewVarianceCBTimeout > timeToAdd) {
      timeToAdd = cbParams.skewVarianceCBTimeout;
    }

    if (liquidityThresholdCrossed && cbParams.liquidityCBTimeout > timeToAdd) {
      timeToAdd = cbParams.liquidityCBTimeout;
    }

    if (contractAdjustmentEvent && cbParams.contractAdjustmentCBTimeout > timeToAdd) {
      timeToAdd = cbParams.contractAdjustmentCBTimeout;
    }

    if (timeToAdd > 0 && CBTimestamp < block.timestamp + timeToAdd) {
      CBTimestamp = block.timestamp + timeToAdd;
      emit CircuitBreakerUpdated(
        CBTimestamp,
        ivVarianceThresholdCrossed,
        skewVarianceThresholdCrossed,
        liquidityThresholdCrossed,
        contractAdjustmentEvent
      );
    }
  }
  function _freePutCollateral(uint amountQuote) internal {
    // In case of rounding errors
    amountQuote = amountQuote > lockedCollateral.quote ? lockedCollateral.quote : amountQuote;
    lockedCollateral.quote -= amountQuote;
    emit PutCollateralFreed(amountQuote, lockedCollateral.quote);
  }
  function _freeCallCollateral(uint amountBase) internal {
    // In case of rounding errors
    amountBase = amountBase > lockedCollateral.base ? lockedCollateral.base : amountBase;
    lockedCollateral.base -= amountBase;
    emit CallCollateralFreed(amountBase, lockedCollateral.base);
  }
  function _sendPremium(address recipient, uint recipientAmount, uint optionMarketPortion) internal {
    _transferQuote(recipient, recipientAmount);
    _transferQuote(address(optionMarket), optionMarketPortion);

    emit PremiumTransferred(recipient, recipientAmount, optionMarketPortion);
  }

  // onlyOptionMarket
  function lockPutCollateral(uint amount, uint freeLiquidity, uint strikeId) external onlyOptionMarket {
    if (amount.multiplyDecimal(lpParams.putCollatScalingFactor) > freeLiquidity) {
      revert LockingMoreQuoteThanIsFree(address(this), amount, freeLiquidity, lockedCollateral);
    }

    _checkCanHedge(amount, true, strikeId);

    lockedCollateral.quote += amount;
    emit PutCollateralLocked(amount, lockedCollateral.quote);
  }
  function lockCallCollateral(uint amount, uint spotPrice, uint freeLiquidity, uint strikeId) external onlyOptionMarket {
    _checkCanHedge(amount, false, strikeId);

    if (amount.multiplyDecimal(spotPrice).multiplyDecimal(lpParams.callCollatScalingFactor) > freeLiquidity) {
      revert LockingMoreQuoteThanIsFree(
        address(this),
        amount.multiplyDecimal(spotPrice),
        freeLiquidity,
        lockedCollateral
      );
    }
    lockedCollateral.base += amount;
    emit CallCollateralLocked(amount, lockedCollateral.base);
  }
  function freePutCollateralAndSendPremium(uint amountQuoteFreed, address recipient, uint totalCost, uint reservedFee, uint longScaleFactor) external onlyOptionMarket {
    _freePutCollateral(amountQuoteFreed);
    _sendPremium(recipient, totalCost.multiplyDecimal(longScaleFactor), reservedFee);
  }
  function freeCallCollateralAndSendPremium(uint amountBase, address recipient, uint totalCost, uint reservedFee, uint longScaleFactor) external onlyOptionMarket {
    _freeCallCollateral(amountBase);
    _sendPremium(recipient, totalCost.multiplyDecimal(longScaleFactor), reservedFee);
  }
  function sendShortPremium(address recipient, uint amountContracts, uint premium, uint freeLiquidity, uint reservedFee, bool isCall, uint strikeId) external onlyOptionMarket {
    if (premium + reservedFee > freeLiquidity) {
      revert SendPremiumNotEnoughCollateral(address(this), premium, reservedFee, freeLiquidity);
    }

    // only blocks opening new positions if cannot hedge
    // Since this is opening a short, pool delta exposure is the same direction as if it were a call
    // (user opens a short call, the pool acquires on a long call)
    _checkCanHedge(amountContracts, isCall, strikeId);
    _sendPremium(recipient, premium, reservedFee);
  }
  function boardSettlement(uint insolventSettlements, uint amountQuoteFreed, uint amountQuoteReserved, uint amountBaseFreed) external onlyOptionMarket returns (uint) {
    // Update circuit breaker whenever a board is settled, to pause deposits/withdrawals
    // This allows keepers some time to settle insolvent positions
    if (block.timestamp + cbParams.boardSettlementCBTimeout > CBTimestamp) {
      CBTimestamp = block.timestamp + cbParams.boardSettlementCBTimeout;
      emit BoardSettlementCircuitBreakerUpdated(CBTimestamp);
    }

    insolventSettlementAmount += insolventSettlements;

    _freePutCollateral(amountQuoteFreed);
    _freeCallCollateral(amountBaseFreed);

    // If amountQuoteReserved > available liquidity, amountQuoteReserved is scaled down to an available amount
    Liquidity memory liquidity = getLiquidity(); // calculates total pool value and potential scaling

    totalOutstandingSettlements += amountQuoteReserved.multiplyDecimal(liquidity.longScaleFactor);

    emit BoardSettlement(insolventSettlementAmount, amountQuoteReserved, totalOutstandingSettlements);

    if (address(poolHedger) != address(0)) {
      poolHedger.resetInteractionDelay();
    }
    return liquidity.longScaleFactor;
  }

  // onlyShortCollateral
  function sendSettlementValue(address user, uint amount) external onlyShortCollateral {
    // To prevent any potential rounding errors
    if (amount > totalOutstandingSettlements) {
      amount = totalOutstandingSettlements;
    }
    totalOutstandingSettlements -= amount;
    _transferQuote(user, amount);

    emit OutstandingSettlementSent(user, amount, totalOutstandingSettlements);
  }
  function reclaimInsolventQuote(uint amountQuote) external onlyShortCollateral {
    Liquidity memory liquidity = getLiquidity();
    if (amountQuote > liquidity.freeLiquidity) {
      revert NotEnoughFreeToReclaimInsolvency(address(this), amountQuote, liquidity);
    }
    _transferQuote(address(shortCollateral), amountQuote);

    insolventSettlementAmount += amountQuote;

    emit InsolventSettlementAmountUpdated(amountQuote, insolventSettlementAmount);
  }
  function reclaimInsolventBase(uint amountBase) external onlyShortCollateral {
    Liquidity memory liquidity = getLiquidity();

    uint freeLiq = ConvertDecimals.convertFrom18(liquidity.freeLiquidity, quoteAsset.decimals());

    if (!quoteAsset.approve(address(exchangeAdapter), freeLiq)) {
      revert QuoteApprovalFailure(address(this), address(exchangeAdapter), freeLiq);
    }

    // Assume the inputs and outputs of exchangeAdapter are always 1e18
    (uint quoteSpent, ) = exchangeAdapter.exchangeToExactBaseWithLimit(
      address(optionMarket),
      amountBase,
      liquidity.freeLiquidity
    );
    insolventSettlementAmount += quoteSpent;

    // It is better for the contract to revert if there is not enough here (due to rounding) to keep accounting in
    // ShortCollateral correct. baseAsset can be donated (sent) to this contract to allow this to pass.
    uint realBase = ConvertDecimals.convertFrom18(amountBase, baseAsset.decimals());
    if (realBase > 0 && !baseAsset.transfer(address(shortCollateral), realBase)) {
      revert BaseTransferFailed(address(this), address(this), address(shortCollateral), realBase);
    }

    emit InsolventSettlementAmountUpdated(quoteSpent, insolventSettlementAmount);
  }
  function exchangeBase() public nonReentrant {
    uint currentBaseBalance = baseAsset.balanceOf(address(this));
    if (currentBaseBalance > 0) {
      if (!baseAsset.approve(address(exchangeAdapter), currentBaseBalance)) {
        revert BaseApprovalFailure(address(this), address(exchangeAdapter), currentBaseBalance);
      }
      currentBaseBalance = ConvertDecimals.convertTo18(currentBaseBalance, baseAsset.decimals());
      uint quoteReceived = exchangeAdapter.exchangeFromExactBase(address(optionMarket), currentBaseBalance);
      emit BaseSold(currentBaseBalance, quoteReceived);
    }
  }
  function updateLiquidationInsolvency(uint insolvencyAmountInQuote) external onlyOptionMarket {
    liquidationInsolventAmount += insolvencyAmountInQuote;
  }
  function transferQuoteToHedge(uint amount) external onlyPoolHedger returns (uint) {
    Liquidity memory liquidity = getLiquidity();

    uint available = liquidity.pendingDeltaLiquidity + liquidity.freeLiquidity;

    amount = amount > available ? available : amount;

    _transferQuote(address(poolHedger), amount);
    emit QuoteTransferredToPoolHedger(amount);

    return amount;
  }
  function _transferQuote(address to, uint amount) internal {
    amount = ConvertDecimals.convertFrom18(amount, quoteAsset.decimals());
    if (amount > 0) {
      if (!quoteAsset.transfer(to, amount)) {
        revert QuoteTransferFailed(address(this), address(this), to, amount);
      }
    }
  }
  function _tryTransferQuote(address to, uint amount) internal returns (bool success) {
    amount = ConvertDecimals.convertFrom18(amount, quoteAsset.decimals());
    if (amount > 0) {
      try quoteAsset.transfer(to, amount) returns (bool res) {
        return res;
      } catch {
        return false;
      }
    }
    return true;
  }

  // views
  function getTotalTokenSupply() public view returns (uint) {
    return liquidityToken.totalSupply() + totalQueuedWithdrawals;
  }
  function getTokenPriceWithCheck() external view returns (uint tokenPrice, bool isStale, uint circuitBreakerExpiry) {
    tokenPrice = getTokenPrice();
    uint spotPrice = exchangeAdapter.getSpotPriceForMarket(
      address(optionMarket),
      BaseExchangeAdapter.PriceType.REFERENCE
    );
    isStale = greekCache.isGlobalCacheStale(spotPrice);
    return (tokenPrice, isStale, CBTimestamp);
  }
  function getTokenPrice() public view returns (uint) {
    Liquidity memory liquidity = getLiquidity();
    return _getTokenPrice(liquidity.NAV, getTotalTokenSupply());
  }
  function getLiquidity() public view returns (Liquidity memory) {
    uint spotPrice = exchangeAdapter.getSpotPriceForMarket(
      address(optionMarket),
      BaseExchangeAdapter.PriceType.REFERENCE
    );

    // if cache is stale, pendingDelta may be inaccurate
    (uint pendingDelta, uint usedDelta) = _getPoolHedgerLiquidity(spotPrice);
    int optionValueDebt = greekCache.getGlobalOptionValue();
    (uint totalPoolValue, uint longScaleFactor) = _getTotalPoolValueQuote(spotPrice, usedDelta, optionValueDebt);
    uint tokenPrice = _getTokenPrice(totalPoolValue, getTotalTokenSupply());

    Liquidity memory liquidity = _getLiquidity(
      spotPrice,
      totalPoolValue,
      tokenPrice.multiplyDecimal(totalQueuedWithdrawals),
      usedDelta,
      pendingDelta,
      longScaleFactor
    );

    return liquidity;
  }
  function getTotalPoolValueQuote() external view returns (uint totalPoolValue) {
    Liquidity memory liquidity = getLiquidity();
    return liquidity.NAV;
  }
  function getLpParams() external view returns (LiquidityPoolParameters memory) {
    return lpParams;
  }
  function getCBParams() external view returns (CircuitBreakerParameters memory) {
    return cbParams;
  }
  function _getTokenPrice(uint totalPoolValue, uint totalTokenSupply) internal pure returns (uint) {
    if (totalTokenSupply == 0) {
      return DecimalMath.UNIT;
    }
    return totalPoolValue.divideDecimal(totalTokenSupply);
  }
  function _getLiquidityAndUpdateCB() internal returns (Liquidity memory liquidity) {
    liquidity = getLiquidity();

    // update Circuit Breakers
    OptionGreekCache.GlobalCache memory globalCache = greekCache.getGlobalCache();
    _updateCBs(liquidity, globalCache.maxIvVariance, globalCache.maxSkewVariance, globalCache.netGreeks.netOptionValue);
  }
  function _getTotalPoolValueQuote(uint basePrice, uint usedDeltaLiquidity, int optionValueDebt) internal view returns (uint, uint) {
    int totalAssetValue = SafeCast.toInt256(
      ConvertDecimals.convertTo18(quoteAsset.balanceOf(address(this)), quoteAsset.decimals()) +
        ConvertDecimals.convertTo18(baseAsset.balanceOf(address(this)), baseAsset.decimals()).multiplyDecimal(basePrice)
    ) +
      SafeCast.toInt256(usedDeltaLiquidity) -
      SafeCast.toInt256(totalOutstandingSettlements + totalQueuedDeposits);

    if (totalAssetValue < 0) {
      revert NegativeTotalAssetValue(address(this), totalAssetValue);
    }

    // If debt is negative we can simply return TAV - (-debt)
    // availableAssetValue here is +'ve and optionValueDebt is -'ve so we can safely return uint
    if (optionValueDebt < 0) {
      return (SafeCast.toUint256(totalAssetValue - optionValueDebt), DecimalMath.UNIT);
    }

    // ensure a percentage of the pool's NAV is always protected from AMM's insolvency
    int availableAssetValue = totalAssetValue - int(protectedQuote);
    uint longScaleFactor = DecimalMath.UNIT;

    // in extreme situations, if the TAV < reserved cash, set long options to worthless
    if (availableAssetValue < 0) {
      return (SafeCast.toUint256(totalAssetValue), 0);
    }

    // NOTE: the longScaleFactor is calculated using the total option debt however only the long debts are scaled down
    // when paid out. Therefore the asset value affected is less than the real amount.
    if (availableAssetValue < optionValueDebt) {
      // both guaranteed to be positive
      longScaleFactor = SafeCast.toUint256(availableAssetValue).divideDecimal(SafeCast.toUint256(optionValueDebt));
    }

    return (
      SafeCast.toUint256(totalAssetValue) - SafeCast.toUint256(optionValueDebt).multiplyDecimal(longScaleFactor),
      longScaleFactor
    );
  }
  function _getLiquidity(uint basePrice, uint totalPoolValue, uint reservedTokenValue, uint usedDelta, uint pendingDelta, uint longScaleFactor) internal view returns (Liquidity memory) {
    Liquidity memory liquidity = Liquidity(0, 0, 0, 0, 0, 0, 0);
    liquidity.NAV = totalPoolValue;
    liquidity.usedDeltaLiquidity = usedDelta;

    uint usedQuote = totalOutstandingSettlements + totalQueuedDeposits;
    uint totalQuote = ConvertDecimals.convertTo18(quoteAsset.balanceOf(address(this)), quoteAsset.decimals());
    uint availableQuote = totalQuote > usedQuote ? totalQuote - usedQuote : 0;

    liquidity.pendingDeltaLiquidity = pendingDelta > availableQuote ? availableQuote : pendingDelta;
    availableQuote -= liquidity.pendingDeltaLiquidity;

    // Only reserve lockedColleratal x scalingFactor which unlocks more liquidity
    // No longer need to lock one ETH worth of quote per call sold
    uint reservedCollatLiquidity = lockedCollateral.quote.multiplyDecimal(lpParams.putCollatScalingFactor) +
      lockedCollateral.base.multiplyDecimal(basePrice).multiplyDecimal(lpParams.callCollatScalingFactor);
    liquidity.reservedCollatLiquidity = availableQuote > reservedCollatLiquidity
      ? reservedCollatLiquidity
      : availableQuote;

    availableQuote -= liquidity.reservedCollatLiquidity;
    liquidity.freeLiquidity = availableQuote > reservedTokenValue ? availableQuote - reservedTokenValue : 0;
    liquidity.burnableLiquidity = availableQuote;
    liquidity.longScaleFactor = longScaleFactor;

    return liquidity;
  }
  function _getPoolHedgerLiquidity(uint basePrice) internal view returns (uint pendingDeltaLiquidity, uint usedDeltaLiquidity) {
    if (address(poolHedger) != address(0)) {
      return poolHedger.getHedgingLiquidity(basePrice);
    }
    return (0, 0);
  }
  function _checkCanHedge(uint amountOptions, bool increasesPoolDelta, uint strikeId) internal view {
    if (address(poolHedger) == address(0)) {
      return;
    }
    if (!poolHedger.canHedge(amountOptions, increasesPoolDelta, strikeId)) {
      revert UnableToHedgeDelta(address(this), amountOptions, increasesPoolDelta, strikeId);
    }
  }

  modifier onlyPoolHedger() {
    if (msg.sender != address(poolHedger)) {
      revert OnlyPoolHedger(address(this), msg.sender, address(poolHedger));
    }
    _;
  }
  modifier onlyOptionMarket() {
    if (msg.sender != address(optionMarket)) {
      revert OnlyOptionMarket(address(this), msg.sender, address(optionMarket));
    }
    _;
  }
  modifier onlyShortCollateral() {
    if (msg.sender != address(shortCollateral)) {
      revert OnlyShortCollateral(address(this), msg.sender, address(shortCollateral));
    }
    _;
  }
  event LiquidityPoolParametersUpdated(LiquidityPoolParameters lpParams);
  event CircuitBreakerParametersUpdated(CircuitBreakerParameters cbParams);
  event PoolHedgerUpdated(PoolHedger poolHedger);
  event PutCollateralLocked(uint quoteLocked, uint lockedCollateralQuote);
  event PutCollateralFreed(uint quoteFreed, uint lockedCollateralQuote);
  event CallCollateralLocked(uint baseLocked, uint lockedCollateralBase);
  event CallCollateralFreed(uint baseFreed, uint lockedCollateralBase);
  event BoardSettlement(uint insolventSettlementAmount, uint amountQuoteReserved, uint totalOutstandingSettlements);
  event OutstandingSettlementSent(address indexed user, uint amount, uint totalOutstandingSettlements);
  event BasePurchased(uint quoteSpent, uint baseReceived);
  event BaseSold(uint amountBase, uint quoteReceived);
  event PremiumTransferred(address indexed recipient, uint recipientPortion, uint optionMarketPortion);
  event QuoteTransferredToPoolHedger(uint amountQuote);
  event InsolventSettlementAmountUpdated(uint amountQuoteAdded, uint totalInsolventSettlementAmount);
  event DepositQueued(address indexed depositor, address indexed beneficiary, uint indexed depositQueueId, uint amountDeposited, uint totalQueuedDeposits, uint timestamp);
  event DepositProcessed(address indexed caller, address indexed beneficiary, uint indexed depositQueueId, uint amountDeposited, uint tokenPrice, uint tokensReceived, uint timestamp);
  event WithdrawProcessed(address indexed caller, address indexed beneficiary, uint indexed withdrawalQueueId, uint amountWithdrawn, uint tokenPrice, uint quoteReceived, uint totalQueuedWithdrawals, uint timestamp);
  event WithdrawPartiallyProcessed(address indexed caller, address indexed beneficiary, uint indexed withdrawalQueueId, uint amountWithdrawn, uint tokenPrice, uint quoteReceived, uint totalQueuedWithdrawals, uint timestamp);
  event WithdrawReverted(address indexed caller, address indexed beneficiary, uint indexed withdrawalQueueId, uint tokenPrice, uint totalQueuedWithdrawals, uint timestamp, uint tokensReturned);
  event WithdrawQueued(address indexed withdrawer, address indexed beneficiary, uint indexed withdrawalQueueId, uint amountWithdrawn, uint totalQueuedWithdrawals, uint timestamp);
  event CircuitBreakerUpdated(uint newTimestamp, bool ivVarianceThresholdCrossed, bool skewVarianceThresholdCrossed, bool liquidityThresholdCrossed, bool contractAdjustmentEvent);
  event BoardSettlementCircuitBreakerUpdated(uint newTimestamp);
  event CheckingCanProcess(uint entryId, bool boardNotStale, bool validEntry, bool guardianBypass, bool delaysExpired);

  error InvalidLiquidityPoolParameters(address thrower, LiquidityPoolParameters lpParams);
  error InvalidCircuitBreakerParameters(address thrower, CircuitBreakerParameters cbParams);
  error CannotRecoverQuoteBase(address thrower);
  error InvalidBeneficiaryAddress(address thrower, address beneficiary);
  error MinimumDepositNotMet(address thrower, uint amountQuote, uint minDeposit);
  error MinimumWithdrawNotMet(address thrower, uint amountQuote, uint minWithdraw);
  error LockingMoreQuoteThanIsFree(address thrower, uint quoteToLock, uint freeLiquidity, Collateral lockedCollateral);
  error SendPremiumNotEnoughCollateral(address thrower, uint premium, uint reservedFee, uint freeLiquidity);
  error NotEnoughFreeToReclaimInsolvency(address thrower, uint amountQuote, Liquidity liquidity);
  error OptionValueDebtExceedsTotalAssets(address thrower, int totalAssetValue, int optionValueDebt);
  error NegativeTotalAssetValue(address thrower, int totalAssetValue);
  error OnlyPoolHedger(address thrower, address caller, address poolHedger);
  error OnlyOptionMarket(address thrower, address caller, address optionMarket);
  error OnlyShortCollateral(address thrower, address caller, address poolHedger);
  error QuoteTransferFailed(address thrower, address from, address to, uint realAmount);
  error BaseTransferFailed(address thrower, address from, address to, uint realAmount);
  error QuoteApprovalFailure(address thrower, address approvee, uint amount);
  error BaseApprovalFailure(address thrower, address approvee, uint amount);
  error UnableToHedgeDelta(address thrower, uint amountOptions, bool increasesDelta, uint strikeId);
}
