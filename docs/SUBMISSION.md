# Montions — Monad Metropolis submission

Track: **Finance & Trading** · Repo: https://github.com/argenestel/montions · Live app: https://montions.vercel.app · Thesis: `docs/THESIS.md`

## One-liner

Outcome-first binary options on Monad with a **fully onchain central limit order book** — say *"I want to make $1,000 if MON ends above $0.0242 by Friday"*, and trade it against a real onchain book. Every component that touches money is a contract: matching, escrow, oracle adapter, fair-value model, market-making vault and the read views. No backend, no indexer, no off-chain matcher.

## What is built

- **MontionsBook** — price-time-priority CLOB (ticks 1–99¢, bitmap + FIFO), 100%-collateralised YES/NO ERC-1155 positions, split/merge, permissionless settlement, void 50/50 if no valid oracle price arrives within 2 days.
- **Pyth settlement** — `parsePriceFeedUpdatesUnique`: the *first* Pyth price at or after expiry, so nobody can pick a favourable timestamp. 34 verified Pyth feeds on Monad (majors, alts, wrapped/staked assets) each with tiered strike ladders.
- **MakerVault** (ERC-4626-style) quoting around an onchain digital-option fair value (`N(d2)`), so books are never empty; exposure capped.
- **Safety** — owner can pause *new risk only* (exits always work), launch caps, two-step ownership; the owner can never move user funds or change an outcome. See `docs/THREAT_MODEL.md`, `SECURITY.md`.
- **Frontend** — static React app, no server; reads chain via RPC with fallback endpoints. Mobile-first, installable PWA.

## Sponsor / bounty integrations

| Partner | How it is used |
|---|---|
| **Pyth** | Settlement oracle for all 34 markets (pull oracle, first price in `[expiry, expiry+300s]`). |
| **Mera** (Category Labs) | **Passkey sign-in**: WebAuthn PRF → deterministic BIP-44 key → ordinary EOA. No extension, no seed phrase; the same passkey always re-derives the same address. Verified end-to-end in headless Chromium with a virtual PRF authenticator. |
| **AUSD** (Agora; the Agora mobile bounty needs Perpl trades, so it is not claimed) | Supported as an alternative collateral: `COLLATERAL=AUSD scripts/mainnet-deploy.sh`. The SDK reads the token's ERC-5267 domain (`"Agora Dollar"`, v1) and verifies it against `DOMAIN_SEPARATOR()` before signing a permit. USDC (Circle, domain v2) is the default. |

## Verification

- Foundry: 245 tests (unit, fuzz, invariants); Python model ⇄ Solidity differential tests for pricing.
- SDK 36 tests, bots 34 tests.
- Mainnet-fork rehearsal of the production deploy (all 34 feeds): 112 checks PASS.
- Passkey account creation, deterministic re-sign-in and a real-USDC trade verified on a Monad-mainnet fork.

## Honest limitations

- **Unaudited.** No third-party audit, legal review or multisig yet; mainnet launch is capped (`COLLATERAL_CAP_USDC`, `SERIES_POOL_CAP_USDC`, `VAULT_CAP_USDC`) and deploys paused.
- Live Pyth settlement needs a Hermes API key for the keeper (`.dev/hermes.key`); without it settlement falls back to the 50/50 void path after the grace period.
- Passkey PRF works with iCloud Keychain, 1Password and Google Password Manager; some browsers/authenticators do not support it (the app falls back to injected wallets).
- Testnet markets use a clearly-labelled demo TWAP oracle, not Pyth.

## Demo script (≤ 3 min)

1. (0:00) Open the app on a phone-sized window. *"Outcome first — you describe what you want to happen."*
2. (0:20) **Create a passkey account** — Face/Touch ID, no extension. Show the address; sign out and sign in again → same address.
3. (0:50) Pick an asset from the 34-asset picker; set payout $1,000, "ends above", strike, expiry. Show the price and the payoff chart.
4. (1:20) Confirm: show slippage, re-quote, "Collateral 100% — pays $1,000 from locked USDC/AUSD". Fill onchain; open the tx in the explorer.
5. (1:50) Positions tab: the YES tokens. Open `docs/ONCHAIN.md` for every contract address and "no backend".
6. (2:20) Vault tab: market-maker vault caps and exposure. Mention pause-new-risk-only and caps.
7. (2:40) Close: Pyth first-price settlement; void-50/50 safety; open source.

## Pitch (≤ 2 min)

Options are the right product, sold through the wrong interface, on the wrong venue. Retail already trades bounded-loss bets on Polymarket and unbounded ones on perps; an option is what they actually want, but strike chains and greeks were built for market makers. Montions makes the interface a sentence: "I want to make $1,000 if MON is above $X by Friday." Price is the probability, max loss is the premium you see before you click.

The binary is the atom of options, and it is the one product that can live fully onchain: 100% collateralised, so no margin engine, no liquidation, no clearing house, no socialised loss. Monad's gas makes a real central limit order book inside a contract practical, with matching and settlement atomic in one transaction. Settlement is Pyth's first signed print at or after expiry, so nobody picks the timestamp; if no print arrives the market voids 50/50.

Liquidity, not UX, is the honest bottleneck. A model-priced maker rests two-sided quotes on every market, a vault does the same with pooled capital, anyone can list a market for any registered asset, and ladders run weekly, monthly and quarterly so markets stay open long enough to attract flow. The same contract and the same sentence work for stocks, FX and rates the moment a feed exists.

Passkey login via Mera means a first-time user trades with a fingerprint. Collateral is USDC or AUSD. Open source, mobile-first, capped, and honest about being unaudited.

## Judge access

- Open the live app; **Create a passkey account** (needs HTTPS on a real domain and a PRF-capable passkey manager) or connect any injected wallet.
- Testnet needs testnet MON for gas (faucet) — the app shows a hint when gas is low.
- Source and runbooks: `README.md`, `docs/MAINNET.md`, `docs/LAUNCH_CHECKLIST.md`.
