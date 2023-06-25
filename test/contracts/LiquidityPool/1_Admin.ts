import { expect } from 'chai';
import { ethers } from 'hardhat';
import { DAY_SEC, HOUR_SEC, MONTH_SEC, toBN, WEEK_SEC, YEAR_SEC } from '../../../scripts/util/web3utils';
import { CircuitBreakerParametersStruct, LiquidityPoolParametersStruct } from '../../../typechain-types/LiquidityPool';
import { DEFAULT_CB_PARAMS, DEFAULT_LIQUIDITY_POOL_PARAMS } from '../../utils/defaultParams';
import { seedFixture } from '../../utils/fixture';
import { hre } from '../../utils/testSetup';
import { TestERC20SetDecimals } from '../../../typechain-types';
import {formatEther, parseEther} from "ethers/lib/utils";
import {constants} from "ethers";

const modLPParams = {
  depositDelay: MONTH_SEC,
  withdrawalDelay: WEEK_SEC / 2,
  withdrawalFee: toBN('0.1'),
  guardianDelay: DAY_SEC,
} as LiquidityPoolParametersStruct;

const modCBParams = {
  liquidityCBThreshold: toBN('0.1'),
  liquidityCBTimeout: 300 * HOUR_SEC,
  ivVarianceCBThreshold: toBN('0.01'),
  skewVarianceCBTimeout: WEEK_SEC,
  boardSettlementCBTimeout: HOUR_SEC * 5,
} as CircuitBreakerParametersStruct;

const setLPParams = async (overrides?: any) => {
  return await hre.f.c.liquidityPool.setLiquidityPoolParameters({
    ...DEFAULT_LIQUIDITY_POOL_PARAMS,
    ...(overrides || {}),
  });
};
const setCBParams = async (overrides?: any) => {
  return await hre.f.c.liquidityPool.setCircuitBreakerParameters({
    ...DEFAULT_CB_PARAMS,
    ...(overrides || {}),
  });
};

const expectInvalidLPParams = async (overrides?: any) => {
  await expect(setLPParams(overrides)).revertedWith('InvalidLiquidityPoolParameters');
};

const expectInvalidCBParams = async (overrides?: any) => {
  await expect(setCBParams(overrides)).revertedWith('InvalidCircuitBreakerParameters');
};

describe('LiquidityPool - Admin', async () => {
  beforeEach(seedFixture);

  describe('Initialization', async () => {
    it('cannot init twice', async () => {
      await expect(
        hre.f.c.liquidityPool.init(
          ethers.constants.AddressZero,
          ethers.constants.AddressZero,
          ethers.constants.AddressZero,
          ethers.constants.AddressZero,
          ethers.constants.AddressZero,
          ethers.constants.AddressZero,
          ethers.constants.AddressZero,
          ethers.constants.AddressZero,
        ),
      ).to.be.revertedWith('AlreadyInitialised');
    });
    it('only owner can initialize', async () => {
      await expect(
        hre.f.c.liquidityPool
          .connect(hre.f.alice)
          .init(
            ethers.constants.AddressZero,
            ethers.constants.AddressZero,
            ethers.constants.AddressZero,
            ethers.constants.AddressZero,
            ethers.constants.AddressZero,
            ethers.constants.AddressZero,
            ethers.constants.AddressZero,
            ethers.constants.AddressZero,
          ),
      ).to.be.revertedWith('OnlyOwner');
    });
    it.skip('delegates snx approval when initialized', async () => {
      expect(
        await hre.f.c.snx.delegateApprovals.canExchangeOnBehalf(
          hre.f.c.synthetixAdapter.address,
          hre.f.c.liquidityPool.address,
        ),
      ).be.true;
    });
    it("test001 => LP params", async() => {
      const lp = hre.f.c.liquidityPool;
      expect(await lp.totalQueuedDeposits()).eq(0);
      expect(await lp.queuedDepositHead()).eq(1);
      expect(await lp.nextQueuedDepositId()).eq(1);
      expect(await lp.totalQueuedWithdrawals()).eq(0);
      expect(await lp.queuedWithdrawalHead()).eq(1);
      expect(await lp.nextQueuedWithdrawalId()).eq(1);
      expect(await lp.CBTimestamp()).eq(0);

      expect(await lp.getTotalTokenSupply()).eq(parseEther('500000'));
      expect(await lp.getTokenPrice()).eq(parseEther('1.0'));
      const _getLiquidity = await lp.getLiquidity();
      expect(_getLiquidity[0]).eq(parseEther('500000'));
      expect(_getLiquidity[1]).eq(parseEther('500000'));
      expect(_getLiquidity[2]).eq(0);
      expect(_getLiquidity[3]).eq(0);
      expect(_getLiquidity[4]).eq(0);
      expect(_getLiquidity[5]).eq(parseEther('500000'));
      expect(_getLiquidity[6]).eq(parseEther('1.0'));
      expect(await lp.getTotalPoolValueQuote()).eq(parseEther('500000'));

      const _getLpParams = await lp.getLpParams();
      console.log(`${_getLpParams}`);
    });
    it("test002 => lt", async() => {
      const lt = hre.f.c.liquidityToken;
      expect(await lt.liquidityPool()).not.eq(constants.AddressZero);
      expect(await lt.liquidityTracker()).eq(constants.AddressZero);
      expect(await lt.name()).eq('sUSD/sETH Pool Tokens');
      expect(await lt.symbol()).eq('LyraELPT');
      expect(await lt.totalSupply()).eq(parseEther('500000'));
    })
  });

  describe('LP params', async () => {
    it('sets liquidity pool params and updates', async () => {
      const oldLPParams = await hre.f.c.liquidityPool.lpParams();
      const oldCBParams = await hre.f.c.liquidityPool.cbParams();

      await setLPParams(modLPParams);
      await setCBParams(modCBParams);

      const newLPParams = await hre.f.c.liquidityPool.lpParams();
      const newCBParams = await hre.f.c.liquidityPool.cbParams();
      // Verify all parameters updated as expected
      expect(oldLPParams.depositDelay).not.eq(newLPParams.depositDelay);
      expect(newLPParams.depositDelay).eq(modLPParams.depositDelay);

      expect(oldLPParams.withdrawalDelay).not.eq(newLPParams.withdrawalDelay);
      expect(newLPParams.withdrawalDelay).eq(modLPParams.withdrawalDelay);

      expect(oldLPParams.withdrawalFee).not.eq(newLPParams.withdrawalFee);
      expect(newLPParams.withdrawalFee).eq(modLPParams.withdrawalFee);

      expect(oldCBParams.liquidityCBThreshold).not.eq(newCBParams.liquidityCBThreshold);
      expect(newCBParams.liquidityCBThreshold).eq(modCBParams.liquidityCBThreshold);

      expect(oldCBParams.liquidityCBTimeout).not.eq(newCBParams.liquidityCBTimeout);
      expect(newCBParams.liquidityCBTimeout).eq(modCBParams.liquidityCBTimeout);

      expect(oldCBParams.ivVarianceCBThreshold).not.eq(newCBParams.ivVarianceCBThreshold);
      expect(newCBParams.ivVarianceCBThreshold).eq(modCBParams.ivVarianceCBThreshold);

      expect(oldCBParams.skewVarianceCBTimeout).not.eq(newCBParams.skewVarianceCBTimeout);
      expect(newCBParams.skewVarianceCBTimeout).eq(modCBParams.skewVarianceCBTimeout);

      expect(oldLPParams.guardianDelay).not.eq(newLPParams.guardianDelay);
      expect(newLPParams.guardianDelay).eq(modLPParams.guardianDelay);

      expect(oldCBParams.boardSettlementCBTimeout).not.eq(newCBParams.boardSettlementCBTimeout);
      expect(newCBParams.boardSettlementCBTimeout).eq(modCBParams.boardSettlementCBTimeout);
    });
  });

  it('Lp Params revert testing', async () => {
    await expectInvalidLPParams({ depositDelay: YEAR_SEC * 2 });
    await expectInvalidLPParams({ withdrawalDelay: YEAR_SEC * 2 });
    await expectInvalidLPParams({ withdrawalFee: toBN('3') });
    await expectInvalidLPParams({ guardianDelay: YEAR_SEC * 2 });
  });
  it('Lp Params revert testing', async () => {
    await expectInvalidCBParams({ liquidityCBThreshold: toBN('20') });
    await expectInvalidCBParams({ ivVarianceCBTimeout: 61 * DAY_SEC });
    await expectInvalidCBParams({ skewVarianceCBTimeout: YEAR_SEC * 2 });
    await expectInvalidCBParams({ boardSettlementCBTimeout: YEAR_SEC * 2 });
  });

  it('recovers funds', async () => {
    const newAsset: TestERC20SetDecimals = await (
      await ethers.getContractFactory('TestERC20SetDecimals')
    ).deploy('test', 'test', 18);
    await newAsset.mint(hre.f.c.liquidityPool.address, toBN('1000'));
    await hre.f.c.liquidityPool.recoverFunds(newAsset.address, hre.f.alice.address);
    expect(await newAsset.balanceOf(hre.f.alice.address)).eq(toBN('1000'));
    expect(await newAsset.balanceOf(hre.f.c.liquidityPool.address)).eq(0);
  });

  it('cannot recover quote or base', async () => {
    await hre.f.c.snx.quoteAsset.mint(hre.f.c.liquidityPool.address, toBN('1000'));
    await hre.f.c.snx.baseAsset.mint(hre.f.c.liquidityPool.address, toBN('2000'));
    await expect(
      hre.f.c.liquidityPool.recoverFunds(hre.f.c.snx.quoteAsset.address, hre.f.deployer.address),
    ).revertedWith('CannotRecoverQuoteBase');
    await expect(
      hre.f.c.liquidityPool.recoverFunds(hre.f.c.snx.baseAsset.address, hre.f.deployer.address),
    ).revertedWith('CannotRecoverQuoteBase');
  });
});
