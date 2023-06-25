//SPDX-License-Identifier: ISC
pragma solidity 0.8.16;
import "openzeppelin-contracts-4.4.1/token/ERC20/ERC20.sol";
import "./synthetix/DecimalMath.sol";
import "./synthetix/Owned.sol";
import "./libraries/SimpleInitializable.sol";
import "./interfaces/ILiquidityTracker.sol";
contract LiquidityToken is ERC20, Owned, SimpleInitializable {
  using DecimalMath for uint;
  address public liquidityPool;
  ILiquidityTracker public liquidityTracker;
  constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) Owned() {}
  function init(address _liquidityPool) external onlyOwner initializer {
    liquidityPool = _liquidityPool;
  }
  function setLiquidityTracker(ILiquidityTracker _liquidityTracker) external onlyOwner {
    liquidityTracker = _liquidityTracker;
    emit LiquidityTrackerSet(liquidityTracker);
  }
  function mint(address account, uint tokenAmount) external onlyLiquidityPool {
    _mint(account, tokenAmount);
  }
  function burn(address account, uint tokenAmount) external onlyLiquidityPool {
    _burn(account, tokenAmount);
  }
  function _afterTokenTransfer(address from, address to, uint amount) internal override {
    if (address(liquidityTracker) != address(0)) {
      if (from != address(0)) {
        liquidityTracker.removeTokens(from, amount);
      }
      if (to != address(0)) {
        liquidityTracker.addTokens(to, amount);
      }
    }
  }
  modifier onlyLiquidityPool() {
    if (msg.sender != liquidityPool) {
      revert OnlyLiquidityPool(address(this), msg.sender, liquidityPool);
    }
    _;
  }
  event LiquidityTrackerSet(ILiquidityTracker liquidityTracker);
  error OnlyLiquidityPool(address thrower, address caller, address liquidityPool);
}
