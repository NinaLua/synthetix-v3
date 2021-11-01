const { deepEqual } = require('assert/strict');
const { getAllContractASTs } = require('../../utils/hardhat');

describe('utils/hardhat.js', () => {
  it('should get artifacts ASTs', async () => {
    const qualifiedNames = [
      'contracts/modules/OwnerModule.sol:OwnerModule',
      'contracts/modules/SomeModule.sol:SomeModule',
    ];

    const output = {
      sources: {
        'contracts/modules/OwnerModule.sol': {
          OwnerModule: {
            ast: { some: 'ast' },
          },
        },
        'contracts/modules/SomeModule.sol': {
          SomeModule: {
            ast: { another: 'ast' },
          },
        },
      },
    };

    const hreMock = {
      artifacts: {
        getAllFullyQualifiedNames: async () => qualifiedNames,
        getBuildInfo: async () => ({ output }),
      },
    };

    const result = await getAllContractASTs(hreMock);

    deepEqual(result, {
      OwnerModule: { some: 'ast' },
      SomeModule: { another: 'ast' },
    });
  });
});
