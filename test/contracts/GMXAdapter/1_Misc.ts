import { ethers } from 'hardhat';
import {
  currentTime,
  DEFAULT_DECIMALS, getEventArgs,
  MAX_UINT, MONTH_SEC,
  OptionType,
  toBN,
  UNIT,
  ZERO_ADDRESS
} from '../../../scripts/util/web3utils';
import { DEFAULT_BASE_PRICE, DEFAULT_GMX_ADAPTER_PARAMS, PricingType } from '../../utils/defaultParams';
import { expect } from '../../utils/testSetup';
import { setCLETHPrice } from '../../utils/seedTestSystemGMX';
import { TestGMXVaultChainlinkPrice } from '../../../typechain-types';
import {BigNumber, constants} from 'ethers';
import { hre } from '../../utils/testSetup';
import {allCurrenciesFixtureGMX, seedFixture} from '../../utils/fixture';
import {formatEther, parseEther} from "ethers/lib/utils";
import {BigNumberish} from "@ethersproject/bignumber";
import {
  ALL_TYPES, closePosition, closePositionWithOverrides, compareTradeResults,
  duplicateOrders, openPosition,
  openPositionWithOverrides,
  orderWithCumulativeResults
} from "../../utils/contractHelpers";
import {createDefaultBoardWithOverrides, mockPrice} from "../../utils/seedTestSystem";
import {fastForward, mineBlock, restoreSnapshot, takeSnapshot} from "../../utils/evm";
import {expectActiveAndAmount, expectRoutedFundsOnOpen} from "../OptionMarket/3_SuccessfulOpen";

describe('GMXAdapter', async () => {
  beforeEach(async () => {
    await allCurrenciesFixtureGMX();
    await hre.f.gc.gmx.USDC.approve(hre.f.gc.GMXAdapter.address, MAX_UINT);
    await hre.f.gc.gmx.btc.approve(hre.f.gc.GMXAdapter.address, MAX_UINT);
    await hre.f.gc.gmx.eth.approve(hre.f.gc.GMXAdapter.address, MAX_UINT);

    await hre.f.gc.GMXAdapter.setMarketPricingParams(hre.f.gc.optionMarket.address, {
      ...DEFAULT_GMX_ADAPTER_PARAMS,
      staticSwapFeeEstimate: toBN('1.01'),
    });
  });

  it('misc admin reverts', async () => {
    await expect(hre.f.gc.GMXAdapter.setVaultContract(ZERO_ADDRESS)).revertedWith('InvalidAddress');
    await expect(hre.f.gc.GMXAdapter.setChainlinkFeed(ZERO_ADDRESS, hre.f.gc.gmx.ethPriceFeed.address)).revertedWith(
      'InvalidAddress',
    );
    await expect(hre.f.gc.GMXAdapter.setChainlinkFeed(hre.f.gc.gmx.eth.address, ZERO_ADDRESS)).revertedWith(
      'InvalidPriceFeedAddress',
    );
  });

  it('set interest free rate', async () => {
    await hre.f.gc.GMXAdapter.setRiskFreeRate(hre.f.gc.optionMarket.address, toBN('1'));
    expect((await hre.f.gc.GMXAdapter.rateAndCarry(hre.f.gc.optionMarket.address)).eq(toBN('1'))).to.be.true;
  });

  it('gets spot price', async () => {
    expect(await hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.MAX_PRICE)).eq(
      DEFAULT_BASE_PRICE.mul(101).div(100),
    );
    expect(await hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.MIN_PRICE)).eq(
      DEFAULT_BASE_PRICE.mul(99).div(100),
    );
    expect(await hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.FORCE_MAX)).eq(
      DEFAULT_BASE_PRICE.mul(101).div(100),
    );
    expect(await hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.FORCE_MIN)).eq(
      DEFAULT_BASE_PRICE.mul(99).div(100),
    );
    expect(await hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.REFERENCE)).eq(
      DEFAULT_BASE_PRICE,
    );
    expect(await hre.f.gc.GMXAdapter.getSettlementPriceForMarket(hre.f.gc.optionMarket.address, 0)).eq(
      DEFAULT_BASE_PRICE,
    );

    const newPrice = toBN('1420');

    await setCLETHPrice(hre.f.gc, newPrice);

    expect(await hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.MAX_PRICE)).eq(
      newPrice.mul(101).div(100),
    );
    expect(await hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.MIN_PRICE)).eq(
      newPrice.mul(99).div(100),
    );

    expect(await hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.FORCE_MAX)).eq(
      newPrice.mul(101).div(100),
    );
    expect(await hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.FORCE_MIN)).eq(
      newPrice.mul(99).div(100),
    );
    expect(await hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.REFERENCE)).eq(
      newPrice,
    );
    expect(await hre.f.gc.GMXAdapter.getSettlementPriceForMarket(hre.f.gc.optionMarket.address, 0)).eq(newPrice);
  });

  it('estimates exchange cost', async () => {
    const estimatedBaseAmt = await hre.f.gc.GMXAdapter.estimateExchangeToExactQuote(
      hre.f.gc.optionMarket.address,
      DEFAULT_BASE_PRICE,
    );
    expect(estimatedBaseAmt).gt(toBN('1'));
    expect(estimatedBaseAmt).lt(toBN('1.05'));

    const estimatedQuoteAmt = await hre.f.gc.GMXAdapter.estimateExchangeToExactBase(
      hre.f.gc.optionMarket.address,
      toBN('1'),
    );

    expect(estimatedQuoteAmt).gt(DEFAULT_BASE_PRICE);
    expect(estimatedQuoteAmt).lt(DEFAULT_BASE_PRICE.mul(105).div(100));

    const om = hre.f.gc.optionMarket.address;
    const x = await hre.f.gc.GMXAdapter.estimateExchangeToExactBase(
        om,parseEther('1')
    );
    expect(x).gt(parseEther('1794'));
    expect(x).lt(parseEther('1795'));

    const x2 = await hre.f.gc.GMXAdapter.estimateExchangeToExactBase(om, parseEther('2'));
    console.log(`${formatEther(x2)}`);
  });

  it('test001', async () => {
    const om = hre.f.gc.optionMarket;
    const x2 = await hre.f.gc.GMXAdapter.estimateExchangeToExactBase(om.address, parseEther('2'));
    expect(x2).gt(parseEther("3589"))

    console.log(`${await om.quoteAsset()}`);
    console.log(`${await om.baseAsset()}`);
  });



  it('exchanges for base', async () => {
    const preBaseBal = await hre.f.gc.gmx.eth.balanceOf(hre.f.deployer.address);
    const preQuoteBal = await hre.f.gc.gmx.USDC.balanceOf(hre.f.deployer.address);
    await hre.f.gc.GMXAdapter.exchangeToExactBaseWithLimit(hre.f.gc.optionMarket.address, toBN('1'), toBN('10001'));
    expect((await hre.f.gc.gmx.eth.balanceOf(hre.f.deployer.address)).sub(preBaseBal))
      .gt(toBN('1', DEFAULT_DECIMALS.ETH))
      .lt(toBN('1.05', DEFAULT_DECIMALS.ETH));
    await hre.f.gc.GMXAdapter.exchangeToExactBaseWithLimit(
      hre.f.gc.optionMarket.address,
      toBN('1'),
      DEFAULT_BASE_PRICE.mul(103).div(100),
    );
    expect((await hre.f.gc.gmx.eth.balanceOf(hre.f.deployer.address)).sub(preBaseBal))
      .gt(toBN('2', DEFAULT_DECIMALS.ETH))
      .lt(toBN('2.1', DEFAULT_DECIMALS.ETH));
    expect(preQuoteBal.sub(await hre.f.gc.gmx.USDC.balanceOf(hre.f.deployer.address))).gt(
      toBN('2', DEFAULT_DECIMALS.USDC).mul(DEFAULT_BASE_PRICE).div(UNIT),
    );
  });

  it('exchanges from base', async () => {
    const preBaseBal = await hre.f.gc.gmx.eth.balanceOf(hre.f.deployer.address);
    const preQuoteBal = await hre.f.gc.gmx.USDC.balanceOf(hre.f.deployer.address);
    await expect(hre.f.gc.GMXAdapter.exchangeFromExactBase(hre.f.gc.optionMarket.address, toBN('1'))).revertedWith(
      'InsufficientSwap',
    );
    await hre.f.gc.GMXAdapter.setMarketPricingParams(hre.f.gc.optionMarket.address, {
      ...DEFAULT_GMX_ADAPTER_PARAMS,
      staticSwapFeeEstimate: toBN('1.05'),
    });
    await hre.f.gc.GMXAdapter.exchangeFromExactBase(hre.f.gc.optionMarket.address, toBN('1'));
    expect(preBaseBal.sub(await hre.f.gc.gmx.eth.balanceOf(hre.f.deployer.address))).eq(
      toBN('1', DEFAULT_DECIMALS.ETH),
    );
    expect((await hre.f.gc.gmx.USDC.balanceOf(hre.f.deployer.address)).sub(preQuoteBal))
      .lt(toBN('1742.01337', DEFAULT_DECIMALS.USDC))
      .gt(toBN('1742.01337', DEFAULT_DECIMALS.USDC).mul(100).div(103));
  });

  describe('reverts for various misc reasons', async () => {
    it('reverts when setting bad parameters', async () => {
      await expect(
        hre.f.gc.GMXAdapter.setMarketPricingParams(hre.f.gc.optionMarket.address, {
          ...DEFAULT_GMX_ADAPTER_PARAMS,
          staticSwapFeeEstimate: toBN('0.99'),
        }),
      ).revertedWith('InvalidMarketPricingParams');

      await expect(hre.f.gc.GMXAdapter.setRiskFreeRate(hre.f.gc.optionMarket.address, toBN('50').add(1))).revertedWith(
        'InvalidRiskFreeRate',
      );
      await expect(hre.f.gc.GMXAdapter.setRiskFreeRate(hre.f.gc.optionMarket.address, toBN('-50').sub(1))).revertedWith(
        'InvalidRiskFreeRate',
      );
    });
    it('reverts when insufficient returned from swap', async () => {
      await hre.f.gc.GMXAdapter.setMarketPricingParams(hre.f.gc.optionMarket.address, {
        ...DEFAULT_GMX_ADAPTER_PARAMS,
        staticSwapFeeEstimate: toBN('1'),
      });
      await expect(hre.f.gc.GMXAdapter.exchangeFromExactBase(hre.f.gc.optionMarket.address, toBN('1'))).revertedWith(
        'InsufficientSwap',
      );
      // Reverts because limit too low
      await expect(
        hre.f.gc.GMXAdapter.exchangeToExactBaseWithLimit(hre.f.gc.optionMarket.address, toBN('1'), toBN('1000')),
      ).revertedWith('InsufficientSwap');
    });

    it('Reverts when CL returns 0', async () => {
      await hre.f.gc.gmx.ethPriceFeed.setLatestAnswer(0, await currentTime());
      await expect(hre.f.gc.GMXAdapter.getSettlementPriceForMarket(hre.f.gc.optionMarket.address, 0)).revertedWith(
        'InvalidAnswer',
      );
    });

    it('Reverts when CL feed not set', async () => {
      const testMarket = await (await ethers.getContractFactory('OptionMarket')).deploy();
      await testMarket.init(
        ZERO_ADDRESS,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
      );
      await expect(hre.f.gc.GMXAdapter.getSettlementPriceForMarket(testMarket.address, 0)).revertedWith(
        'InvalidPriceFeedAddress',
      );
    });

    it('reverts for all non-implemented functions', async () => {
      await expect(hre.f.gc.GMXAdapter.exchangeFromExactQuote(hre.f.gc.optionMarket.address, toBN('1'))).revertedWith(
        'NotImplemented',
      );
      await expect(hre.f.gc.GMXAdapter.exchangeToExactQuote(hre.f.gc.optionMarket.address, toBN('1'))).revertedWith(
        'NotImplemented',
      );
      await expect(hre.f.gc.GMXAdapter.exchangeToExactBase(hre.f.gc.optionMarket.address, toBN('1'))).revertedWith(
        'NotImplemented',
      );
      await expect(
        hre.f.gc.GMXAdapter.exchangeToExactQuoteWithLimit(hre.f.gc.optionMarket.address, toBN('1'), toBN('10')),
      ).revertedWith('NotImplemented');
    });

    it('reverts for failed transfers', async () => {
      const tokenForceFailQuote = await (await ethers.getContractFactory('TestERC20Fail')).deploy('t', 't');
      const tokenForceFailBase = await (await ethers.getContractFactory('TestERC20Fail')).deploy('t', 't');
      const testMarket = await (await ethers.getContractFactory('OptionMarket')).deploy();
      await testMarket.init(
        ZERO_ADDRESS,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
        ZERO_ADDRESS,
        tokenForceFailQuote.address,
        tokenForceFailBase.address,
      );

      await hre.f.gc.GMXAdapter.setChainlinkFeed(tokenForceFailBase.address, hre.f.gc.gmx.ethPriceFeed.address);
      await (hre.f.gc.gmx.vault as any as TestGMXVaultChainlinkPrice).setFeed(
        tokenForceFailBase.address,
        hre.f.gc.gmx.ethPriceFeed.address,
      );
      await (hre.f.gc.gmx.vault as any as TestGMXVaultChainlinkPrice).setFeed(
        tokenForceFailQuote.address,
        hre.f.gc.gmx.usdcPriceFeed.address,
      );

      await tokenForceFailQuote.permitMint(hre.f.gc.gmx.vault.address, true);
      await tokenForceFailBase.permitMint(hre.f.gc.gmx.vault.address, true);

      await tokenForceFailBase.setForceFail(true);
      await tokenForceFailQuote.setForceFail(true);

      await hre.f.gc.GMXAdapter.setMarketPricingParams(testMarket.address, {
        ...DEFAULT_GMX_ADAPTER_PARAMS,
        staticSwapFeeEstimate: toBN('1.02'),
      });

      await hre.f.gc.GMXAdapter.setMarketPricingParams(testMarket.address, {
        ...DEFAULT_GMX_ADAPTER_PARAMS,
        staticSwapFeeEstimate: toBN('1.02'),
      });

      await expect(hre.f.gc.GMXAdapter.exchangeFromExactBase(testMarket.address, toBN('1'))).revertedWith(
        'AssetTransferFailed',
      );
      await expect(
        hre.f.gc.GMXAdapter.exchangeToExactBaseWithLimit(testMarket.address, toBN('1'), toBN('1000')),
      ).revertedWith('AssetTransferFailed');
    });

    it('Reverts if the spot variance CB is fired', async () => {
      await hre.f.gc.GMXAdapter.setMarketPricingParams(hre.f.gc.optionMarket.address, {
        ...DEFAULT_GMX_ADAPTER_PARAMS,
        priceVarianceCBPercent: toBN('0.01'),
        gmxUsageThreshold: toBN('0.01'),
      });

      const newFeed = await (await ethers.getContractFactory('MockAggregatorV2V3')).deploy();
      await newFeed.setDecimals(18);
      await hre.f.gc.GMXAdapter.setChainlinkFeed(hre.f.gc.gmx.eth.address, newFeed.address);
      const oldMax = (await hre.f.gc.gmx.vault.getMaxPrice(hre.f.gc.gmx.eth.address))
        .mul(UNIT)
        .div(BigNumber.from(10).pow(30));
      const min = (await hre.f.gc.gmx.vault.getMinPrice(hre.f.gc.gmx.eth.address))
        .mul(UNIT)
        .div(BigNumber.from(10).pow(30));
      await newFeed.setLatestAnswer(min, await currentTime());

      await expect(
        hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.MIN_PRICE),
      ).revertedWith('PriceVarianceTooHigh');
      await expect(
        hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.MAX_PRICE),
      ).revertedWith('PriceVarianceTooHigh');

      // Getting reference or force prices don't revert
      expect(await hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.REFERENCE)).eq(
        min,
      );
      expect(await hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.FORCE_MAX)).eq(
        oldMax,
      );
      expect(await hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.FORCE_MIN)).eq(
        min,
      );

      // Same for setting max price
      const newMax = (await hre.f.gc.gmx.vault.getMaxPrice(hre.f.gc.gmx.eth.address))
        .mul(UNIT)
        .div(BigNumber.from(10).pow(30));
      await newFeed.setLatestAnswer(newMax, await currentTime());

      await expect(
        hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.MIN_PRICE),
      ).revertedWith('PriceVarianceTooHigh');
      await expect(
        hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.MAX_PRICE),
      ).revertedWith('PriceVarianceTooHigh');
      // Getting reference doesn't revert
      expect(await hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.REFERENCE)).eq(
        newMax,
      );
      expect(await hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.FORCE_MAX)).eq(
        newMax,
      );
      expect(await hre.f.gc.GMXAdapter.getSpotPriceForMarket(hre.f.gc.optionMarket.address, PricingType.FORCE_MIN)).eq(
        min,
      );
    });
  });
});
describe('Successful Open v2', async () => {
  const collaterals = [toBN('0'), toBN('0'), toBN('1'), toBN('1500'), toBN('1500')];

  let DEFAULT_PARAM: {
    optionType: OptionType;
    strikeId: BigNumberish;
    amount: BigNumber;
    setCollateralTo?: BigNumber;
  };
  let oldUserQuoteBal: BigNumber;
  let oldUserBaseBal: BigNumber;
  let oldOMBalance: BigNumber;
  let om : any;
  let ga : any;

  beforeEach(async () => {
    await seedFixture();
    oldUserQuoteBal = await hre.f.c.snx.quoteAsset.balanceOf(hre.f.deployer.address);
    oldUserBaseBal = await hre.f.c.snx.baseAsset.balanceOf(hre.f.deployer.address);
    oldOMBalance = await hre.f.c.snx.quoteAsset.balanceOf(hre.f.c.optionMarket.address);

    await allCurrenciesFixtureGMX();
    await hre.f.gc.gmx.USDC.approve(hre.f.gc.GMXAdapter.address, MAX_UINT);
    await hre.f.gc.gmx.btc.approve(hre.f.gc.GMXAdapter.address, MAX_UINT);
    await hre.f.gc.gmx.eth.approve(hre.f.gc.GMXAdapter.address, MAX_UINT);

    await hre.f.gc.GMXAdapter.setMarketPricingParams(hre.f.gc.optionMarket.address, {
      ...DEFAULT_GMX_ADAPTER_PARAMS,
      staticSwapFeeEstimate: toBN('1.01'),
    });

    om = hre.f.gc.optionMarket;
    ga = await hre.f.gc.GMXAdapter;
  });

  async function op_1(_optionType: any, _amount: any) {
    await openPosition({
      optionType: _optionType,
      amount: _amount,
      setCollateralTo: collaterals[_optionType],
      iterations: 3,
    });
  }

  it('test1', async () => {
    await op_1(0, parseEther("1"));
    await op_1(1, parseEther("1"));
    await op_1(2, parseEther("1"));
    await op_1(3, parseEther("1"));
    await op_1(4, parseEther("1"));
  });
  it("test002", async() => {
    console.log(`${await om.getOptionMarketParams()}`);
    await op_1(0, parseEther("1"));
    console.log(`${await om.getOptionMarketParams()}`);
    expect(await ga.isGlobalPaused()).false;
  });
  it("test003 => baseExchangeAdapter", async() => {
    console.log(`${await ga.requireNotGlobalPaused(om.address)}`);
    console.log(`${await ga.requireNotMarketPaused(om.address)}`)
    console.log(`${formatEther(await ga.rateAndCarry(om.address))}`);
    console.log(`${formatEther(await ga.getSpotPriceForMarket(om.address, 0))}`);
    console.log(`${formatEther(await ga.getSettlementPriceForMarket(om.address,0))}`);
    console.log(`${formatEther(await ga.estimateExchangeToExactQuote(om.address, DEFAULT_BASE_PRICE))}`);
    console.log(`${formatEther(await ga.estimateExchangeToExactBase(om.address, parseEther('1.0')))}`);
  });
  it("test004 => GMXAdapter", async() => {
    expect(await ga.getSpotPriceForMarket(om.address,0)).eq(parseEther("1724.5932363"));
    expect(await ga.getSettlementPriceForMarket(om.address,0)).eq(parseEther("1742.01337"));
    expect(await ga.estimateExchangeToExactQuote(om.address, DEFAULT_BASE_PRICE)).gt(parseEther("1.03"));
    const _amount = parseEther("1.0");
    expect(await ga.estimateExchangeToExactBase(om.address, _amount)).gt(parseEther("1794"));
    expect(await ga.estimateExchangeToExactBase(om.address, _amount)).lt(parseEther("1795"));

    console.log(`${await ga.getAdapterState(om.address)}`);
  });
});
