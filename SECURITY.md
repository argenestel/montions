# Security

Montions is **new, unaudited software**. Do not put funds in it that you cannot afford to lose.

## Reporting a vulnerability
Please report privately; do not open a public issue for security problems.
- Email: **security@\<set-before-launch\>** (placeholder — set a monitored address before any mainnet launch).
- Include: affected contract/function, a reproducible scenario (a Foundry test is ideal), and the impact you believe it has.
- We aim to acknowledge within 72 hours. Please give us reasonable time to fix before disclosure.
- A bounty programme (e.g. on Cantina/Immunefi) is **not yet live**; do not assume rewards. This will be announced before mainnet.

## Scope
In scope: everything under `src/` (orderbook, vault, quoter, oracle adapters, resolvers) and the deployment scripts under `script/`.
Out of scope: the Monad chain itself (report to Monad's Cantina program), Pyth, Circle/USDC, third-party wallets.

## What has been done so far (honest status)
- 200+ Foundry tests: unit, fuzz, and a 7-property invariant suite on the orderbook.
- Differential testing: an independent Python reference model replays 12 generated scenarios (thousands of operations) against the Solidity Book.
- Two independent AI-assisted security reviews of the spec and of the Book (Grok, Codex Luna); all high/medium findings were fixed or tracked in `docs/THREAT_MODEL.md`.
- **No professional human audit yet.** This is the main gate before real-money mainnet use. See `docs/LAUNCH_CHECKLIST.md`.
