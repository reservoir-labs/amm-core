# Vexchange v3-core

## Setup

This repo uses [foundry](https://github.com/foundry-rs/foundry)
as the main tool for compiling and testing smart contracts.

To install dependencies:

```shell
git submodule update --init --recursive
nvm use
npm install
npm run install 
```

## Building

```shell

forge build

```

## Testing

To run unit tests:

```shell
forge test
```

To run integration tests:

```shell
npm run test:integration
```

To run legacy tests:

```shell
npm run test:uniswap
```

## Contributing

Are you interested in helping us build the future of Vexchange with our V3?
Contribute in these ways:

- If you find bugs or code errors, you can open a new
[issue ticket here.](https://https://github.com/vexchange/v3-core/issues/new)

- If you find an issue and would like to submit a fix for said issue, follow
these steps:
  - Start by forking the V3-Core repository to your local environment.
  - Make the changes you find necessary to your local repository.
  - Submit your [pull request.](https://github.com/vexchange/v3-core/compare)

- Have questions, or want to interact with the team and the community?
Join our [discord!](https://discord.gg/vexchange)
