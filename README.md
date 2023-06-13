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

## Contributing

Are you interested in helping us build the future of Reservoir?
Contribute in these ways:

- If you find bugs or code errors, you can open a new
[issue ticket here.](https://github.com/reservoir-labs/amm-core/issues/new)

- If you find an issue and would like to submit a fix for said issue, follow
these steps:
  - Start by forking the amm-core repository to your local environment.
  - Make the changes you find necessary to your local repository.
  - Submit your [pull request.](https://github.com/reservoir-labs/amm-core/compare)

- Have questions, or want to interact with the team and the community?
Join our [discord!](https://discord.com/invite/eAyk6eBU)
