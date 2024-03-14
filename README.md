# Reservoir AMM-core

## Setup

### Install global dependencies

This repo uses [foundry](https://github.com/foundry-rs/foundry)
as the main tool for compiling and testing smart contracts. You can install
foundry via:

```shell
curl -L https://foundry.paradigm.xyz | bash
```

For alternative installation options & more details [see the foundry repo](https://github.com/foundry-rs/foundry).

### Install project dependencies

```bash
git submodule update --init --recursive
nvm use
npm ci
npm run install
```

## Building

```bash
forge build
```

## Testing

To run unit tests:

```bash
forge test
```

To run integration tests:

```bash
npm run test:integration
```

To run differential fuzz tests:

```bash
npm run test:differential
```

To run legacy tests:

```bash
npm run test:uniswap
```

## Audits

You can find all audit reports under the audits folder.

V1.0

- [ABDK](./audits/ABDK_ReservoirFi_AMMCore_v_1_0.pdf)

## Production Parameters

- Assumptions when setting an appropriate max change rate: 
  - Oracle manipulation attempts will move prices more than the most violent organic runs
  - So what we need is some 
- Refer to this spreadsheet for detailed [calculations](https://docs.google.com/spreadsheets/d/1oAn8ghqK1MThrgOcHUl8nP_ATTpnlmMqnDtqBXxeHJs/edit#gid=0)

- `ReservoirPair::maxChangeRate`
  - BTC-ETH pair
    - Fixed at 0.0005e18 (5bp/s)
    - Implies that:
      - price can change 3% in 1 minute if swapped once per minute 
      - price can change 6.09% in 2 minute if swapped once per minute
      - Price can change 34.39% in 10 minutes if swapped once per minute
        - compared to 30% in 10 minutes if swapped only once per 10 minutes 
        - compared to 34.97% in 10 minutes if swapped once per second
      - In the most violent run
  - ETH-USDC pair
    - Fixed at 0.0005e18 (5bp/s)
  - Stable Pairs
    - Fixed at ...

- TWAP Period
  - BTC-ETH pair
    - 15 min
  - ETH-USDC pair
    - 15 min

- Max price change within one trade
  - team intuits it should be set somewhere between 1-3% 

## Contributing

Are you interested in helping us build the future of Reservoir?
Contribute in these ways:

- For SECURITY related or sensitive bugs, please get in touch with the team
at security@reservoir.fi or on discord instead of opening an issue on github.

- If you find bugs or code errors, you can open a new
[issue ticket here.](https://github.com/reservoir-labs/amm-core/issues/new)

- If you find an issue and would like to submit a fix for said issue, follow
these steps:
  - Start by forking the amm-core repository to your local environment.
  - Make the changes you find necessary to your local repository.
  - Submit your [pull request.](https://github.com/reservoir-labs/amm-core/compare)

- Have questions, or want to interact with the team and the community?
Join our [discord!](https://discord.gg/SZjwsPT7CB)
