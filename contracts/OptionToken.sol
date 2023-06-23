//SPDX-License-Identifier: ISC
pragma solidity 0.8.16;
import "openzeppelin-contracts-4.4.1/utils/math/SafeCast.sol";
import "openzeppelin-contracts-4.4.1/token/ERC721/extensions/ERC721Enumerable.sol";
import "openzeppelin-contracts-4.4.1/security/ReentrancyGuard.sol";
import "./synthetix/DecimalMath.sol";
import "./synthetix/Owned.sol";
import "./libraries/ConvertDecimals.sol";
import "./libraries/SimpleInitializable.sol";

import "./OptionMarket.sol";
import "./BaseExchangeAdapter.sol";
import "./OptionGreekCache.sol";

contract OptionToken is Owned, SimpleInitializable, ReentrancyGuard, ERC721Enumerable {
  using DecimalMath for uint;
  enum PositionState {
    EMPTY,
    ACTIVE,
    CLOSED,
    LIQUIDATED,
    SETTLED,
    MERGED
  }
  enum PositionUpdatedType {
    OPENED,
    ADJUSTED,
    CLOSED,
    SPLIT_FROM,
    SPLIT_INTO,
    MERGED,
    MERGED_INTO,
    SETTLED,
    LIQUIDATED,
    TRANSFER
  }
  struct OptionPosition {
    uint positionId;
    uint strikeId;
    OptionMarket.OptionType optionType;
    uint amount;
    uint collateral;
    PositionState state;
  }
  struct PartialCollateralParameters {
    uint penaltyRatio;
    uint liquidatorFeeRatio;
    uint smFeeRatio;
    uint minLiquidationFee;
  }
  struct PositionWithOwner {
    uint positionId;
    uint strikeId;
    OptionMarket.OptionType optionType;
    uint amount;
    uint collateral;
    PositionState state;
    address owner;
  }
  struct LiquidationFees {
    uint returnCollateral;
    uint lpPremiums;
    uint lpFee;
    uint liquidatorFee;
    uint smFee;
    uint insolventAmount;
  }
  OptionMarket internal optionMarket;
  OptionGreekCache internal greekCache;
  address internal shortCollateral;
  BaseExchangeAdapter internal exchangeAdapter;
  mapping(uint => OptionPosition) public positions;
  uint public nextId = 1;
  string public baseURI;
  PartialCollateralParameters public partialCollatParams;
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
  modifier notGlobalPaused() {
    exchangeAdapter.requireNotGlobalPaused(address(optionMarket));
    _;
  }
  constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) Owned() {}
  function init(OptionMarket _optionMarket, OptionGreekCache _greekCache, address _shortCollateral, BaseExchangeAdapter _exchangeAdapter) external onlyOwner initializer {
    optionMarket = _optionMarket;
    greekCache = _greekCache;
    shortCollateral = _shortCollateral;
    exchangeAdapter = _exchangeAdapter;
  }
  //  settings
  function setPartialCollateralParams(PartialCollateralParameters memory _partialCollatParams) external onlyOwner {
    if (
      _partialCollatParams.penaltyRatio > DecimalMath.UNIT ||
      (_partialCollatParams.liquidatorFeeRatio + _partialCollatParams.smFeeRatio) > DecimalMath.UNIT
    ) {
      revert InvalidPartialCollateralParameters(address(this), _partialCollatParams);
    }

    partialCollatParams = _partialCollatParams;
    emit PartialCollateralParamsSet(partialCollatParams);
  }
  function setURI(string memory newURI) external onlyOwner {
    baseURI = newURI;
    emit URISet(baseURI);
  }
  function _baseURI() internal view override returns (string memory) {
    return baseURI;
  }
  // func
  function adjustPosition(OptionMarket.TradeParameters memory trade, uint strikeId, address trader, uint positionId, uint optionCost, uint setCollateralTo, bool isOpen) external onlyOptionMarket returns (uint, int pendingCollateral) {
    OptionPosition storage position;
    bool newPosition = false;
    if (positionId == 0) {
      if (!isOpen) {
        revert CannotClosePositionZero(address(this));
      }
      if (trade.amount == 0) {
        revert CannotOpenZeroAmount(address(this));
      }

      positionId = nextId++;
      _mint(trader, positionId);
      position = positions[positionId];

      position.positionId = positionId;
      position.strikeId = strikeId;
      position.optionType = trade.optionType;
      position.state = PositionState.ACTIVE;

      newPosition = true;
    } else {
      position = positions[positionId];
    }

    if (
      position.positionId == 0 ||
      position.state != PositionState.ACTIVE ||
      position.strikeId != strikeId ||
      position.optionType != trade.optionType
    ) {
      revert CannotAdjustInvalidPosition(
        address(this),
        positionId,
        position.positionId == 0,
        position.state != PositionState.ACTIVE,
        position.strikeId != strikeId,
        position.optionType != trade.optionType
      );
    }
    if (trader != ownerOf(position.positionId)) {
      revert OnlyOwnerCanAdjustPosition(address(this), positionId, trader, ownerOf(position.positionId));
    }

    if (isOpen) {
      position.amount += trade.amount;
    } else {
      position.amount -= trade.amount;
    }

    if (position.amount == 0) {
      if (setCollateralTo != 0) {
        revert FullyClosingWithNonZeroSetCollateral(address(this), position.positionId, setCollateralTo);
      }
      // return all collateral to the user if they fully close the position
      pendingCollateral = -(SafeCast.toInt256(position.collateral));
      if (
        trade.optionType == OptionMarket.OptionType.SHORT_CALL_QUOTE ||
        trade.optionType == OptionMarket.OptionType.SHORT_PUT_QUOTE
      ) {
        // Add the optionCost to the inverted collateral (subtract from collateral)
        pendingCollateral += SafeCast.toInt256(optionCost);
      }
      position.collateral = 0;
      position.state = PositionState.CLOSED;
      _burn(position.positionId); // burn tokens that have been closed.
      emit PositionUpdated(position.positionId, trader, PositionUpdatedType.CLOSED, position, block.timestamp);
      return (position.positionId, pendingCollateral);
    }

    if (_isShort(trade.optionType)) {
      uint preCollateral = position.collateral;
      if (trade.optionType != OptionMarket.OptionType.SHORT_CALL_BASE) {
        if (isOpen) {
          preCollateral += optionCost;
        } else {
          // This will only throw if the position is insolvent
          preCollateral -= optionCost;
        }
      }
      pendingCollateral = SafeCast.toInt256(setCollateralTo) - SafeCast.toInt256(preCollateral);
      position.collateral = setCollateralTo;
      if (canLiquidate(position, trade.expiry, trade.strikePrice, trade.spotPrice)) {
        revert AdjustmentResultsInMinimumCollateralNotBeingMet(address(this), position, trade.spotPrice);
      }
    }
    // if long, pendingCollateral is 0 - ignore

    emit PositionUpdated(
      position.positionId,
      trader,
      newPosition ? PositionUpdatedType.OPENED : PositionUpdatedType.ADJUSTED,
      position,
      block.timestamp
    );

    return (position.positionId, pendingCollateral);
  }
  function addCollateral(uint positionId, uint amountCollateral) external onlyOptionMarket returns (OptionMarket.OptionType optionType) {
    OptionPosition storage position = positions[positionId];

    if (position.positionId == 0 || position.state != PositionState.ACTIVE || !_isShort(position.optionType)) {
      revert AddingCollateralToInvalidPosition(
        address(this),
        positionId,
        position.positionId == 0,
        position.state != PositionState.ACTIVE,
        !_isShort(position.optionType)
      );
    }

    _requireStrikeNotExpired(position.strikeId);

    position.collateral += amountCollateral;

    emit PositionUpdated(
      position.positionId,
      ownerOf(positionId),
      PositionUpdatedType.ADJUSTED,
      position,
      block.timestamp
    );

    return position.optionType;
  }
  function settlePositions(uint[] memory positionIds) external onlyShortCollateral {
    uint positionsLength = positionIds.length;
    for (uint i = 0; i < positionsLength; ++i) {
      positions[positionIds[i]].state = PositionState.SETTLED;

      emit PositionUpdated(
        positionIds[i],
        ownerOf(positionIds[i]),
        PositionUpdatedType.SETTLED,
        positions[positionIds[i]],
        block.timestamp
      );

      _burn(positionIds[i]);
    }
  }
  function liquidate(uint positionId, OptionMarket.TradeParameters memory trade, uint totalCost) external onlyOptionMarket returns (LiquidationFees memory liquidationFees) {
    OptionPosition storage position = positions[positionId];

    if (!canLiquidate(position, trade.expiry, trade.strikePrice, trade.spotPrice)) {
      revert PositionNotLiquidatable(address(this), position, trade.spotPrice);
    }

    uint convertedMinLiquidationFee = partialCollatParams.minLiquidationFee;
    uint insolvencyMultiplier = DecimalMath.UNIT;
    if (trade.optionType == OptionMarket.OptionType.SHORT_CALL_BASE) {
      totalCost = exchangeAdapter.estimateExchangeToExactQuote(address(optionMarket), totalCost);
      convertedMinLiquidationFee = partialCollatParams.minLiquidationFee.divideDecimal(trade.spotPrice);
      insolvencyMultiplier = trade.spotPrice;
    }

    position.state = PositionState.LIQUIDATED;

    emit PositionUpdated(
      position.positionId,
      ownerOf(position.positionId),
      PositionUpdatedType.LIQUIDATED,
      position,
      block.timestamp
    );

    _burn(positionId);

    return getLiquidationFees(totalCost, position.collateral, convertedMinLiquidationFee, insolvencyMultiplier);
  }
  function split(uint positionId, uint newAmount, uint newCollateral, address recipient) external nonReentrant notGlobalPaused returns (uint newPositionId) {
    OptionPosition storage originalPosition = positions[positionId];

    // Will both check whether position is valid and whether approved to split
    // Will revert if it is an invalid positionId or inactive position (as they cannot be owned)
    if (!_isApprovedOrOwner(msg.sender, originalPosition.positionId)) {
      revert SplittingUnapprovedPosition(address(this), msg.sender, originalPosition.positionId);
    }

    _requireStrikeNotExpired(originalPosition.strikeId);

    // Do not allow splits that result in originalPosition.amount = 0 && newPosition.amount = 0;
    if (newAmount >= originalPosition.amount || newAmount == 0) {
      revert InvalidSplitAmount(address(this), originalPosition.amount, newAmount);
    }

    originalPosition.amount -= newAmount;

    // Create new position
    newPositionId = nextId++;
    _mint(recipient, newPositionId);

    OptionPosition storage newPosition = positions[newPositionId];
    newPosition.positionId = newPositionId;
    newPosition.amount = newAmount;
    newPosition.strikeId = originalPosition.strikeId;
    newPosition.optionType = originalPosition.optionType;
    newPosition.state = PositionState.ACTIVE;

    if (_isShort(originalPosition.optionType)) {
      // only change collateral if partial option type
      originalPosition.collateral -= newCollateral;
      newPosition.collateral = newCollateral;

      (uint strikePrice, uint expiry) = optionMarket.getStrikeAndExpiry(originalPosition.strikeId);
      uint spotPrice = exchangeAdapter.getSpotPriceForMarket(
        address(optionMarket),
        BaseExchangeAdapter.PriceType.REFERENCE
      );

      if (canLiquidate(originalPosition, expiry, strikePrice, spotPrice)) {
        revert ResultingOriginalPositionLiquidatable(address(this), originalPosition, spotPrice);
      }
      if (canLiquidate(newPosition, expiry, strikePrice, spotPrice)) {
        revert ResultingNewPositionLiquidatable(address(this), newPosition, spotPrice);
      }
    }
    emit PositionUpdated(
      newPosition.positionId,
      recipient,
      PositionUpdatedType.SPLIT_INTO,
      newPosition,
      block.timestamp
    );
    emit PositionUpdated(
      originalPosition.positionId,
      ownerOf(positionId),
      PositionUpdatedType.SPLIT_FROM,
      originalPosition,
      block.timestamp
    );
  }
  function merge(uint[] memory positionIds) external nonReentrant notGlobalPaused {
    uint positionsLen = positionIds.length;
    if (positionsLen < 2) {
      revert MustMergeTwoOrMorePositions(address(this));
    }

    OptionPosition storage firstPosition = positions[positionIds[0]];
    if (!_isApprovedOrOwner(msg.sender, firstPosition.positionId)) {
      revert MergingUnapprovedPosition(address(this), msg.sender, firstPosition.positionId);
    }
    _requireStrikeNotExpired(firstPosition.strikeId);

    address positionOwner = ownerOf(firstPosition.positionId);

    OptionPosition storage nextPosition;
    for (uint i = 1; i < positionsLen; ++i) {
      nextPosition = positions[positionIds[i]];

      if (!_isApprovedOrOwner(msg.sender, nextPosition.positionId)) {
        revert MergingUnapprovedPosition(address(this), msg.sender, nextPosition.positionId);
      }

      if (
        positionOwner != ownerOf(nextPosition.positionId) ||
        firstPosition.strikeId != nextPosition.strikeId ||
        firstPosition.optionType != nextPosition.optionType ||
        firstPosition.positionId == nextPosition.positionId
      ) {
        revert PositionMismatchWhenMerging(
          address(this),
          firstPosition,
          nextPosition,
          positionOwner != ownerOf(nextPosition.positionId),
          firstPosition.strikeId != nextPosition.strikeId,
          firstPosition.optionType != nextPosition.optionType,
          firstPosition.positionId == nextPosition.positionId
        );
      }

      firstPosition.amount += nextPosition.amount;
      firstPosition.collateral += nextPosition.collateral;
      nextPosition.collateral = 0;
      nextPosition.amount = 0;
      nextPosition.state = PositionState.MERGED;

      // By burning the position, if the position owner is queried again, it will revert.
      _burn(positionIds[i]);

      emit PositionUpdated(
        nextPosition.positionId,
        positionOwner,
        PositionUpdatedType.MERGED,
        nextPosition,
        block.timestamp
      );
    }

    // make sure final position is not liquidatable
    if (_isShort(firstPosition.optionType)) {
      (uint strikePrice, uint expiry) = optionMarket.getStrikeAndExpiry(firstPosition.strikeId);
      uint spotPrice = exchangeAdapter.getSpotPriceForMarket(
        address(optionMarket),
        BaseExchangeAdapter.PriceType.REFERENCE
      );
      if (canLiquidate(firstPosition, expiry, strikePrice, spotPrice)) {
        revert ResultingNewPositionLiquidatable(address(this), firstPosition, spotPrice);
      }
    }

    emit PositionUpdated(
      firstPosition.positionId,
      positionOwner,
      PositionUpdatedType.MERGED_INTO,
      firstPosition,
      block.timestamp
    );
  }
  function _isShort(OptionMarket.OptionType optionType) internal pure returns (bool shortPosition) {
    shortPosition = (uint(optionType) >= uint(OptionMarket.OptionType.SHORT_CALL_BASE)) ? true : false;
  }
  function _beforeTokenTransfer(address from, address to, uint tokenId) internal override {
    super._beforeTokenTransfer(from, to, tokenId);

    if (from != address(0) && to != address(0)) {
      emit PositionUpdated(tokenId, to, PositionUpdatedType.TRANSFER, positions[tokenId], block.timestamp);
    }
  }

  // view
  function canLiquidate(OptionPosition memory position, uint expiry, uint strikePrice, uint spotPrice) public view returns (bool) {
    if (!_isShort(position.optionType)) {
      return false;
    }
    if (position.state != PositionState.ACTIVE) {
      return false;
    }

    // Option expiry is checked in optionMarket._doTrade()
    // Will revert if called post expiry
    uint minCollateral = greekCache.getMinCollateral(
      position.optionType,
      strikePrice,
      expiry,
      spotPrice,
      position.amount
    );

    return position.collateral < minCollateral;
  }
  function getLiquidationFees(uint gwavPremium, uint userPositionCollateral, uint convertedMinLiquidationFee, uint insolvencyMultiplier) public view returns (LiquidationFees memory liquidationFees) {
    // User is fully solvent
    uint minOwed = gwavPremium + convertedMinLiquidationFee;
    uint totalCollatPenalty;

    if (userPositionCollateral >= minOwed) {
      uint remainingCollateral = userPositionCollateral - gwavPremium;
      totalCollatPenalty = remainingCollateral.multiplyDecimal(partialCollatParams.penaltyRatio);
      if (totalCollatPenalty < convertedMinLiquidationFee) {
        totalCollatPenalty = convertedMinLiquidationFee;
      }
      liquidationFees.returnCollateral = remainingCollateral - totalCollatPenalty;
    } else {
      // user is insolvent
      liquidationFees.returnCollateral = 0;
      // edge case where short call base collat < minLiquidationFee
      if (userPositionCollateral >= convertedMinLiquidationFee) {
        totalCollatPenalty = convertedMinLiquidationFee;
        liquidationFees.insolventAmount = (minOwed - userPositionCollateral).multiplyDecimal(insolvencyMultiplier);
      } else {
        totalCollatPenalty = userPositionCollateral;
        liquidationFees.insolventAmount = (gwavPremium).multiplyDecimal(insolvencyMultiplier);
      }
    }
    liquidationFees.smFee = totalCollatPenalty.multiplyDecimal(partialCollatParams.smFeeRatio);
    liquidationFees.liquidatorFee = totalCollatPenalty.multiplyDecimal(partialCollatParams.liquidatorFeeRatio);
    liquidationFees.lpFee = totalCollatPenalty - (liquidationFees.smFee + liquidationFees.liquidatorFee);
    liquidationFees.lpPremiums = userPositionCollateral - totalCollatPenalty - liquidationFees.returnCollateral;
  }
  function getPositionState(uint positionId) external view returns (PositionState) {
    return positions[positionId].state;
  }
  function getOptionPosition(uint positionId) external view returns (OptionPosition memory) {
    return positions[positionId];
  }
  function getOptionPositions(uint[] memory positionIds) external view returns (OptionPosition[] memory) {
    uint positionsLen = positionIds.length;

    OptionPosition[] memory result = new OptionPosition[](positionsLen);
    for (uint i = 0; i < positionsLen; ++i) {
      result[i] = positions[positionIds[i]];
    }
    return result;
  }
  function getPositionWithOwner(uint positionId) external view returns (PositionWithOwner memory) {
    return _getPositionWithOwner(positionId);
  }
  function getPositionsWithOwner(uint[] memory positionIds) external view returns (PositionWithOwner[] memory) {
    uint positionsLen = positionIds.length;

    PositionWithOwner[] memory result = new PositionWithOwner[](positionsLen);
    for (uint i = 0; i < positionsLen; ++i) {
      result[i] = _getPositionWithOwner(positionIds[i]);
    }
    return result;
  }
  function getOwnerPositions(address target) external view returns (OptionPosition[] memory) {
    uint balance = balanceOf(target);
    OptionPosition[] memory result = new OptionPosition[](balance);
    for (uint i = 0; i < balance; ++i) {
      result[i] = positions[ERC721Enumerable.tokenOfOwnerByIndex(target, i)];
    }
    return result;
  }
  function _getPositionWithOwner(uint positionId) internal view returns (PositionWithOwner memory) {
    OptionPosition memory position = positions[positionId];
    return
      PositionWithOwner({
        positionId: position.positionId,
        strikeId: position.strikeId,
        optionType: position.optionType,
        amount: position.amount,
        collateral: position.collateral,
        state: position.state,
        owner: ownerOf(positionId)
      });
  }
  function getPartialCollatParams() external view returns (PartialCollateralParameters memory) {
    return partialCollatParams;
  }
  function _requireStrikeNotExpired(uint strikeId) internal view {
    (, uint priceAtExpiry, , ) = optionMarket.getSettlementParameters(strikeId);
    if (priceAtExpiry != 0) {
      revert StrikeIsSettled(address(this), strikeId);
    }
  }

  event URISet(string URI);
  event PartialCollateralParamsSet(PartialCollateralParameters partialCollateralParams);
  event PositionUpdated(uint indexed positionId, address indexed owner, PositionUpdatedType indexed updatedType, OptionPosition position, uint timestamp);
  error InvalidPartialCollateralParameters(address thrower, PartialCollateralParameters partialCollatParams);
  error AdjustmentResultsInMinimumCollateralNotBeingMet(address thrower, OptionPosition position, uint spotPrice);
  error CannotClosePositionZero(address thrower);
  error CannotOpenZeroAmount(address thrower);
  error CannotAdjustInvalidPosition(address thrower, uint positionId, bool invalidPositionId, bool positionInactive, bool strikeMismatch, bool optionTypeMismatch);
  error OnlyOwnerCanAdjustPosition(address thrower, uint positionId, address trader, address owner);
  error FullyClosingWithNonZeroSetCollateral(address thrower, uint positionId, uint setCollateralTo);
  error AddingCollateralToInvalidPosition(address thrower, uint positionId, bool invalidPositionId, bool positionInactive, bool isShort);
  error PositionNotLiquidatable(address thrower, OptionPosition position, uint spotPrice);
  error SplittingUnapprovedPosition(address thrower, address caller, uint positionId);
  error InvalidSplitAmount(address thrower, uint originalPositionAmount, uint splitAmount);
  error ResultingOriginalPositionLiquidatable(address thrower, OptionPosition position, uint spotPrice);
  error ResultingNewPositionLiquidatable(address thrower, OptionPosition position, uint spotPrice);
  error MustMergeTwoOrMorePositions(address thrower);
  error MergingUnapprovedPosition(address thrower, address caller, uint positionId);
  error PositionMismatchWhenMerging(address thrower, OptionPosition firstPosition, OptionPosition nextPosition, bool ownerMismatch, bool strikeMismatch, bool optionTypeMismatch, bool duplicatePositionId);
  error StrikeIsSettled(address thrower, uint strikeId);
  error OnlyOptionMarket(address thrower, address caller, address optionMarket);
  error OnlyShortCollateral(address thrower, address caller, address shortCollateral);
}
