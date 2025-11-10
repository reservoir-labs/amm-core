# Reservoir AMM Liquidity Provision Overview

Welcome to **Reservoir**, a next-generation DeFi liquidity layer
engineered for *maximum capital efficiency* and *robust,
manipulation-resistant pricing*. This brief outlines our
architecture and presents a targeted liquidity-seeding proposal.

## Problem Statement

1. Capital efficiency in AMMs is inadequate
   - Most of the capital in AMMs remains untouched for the
     majority of swaps.
   - Today only a small set of collaterals are usable on money
     markets.

2. Today most DeFi lending protocols depend on Chainlink
   - Single source of failure, centralized solution
   - Inefficient architecture as prices have to be pushed on chain
     from without
   - Absence of price feeds for tokens means it's impossible to
     create money markets for those tokens

---

## Solution Overview

### 1. Automated Market Maker (AMM)

Reservoir combines two battle-tested curve designs inside a
single, modular pool contract:

| Curve                            | Best for                  | Key Benefit                        |
|-----------------------------------|---------------------------|-------------------------------------|
| **Constant Product** (x * y = k)  | Uncorrelated/volatile     | Deep liquidity & reliable price     |
|                                   | pairs                     | discovery across the full range     |
| **Stable**                        | Correlated assets         | Ultra-low slippage within tight     |
|                                   | (stables, LSTs, FX)       | bands, boosting capital efficiency. |
|                                   |                           | Configurable amplification coeff.   |

Liquidity providers select the curve that matches the asset
profile, ensuring each pool remains optimised.

---

### 2. Asset Manager

Idle liquidity shouldn’t sit still. Our **Asset Manager**
contracts plug directly into Euler V2 money markets to unlock
additional yield:

- **Yield on Idle Reserves** – Surplus tokens are supplied to
  Euler markets, earning passive interest in real-time
- **Automatic Rebalancing** – Every deposit or withdrawal
  rebalances the on-hand vs. farmed allocation to match current
  utilisation
- **Instant Recall** – Large swaps trigger same-tx withdrawals
  from Euler, guaranteeing liquidity is always available for
  traders + LPs

Result: LPs capture **swap fees + money-market yield**—
compounding their effective APR.

---

### 3. Native Oracle

Each Reservoir pool is its own price oracle, eliminating
reliance on centralized feeds:

- **Manipulation-Resistant** – Configurable max change per unit
  time & windowed TWAPs (15-min by default) defend against
  short-term attacks
- **Incentivised Upkeep** – MEV searchers earn rewards for
  pushing updates when price moves beyond configurable
  thresholds, keeping data fresh without a privileged keeper
- **Plug-and-Play** – Any protocol can query the on-chain oracle
  directly—perfect for lending, derivatives, or collateral
  management

---

### 4. Liquidity-Seeding Proposal

To bootstrap healthy markets & oracle feeds, we propose seeding
these potential pairs:

| Pair                     | Curve           | Why It Matters                  |
|--------------------------|-----------------|---------------------------------|
| **EURC / USDC**          | Stable          | Establishes a euro-pegged FX    |
|                          |                 | pair; forms the reference       |
|                          |                 | oracle for money markets        |
| **EURC / BTC.b**         | Constant Product| Enables euro-denominated BTC    |
|                          |                 | exposure; diversifies liquidity |
|                          |                 | corridors                       |
| **EURC / X** (long-tail  | Depends         | Expands oracle coverage &       |
| tokens on Avalanche/     |                 | supports ecosystem growth       |
| Arbitrum)                |                 |                                 |

**Earnings = Swapfees + Euler Supply APY** (auto-compounded)

#### Requested Capital

- **$100-200K** per pair for sufficient liquidity to power the
  oracle and kickstart the money market
- This solution is feasible on any EVM chain with EulerV2
  deployed (ETH mainnet, Arbitrum, Avalanche, Berachain etc. No
  plans for Plume network yet)

---

### 5. Why Provide Liquidity?

1. **Capital Efficiency** – Earn both trading fees and
   money-market yield
2. **Expand utility of EURC** – There aren't many money markets
   where EURC is available to be borrowed/lent. Seeding liq in
   the AMM instantly creates these new markets on EulerV2
3. **Security** – Contracts audited by ABDK and Cantina (see
   `/audits`)

---

### 6. Next Steps

Contact the team on
[discord](https://discord.com/invite/s4HyBKtDMx), or set up a
telegram group with contacts.
