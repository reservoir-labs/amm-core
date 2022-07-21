# Vexchange v3-core

## Setup

This repo uses [foundry](https://github.com/foundry-rs/foundry)
as the main tool for compiling and testing smart contracts.

## Compiling

```shell
forge build
```

## Testing

```shell
forge test
```

Asset manager tests forks the ETH mainnet and uses Compound's contracts for 
integration testing.
To fork the mainnet and run the tests:

```shell
forge test -vvv --fork-url https://cloudflare-eth.com --block-number 15165804 
```
