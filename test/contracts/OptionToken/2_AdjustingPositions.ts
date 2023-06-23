import { OptionType, PositionState, toBN, ZERO_ADDRESS } from '../../../scripts/util/web3utils';
import { PositionWithOwnerStruct } from '../../../typechain-types/OptionToken';
import { ALL_TYPES, closePosition, CLOSE_FUNCTIONS, DEFAULT_OPTIONS, openPosition } from '../../utils/contractHelpers';
import { allTradesFixture } from '../../utils/fixture';
import { expect, hre } from '../../utils/testSetup';

describe('OptionToken - AdjustingPositions', async () => {
  beforeEach(allTradesFixture);
  it('gets all positions as expected', async () => {
    expect(await hre.f.c.optionToken.balanceOf(hre.f.deployer.address)).eq(5);
    let position: PositionWithOwnerStruct;

    for (const optionType of ALL_TYPES) {
      position = await hre.f.c.optionToken.getPositionWithOwner(hre.f.positionIds[optionType]);

      expect(position.owner).eq(hre.f.deployer.address);
      expect(position.strikeId).eq(hre.f.strike.strikeId);
      expect(position.optionType).eq(optionType);
      expect(position.amount).eq(DEFAULT_OPTIONS[optionType].amount);
      expect(position.state).eq(PositionState.ACTIVE);
      expect(position.collateral).to.eq((DEFAULT_OPTIONS[optionType] as any).setCollateralTo || 0);
    }
  });
  it('can assign closed status when closed', async () => {
    for (const optionType of ALL_TYPES) {
      await CLOSE_FUNCTIONS[optionType](hre.f.positionIds[optionType]);
      const position = await hre.f.c.optionToken.getOptionPosition(hre.f.positionIds[optionType]);
      expect(position.collateral).eq(0);
      expect(position.amount).eq(0);
      expect(position.state).eq(PositionState.CLOSED);
      expect(await hre.f.c.optionToken.canLiquidate(position, 0, 0, 0)).to.be.false;
    }
    expect((await hre.f.c.optionToken.getOwnerPositions(hre.f.deployer.address)).length).eq(0);
  });
});
