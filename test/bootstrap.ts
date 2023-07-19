import { wei } from '@synthetixio/wei';
import { coreBootstrap } from '@synthetixio/router/dist/utils/tests';
import { snapshotCheckpoint } from '@synthetixio/core-utils/utils/mocha/snapshot';
import { createStakedPool } from '@synthetixio/main/test/common';
import {
  PerpMarketProxy,
  AccountProxy,
  SnxCollateralMock,
  SynthetixUsdCollateralMock,
  WrappedStakedEthCollateralMock,
  PythMock,
  AggregatorV3Mock,
} from './generated/typechain';
import type { IMarketConfigurationModule } from './generated/typechain/MarketConfigurationModule';
import { BigNumber, utils } from 'ethers';
import { createOracleNode } from '@synthetixio/oracle-manager/test/common';
import { CollateralMock } from '../typechain-types';
import { bn } from './generators';

interface Systems extends ReturnType<Parameters<typeof createStakedPool>[0]['systems']> {
  PerpMarketProxy: PerpMarketProxy;
  AggregatorV3Mock: AggregatorV3Mock;
  PythMock: PythMock;
  CollateralMock: CollateralMock;
  Collateral2Mock: CollateralMock;
  Collateral3Mock: CollateralMock;
}

// Hardcoded definition relative to provisioned contracts defined in the toml.
//
// This type is used in `getContract` for mostly autocomplete. Notice there is zero guarantee runtime
// `getContract` calls would be correct. This interface is more likely to just be a subset of provisioned
// contracts in cannon toml.
interface Contracts {
  ['synthetix.CoreProxy']: Systems['Core'];
  ['synthetix.USDProxy']: Systems['USD'];
  ['synthetix.oracle_manager.Proxy']: Systems['OracleManager'];
  SnxCollateralMock: SnxCollateralMock;
  SynthetixUsdCollateralMock: SynthetixUsdCollateralMock;
  WrappedStakedEthCollateralMock: WrappedStakedEthCollateralMock;
  PerpMarketProxy: PerpMarketProxy;
  AccountProxy: AccountProxy;
  PythMock: PythMock;
  AggregatorV3Mock: AggregatorV3Mock;
}

// A set of intertwined operations occur on `coreBootstrap` invocation. Generally speaking, it:
//
// - Builds contracts using cannon using topology defined by the specified `cannonfile.toml`.
// - Generates TypeScript interfaces via typechain.
// - Using `cannon:build` builds and deploys contracts into a local Anvil runtime.
// - Returns a collection of utility methods contextualised by metadata from cannon for testing.
//
// @see: https://github.com/Synthetixio/synthetix-router/blob/master/src/utils/tests.ts#L23
// @see: https://github.com/usecannon/cannon/blob/main/packages/hardhat-cannon/src/tasks/build.ts
// @see: https://github.com/foundry-rs/foundry/commit/b02dcd26ff2aabc305cee61cd2fa3f7c3a85aad2
const _bootstraped = coreBootstrap<Contracts>({ cannonfile: 'cannonfile.toml' });
const restoreSnapshot = _bootstraped.createSnapshot();

export interface BootstrapArgs {
  pool: {
    initialCollateralPrice: BigNumber;
  };
  global: IMarketConfigurationModule.ConfigureParametersStruct;
  markets: {
    name: string;
    initialPrice: BigNumber;
    specific: IMarketConfigurationModule.ConfigureByMarketParametersStruct;
  }[];
}

export const bootstrap = (args: BootstrapArgs) => {
  const { getContract, getSigners, getProvider } = _bootstraped;

  before(restoreSnapshot);

  let systems: Systems;
  before('load contracts', () => {
    systems = {
      Account: getContract('AccountProxy'),
      PerpMarketProxy: getContract('PerpMarketProxy'),
      Core: getContract('synthetix.CoreProxy'),
      USD: getContract('synthetix.USDProxy'),
      OracleManager: getContract('synthetix.oracle_manager.Proxy'),
      AggregatorV3Mock: getContract('AggregatorV3Mock'),
      PythMock: getContract('PythMock'),
      // Difference between this and `Collateral{2}Mock`?
      //
      // `Collateral{2}Mock` is defined by a `cannon.test.toml` which isn't available here. Both mocks below
      // follow the same ERC20 standard, simply named differently.
      //
      // `CollateralMock` is collateral deposited/delegated configured `args.markets`.
      CollateralMock: getContract('SnxCollateralMock'),
      Collateral2Mock: getContract('WrappedStakedEthCollateralMock'),
      Collateral3Mock: getContract('SynthetixUsdCollateralMock'),
    };
  });

  const getOwner = () => getSigners()[0];
  const core = {
    provider: () => getProvider(),
    signers: () => getSigners(),
    owner: () => getOwner(),
    traders: () => getSigners().slice(1),
    systems: () => systems,
  };

  // Create a pool which makes `args.markets.length` with all equal weighting.
  const stakedPool = createStakedPool(core, args.pool.initialCollateralPrice);

  let hasConfiguredGlobally = false;
  const markets = args.markets.map(({ name, initialPrice, specific }) => {
    const readableName = utils.parseBytes32String(name);
    let oracleNodeId: string, aggregator: AggregatorV3Mock, marketId: BigNumber;

    before(`provision price oracle nodes - ${readableName}`, async () => {
      const { oracleNodeId: nodeId, aggregator: agg } = await createOracleNode(
        getOwner(),
        initialPrice,
        systems.OracleManager
      );
      oracleNodeId = nodeId;
      aggregator = agg as AggregatorV3Mock;
    });

    before(`provision market - ${readableName}`, async () => {
      marketId = await systems.PerpMarketProxy.callStatic.createMarket({ name });
      await systems.PerpMarketProxy.createMarket({ name });
    });

    before(`delegate pool collateral to market - ${name}`, async () => {
      await systems.Core.connect(getOwner()).setPoolConfiguration(stakedPool.poolId, [
        {
          marketId,
          weightD18: utils.parseEther('1'),
          maxDebtShareValueD18: utils.parseEther('1'),
        },
      ]);
    });

    before('configure global market', async () => {
      if (!hasConfiguredGlobally) {
        await systems.PerpMarketProxy.connect(getOwner()).setMarketConfiguration(args.global);
      }
    });

    before(`configure market - ${readableName}`, async () => {
      await systems.PerpMarketProxy.connect(getOwner()).setMarketConfigurationById(marketId, specific);
    });

    return {
      oracleNodeId: () => oracleNodeId,
      aggregator: () => aggregator,
      marketId: () => marketId,
    };
  });

  const configureMarketCollateral = async () => {
    const collaterals = [
      { address: systems.Collateral2Mock.address, initialPrice: bn(1), max: bn(999_999) },
      { address: systems.Collateral3Mock.address, initialPrice: bn(1000), max: bn(100_000) },
    ];
    const collateralTypes = collaterals.map(({ address }) => address);

    let collateralOracles: Awaited<ReturnType<typeof createOracleNode>>[] = [];
    for (const { initialPrice } of collaterals) {
      collateralOracles.push(await createOracleNode(getOwner(), initialPrice, systems.OracleManager));
    }

    const oracleNodeIds = collateralOracles.map(({ oracleNodeId }) => oracleNodeId);
    const maxAllowables = collaterals.map(({ max }) => max);

    await systems.PerpMarketProxy.setCollateralConfiguration(collateralTypes, oracleNodeIds, maxAllowables);

    return collaterals.map((collateral, idx) => ({
      ...collateral,
      oracleNodeId: () => oracleNodeIds[idx],
      aggregator: () => collateralOracles[idx].aggregator,
    }));
  };
  let marketCollaterals: Awaited<ReturnType<typeof configureMarketCollateral>>;

  before('configure market collaterals', async () => {
    marketCollaterals = await configureMarketCollateral();
  });

  const restore = snapshotCheckpoint(core.provider);

  return {
    ...core,
    restore,
    markets: () => markets,
    marketCollaterals: () => marketCollaterals,
    pool: () => ({
      id: stakedPool.poolId,
      stakerAccountId: stakedPool.accountId,
      stakedAmount: stakedPool.depositAmount,
      collateral: stakedPool.collateralContract,
      oracleNodeId: stakedPool.oracleNodeId,
      aggregator: stakedPool.aggregator,
    }),
  };
};
