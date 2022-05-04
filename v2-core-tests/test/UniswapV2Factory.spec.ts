import chai, { expect } from 'chai'
import { Contract } from 'ethers'
import {BigNumber, bigNumberify} from 'ethers/utils'
import { solidity, MockProvider, createFixtureLoader } from 'ethereum-waffle'

import { getCreate2Address } from './shared/utilities'
import { factoryFixture } from './shared/fixtures'

import UniswapV2Pair from '../../out/UniswapV2Pair.sol/UniswapV2Pair.json'
import { AddressZero } from "ethers/constants";

chai.use(solidity)

const TEST_ADDRESSES: [string, string] = [
  '0x1000000000000000000000000000000000000000',
  '0x2000000000000000000000000000000000000000'
]

describe('UniswapV2Factory', () => {
  const provider = new MockProvider({
    hardfork: 'istanbul',
    mnemonic: 'horn horn horn horn horn horn horn horn horn horn horn horn',
    gasLimit: 9999999
  })
  const [wallet, other] = provider.getWallets()
  const loadFixture = createFixtureLoader(provider, [wallet, other])

  let factory: Contract
  let expectedDefaultSwapFee: BigNumber
  let expectedDefaultPlatformFee: BigNumber
  let expectedPlatformFeeTo: string

  beforeEach(async () => {
    const fixture = await loadFixture(factoryFixture)
    factory = fixture.factory
    expectedDefaultSwapFee = fixture.defaultSwapFee
    expectedDefaultPlatformFee = fixture.defaultPlatformFee
    expectedPlatformFeeTo = fixture.platformFeeTo
  })

  it('platformFeeTo, defaultSwapFee, defaultPlatformFee, platformFeeTo, defaultRecoverer, allPairsLength', async () => {
    expect(await factory.defaultSwapFee()).to.eq(expectedDefaultSwapFee)
    expect(await factory.defaultPlatformFee()).to.eq(expectedDefaultPlatformFee)
    expect(await factory.platformFeeTo()).to.eq(expectedPlatformFeeTo)
    expect(await factory.defaultRecoverer()).to.eq(AddressZero)
    expect(await factory.allPairsLength()).to.eq(0)
  })

  async function createPair(tokens: [string, string]) {
    const bytecode = UniswapV2Pair.bytecode.object
    const create2Address = getCreate2Address(factory.address, tokens, bytecode)
    await expect(factory.createPair(...tokens, ))
      .to.emit(factory, 'PairCreated')
      .withArgs(
          TEST_ADDRESSES[0],
          TEST_ADDRESSES[1],
          create2Address,
          bigNumberify(1),
          expectedDefaultSwapFee,
          expectedDefaultPlatformFee
      )

    await expect(factory.createPair(...tokens)).to.be.reverted // UniswapV2: PAIR_EXISTS
    await expect(factory.createPair(...tokens.slice().reverse())).to.be.reverted // UniswapV2: PAIR_EXISTS
    expect(await factory.getPair(...tokens)).to.eq(create2Address)
    expect(await factory.getPair(...tokens.slice().reverse())).to.eq(create2Address)
    expect(await factory.allPairs(0)).to.eq(create2Address)
    expect(await factory.allPairsLength()).to.eq(1)

    const pair = new Contract(create2Address, JSON.stringify(UniswapV2Pair.abi), provider)
    expect(await pair.factory()).to.eq(factory.address)
    expect(await pair.token0()).to.eq(TEST_ADDRESSES[0])
    expect(await pair.token1()).to.eq(TEST_ADDRESSES[1])
  }

  it('retrievePairInitCode', async () => {
    // Retrieve the UniswapV2Pair init-code from the factory
    const initCode: BigNumber = await factory.getPairInitHash()

    // Expected init-code (hard coded value is used in dependent modules as a gas optimisation, so also verified here).
    // Note: changing the hard-coded expected init-code value implies you will need to also update the dependency.
    // See dependency @ v2-periphery/contracts/libraries/UniswapV2Library.sol
    // todo: update this comment once we have built out the router
    expect(initCode, 'UniswapV2Pair init-code').to.eq('0x532432c7a4aa1f8ce4121791e8a5937d0f66162b0eb19d7b134c8e5e1de69155')
  })

  it('createPair', async () => {
    await createPair(TEST_ADDRESSES)
  })

  it('createPair:reverse', async () => {
    await createPair(TEST_ADDRESSES.slice().reverse() as [string, string])
  })

  it('createPair:gas', async () => {
    const tx = await factory.createPair(...TEST_ADDRESSES)
    const receipt = await tx.wait()
    expect(receipt.gasUsed).to.eq(2327131)
  })

  it('setPlatformFeeTo', async () => {
    await expect(factory.connect(other).setPlatformFeeTo(other.address)).to.be.revertedWith('Ownable: caller is not the owner')
    await factory.setPlatformFeeTo(wallet.address)
    expect(await factory.platformFeeTo()).to.eq(wallet.address)
  })
})
