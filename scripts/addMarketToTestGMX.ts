import chalk from 'chalk';
import { addGMXMarket } from './deploy/deployGMXContracts';
import { DeploymentType, getSelectedNetwork } from './util';
import { loadEnv, loadParams } from './util/parseFiles';
import { getDeployer } from './util/providers';

async function main() {
  const network = getSelectedNetwork();
  const envVars = loadEnv(network);
  const deployer = await getDeployer(envVars);
  const deploymentParams = { network, deployer, deploymentType: DeploymentType.MockGmxMockPricing };
  const params = loadParams(deploymentParams);

  const marketTicker = 'BTC';
  const marketId = 1;

  console.log(`Adding market ${marketTicker} on ${network}`);
  await addGMXMarket(deploymentParams, params, marketTicker, marketId);

  console.log(chalk.greenBright('\n=== Successfully deployed! ===\n'));
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
