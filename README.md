# Montions

**Outcome-first binary options on Monad, with a fully onchain central limit order book.**

> *"I want to make $1,000 if MON ends above $1.05 by Friday."*

You say what you want to happen. The app finds the market, quotes the price, and you trade against a real onchain order book. Everything that touches money is a contract: the orderbook and matching, the collateral, price oracle, fair-value model, a market-making vault, and the read views the UI uses. There is **no backend, no indexer, no off-chain matcher and no signed price feed**. The frontend is a static page that reads the chain over RPC.

Built for the **Monad Metropolis hackathon — Finance & Trading track.**

## Why

Options are the right product sold through the wrong interface on the wrong venue. People already trade bounded-loss, asymmetric bets (prediction markets) and unbounded ones (perps); an option is what they want, but strike chains and greeks were built for market makers. The binary is the atom: price is the probability, max loss is the premium. Matching belongs onchain and Monad makes a CLOB in a contract practical: 100% collateral, so no margin engine, no liquidation, no clearing house. Settlement comes first: Pyth's first print at expiry, nobody picks the timestamp. Liquidity, not UX, is the honest bottleneck, so markets are quoted by a model-priced maker and stay open for weeks to months. Full argument and counter-arguments: **[docs/THESIS.md](docs/THESIS.md)**.

## How it works

- A **market** is a yes/no question settled by a resolver contract, e.g. *"MON ≥ $1.05 at 12:00 UTC?"*.
- One **contract** pays **$1 USDC** if its outcome is true and $0 otherwise. YES at 14¢ pays $1 → you win 86¢ per contract if right. NO costs 100¢ − YES price.
- Prices are integer **ticks (1–99¢)** in a price-time-priority **CLOB**; matching, escrow and settlement are atomic in `MontionsBook`. Every contract is **100% collateralised**: YES + NO = 1 USDC locked.
- **Settlement** is deterministic and permissionless:
  - *Mainnet:* Pyth's signed **first price at or after expiry** (`parsePriceFeedUpdatesUnique`) — nobody can pick a favourable timestamp. If no valid price arrives, the market **voids 50/50**.
  - *Testnet/demo:* a 60-second TWAP from onchain demo pools (clearly labelled MOCK; manipulable at low liquidity).
- A **MakerVault** (ERC-4626-style) posts quotes around a fair value computed *in Solidity* (digital-option `N(d2)` with realised/configured volatility) so books are never empty. Its risk is capped and stated plainly.

## Architecture (all onchain)

Full reference — contracts, units, trade lifecycle, settlement, safety controls, testnet addresses and how to verify them: **[docs/ONCHAIN.md](docs/ONCHAIN.md)**.

| Contract | Role |
|---|---|
| `MontionsBook` | Series registry, CLOB (tick bitmaps, FIFO queues), escrow, split/merge, resolution, ERC-1155 YES/NO tokens, views for the UI |
| `PythSettlementResolver` / `PythOracle` | Mainnet settlement and price adapter over Pyth |
| `TwapThresholdResolver` / `OracleHub` / `SpotPool` | Demo/testnet TWAP oracle over onchain pools |
| `TimelockOpResolver` | Event markets, e.g. "did this governance operation execute?" |
| `Quoter` / `PricingLib` | Fair value, book-walking quotes, one-call snapshots for the UI |
| `MakerVault` | Onchain market maker with exposure caps |

Safety controls: owner can **pause new risk only** (exits always work), set **launch caps**, and hand ownership to a Safe in two steps. The owner can **never** move user funds or change an outcome. See `docs/THREAT_MODEL.md`.

## Quick start (local)

```bash
scripts/dev-up.sh                 # anvil + contracts + 108 seeded markets + vault liquidity + price bot  (~3 min)
cd app && pnpm install && pnpm dev   # http://127.0.0.1:5175 — built-in dev wallet, faucet included
scripts/dev-down.sh
```

Tests: `forge test` (245 tests incl. fuzz, invariants, and differential replay against an independent Python model) · `pnpm --dir sdk test` · `pnpm --dir bots test`.

## Deploy

- **Testnet** (demo oracle): fund the throwaway deployer, then `scripts/testnet-deploy.sh` — see `docs/DEPLOY.md`.
- **Mainnet**: `docs/MAINNET.md` and `docs/LAUNCH_CHECKLIST.md`. **Not launched.**

## Honest status

- **Mainnet is NOT live and is not ready for real funds.** Open gates: a professional audit, legal review, a Safe-owned deployment, a testnet soak, and live Pyth settlement verification (Pyth's Hermes now requires an API key).
- What *has* been done: two independent AI security reviews, a 7-property invariant suite, differential testing against a second implementation, and a rehearsal on a **local fork of Monad mainnet** using real USDC and the real Pyth contract (deploy guards, handover, trading, 50/50 void path). No transaction has been sent to a live mainnet.
- USDC is issuer-controlled: Circle can freeze an address, including the Book.
- Binary options may be restricted in your jurisdiction. Nothing here is financial or legal advice.

## Repo map

`src/` contracts · `test/` Foundry tests (`test/diff` = differential replay) · `tools/refmodel` independent Python model · `script/` deploy & seed · `scripts/` ops (dev env, fork rehearsal, verifier) · `bots/` keeper + demo price bot · `sdk/` TypeScript SDK · `app/` frontend · `docs/` spec, threat model, runbooks.

License: MIT.
