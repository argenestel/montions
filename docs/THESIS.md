# Thesis

**Options are the right product, sold through the wrong interface, on the wrong venue.**

1. **Demand is already here, mispackaged.** Retail trades two things at scale: perps (asymmetric upside, unbounded loss) and prediction markets (yes/no, price = probability). An option is what they actually want, bounded loss with an asymmetric payoff, but the interface (strike chains, implied vol, greeks) was built for market makers. Hunch's October 2026 demo reached ~150k views by changing nothing but the sentence.
2. **The binary is the atom.** "MON above $X by Friday" is the simplest option: the price is the probability, the maximum loss is the premium, the payout is fixed. A vanilla call is a stack of binaries across strikes, so spreads and vanillas can be composed later from the same book. Polymarket already taught a hundred million people to read a price as a probability.
3. **Matching belongs onchain, and only now can be.** Options liquidity lives on Deribit, Paradigm RFQ and Telegram because an orderbook was too expensive onchain and AMMs price convexity badly, so DeFi options became vaults selling to a few desks. Monad's gas makes a central limit order book inside a contract practical. With 100% collateral there is no margin engine, no liquidation, no clearing house and no socialised loss; matching and settlement are atomic in one contract. That is a product advantage, not ideology.
4. **Settlement is the whole game.** Binaries are most manipulable right at the strike at expiry, so the oracle rule comes before anything else: Pyth's first signed print at or after expiry, nobody chooses the timestamp, void 50/50 if no valid print arrives within the grace period.
5. **Liquidity is the honest bottleneck,** not UX. The answer is a model-priced maker that rests two-sided quotes on the book, a vault that does the same with pooled capital, permissionless market creation for any registered asset, and long-dated ladders (weekly, monthly, quarterly) so markets stay open long enough to attract flow. Thin books at 1–99¢ are survivable because every participant's loss is bounded.
6. **It generalises past crypto.** The same contract and the same sentence work for stocks, FX and rates the moment a price feed exists. The interface never changes; only the asset list grows.

**Counter-arguments taken seriously**

- Regulators file binaries next to prediction markets; venue and product type matter, and the launch is capped and paused by default.
- Market-making returns on binaries are thin and informed flow picks off a lagging model; the maker caps exposure per market and stops quoting near expiry.
- Oracle lag at expiry is a real attack surface; first-print settlement and the void path are the mitigation, not a cure.

**What Montions is betting on:** that the first options product most people use will be a sentence, settled onchain, with a loss they can see before they click.

---

# Appendix: market research notes (Oct 2026)

> Compiled by Grok (xai/grok-4.6, xhigh) on 2026-10-10. X search was blocked for it, so tweet quotes, view counts and dates are **unverified**. Product/blog pages below were spot-checked and exist: hunch.cool, derive.xyz blog posts, dreamos.app.

### 1. Core thesis (what people are actually saying)

The live conversation is **UX, not greeks**. On **6 Oct 2026**, [@rightclcksaveas](https://x.com/rightclcksaveas) (louis, cy; listed on his site as [Hunch](https://hunch.cool/)) posted *“where are the crypto options traders hiding???”* ([tweet](https://x.com/rightclcksaveas/status/2107450084153602261), ~140k views), then the demo: *“idk? stop hiding? think this is a pretty good way to make options feel simple? wdyt?”* ([tweet](https://x.com/rightclcksaveas/status/2107553330033836274), **~153k views, 2.5k likes, 1.8k bookmarks, 232 replies**). The frame is a sentence: **“I want to make $1,100 if HYPE hits $111 by Nov 27”** — cost $505, “20% chance,” Buy. Site copy: *“Say what you think will happen in a sentence.”*

[@jonwu_](https://x.com/jonwu_/status/2107627717000843581) (7 Oct): *“never ceases to amaze me how much ux can be improved if someone smart just thinks harder about it.”*

The “hiding” punchline is **venue, not demand**. [@jdasad77](https://x.com/jdasad77/status/2107454914272399779) (6 Oct): traders are on **Deribit depth, Paradigm RFQ, OKX/Bybit, Telegram** (directional, vol arb, selling premium, MM). [@0mllwntrmt3](https://x.com/0mllwntrmt3/status/2106756152902234219) (4 Oct) plugs an “Opshnz cartel” of **Derive, Paradex, Paradigm, Wintermute, Rysk**.

**Perps → defined-risk** is the house thesis, not the viral clip. Derive (29 Aug 2026): *“Most professional traders who are moving from perpetuals toward options are doing so because they want more precise hedging, defined risk, and capital efficiency”* ([post](https://www.derive.xyz/blog/what-is-an-onchain-crypto-options-protocol/)). Same week they argue **Deribit’s 2025 US-party acquisition** pushed Asian desks off CEX custody ([post](https://www.derive.xyz/blog/how-do-decentralized-crypto-options-work/)).

**Prediction-market crossover / 0DTE / “options are propping up”:** I did **not** find those phrases in this thread. Structurally, Hunch’s sentence is a **digital / binary payoff**; Polymarket already trained retail on YES/NO. Treat that as analogy, not a sourced 2026 tweet.

### 2. Projects in that discourse vs a fully onchain binary CLOB

| Name | What it is | vs Montions |
|---|---|---|
| **Hunch** | Sentence UX over **Derive listed options + Rysk “earn”** (HyperEVM). Call spreads, not a native book. | Same sentence. Different machine: offchain matcher / listed vanillas. |
| **Dream** ([@dreaming](https://x.com/dreaming), [dreamos.app](https://dreamos.app)) | Mobile *“fastest way to trade options.”* Tagged on the clip; [@domdosu](https://x.com/domdosu/status/2108608112345100455) (9 Oct, ~34k views): *“Should we drop this?”* | App/UX race, not an onchain binary CLOB. |
| **Clutch** (2024 “Degen Leverage Machine”) | Quoted as prior art. Now StonkBrokers / RH Chain. Founder: liquidity, not UX, is the bottleneck. | Early “easy mode”; not Monad CLOB. |
| **Derive** (ex-Lyra) | Dominant onchain vanillas: CLOB + RFQ, portfolio margin. DeFiLlama: ~$81m 30d **premium**, ~$4.4b notional; everyone else is small. | Vanilla greeks book, not 100% collat binaries. |
| **Paradex Options** | ZK perps+options, CEX-like, privacy. | Offchain speed / unified margin. |
| **Aevo** | Custom L2 options+perps; volume has faded vs Derive. | Same CEX-on-L2 pattern. |
| **Panoptic** | Perpetual options from Uniswap LP; **no book, no oracle, no expiry.** | Opposite of dated, oracle-settled binaries. |
| **Rysk / Thetanuts / SOFA** | Vault/RFQ **sellers** (covered calls, structured). | Supply side, not a public binary book. |
| **Polymarket** | Event YES/NO. Huge retail. US geoblocked on .com. | Same payoff shape; not a token-threshold CLOB with Pyth. |

Montions’ actual gap: **onchain matching + 100% collateral + Pyth first-print settlement**, not another skin on Derive.

### 3. Counters (from the same week, plus structure)

- **Liquidity, not UX:** [@OxSimpleFarmer](https://x.com/OxSimpleFarmer/status/2107590317486780427) (Clutch founder, 6 Oct): *“the bottle neck for options isn’t (only ux) its liquidity for the underlying assets.”* Thin underlyings → garbage IV / empty books.
- **Pros already have a desk.** Deribit/Paradigm/Telegram is the real options market; a pretty sentence doesn’t move that flow.
- **MM:** binary books need two-sided quotes at 1–99¢ or they die. Vaults help; they don’t create flow.
- **Oracle:** Derive still uses listed expiries + venue settlement. A permissionless Pyth print is cleaner *and* a manipulation/void-path problem (your 50/50 void is the honest version).
- **Regulation:** Derive (25 Aug 2026): US retail still largely blocked; venue + product type matter ([post](https://www.derive.xyz/blog/are-crypto-options-legal-in-2026/)). Binaries sit next to prediction markets in a regulator’s head.
- **Scale check:** even Derive’s options are a rounding error vs perps. “Traction” is relative.

### 4. Pitch lines (honest)

1. *Retail already types the order: “I want to make $1,000 if MON is above $X by Friday.” Hunch proved the sentence; we settle it on a book.*
2. *Perps won by hiding greeks. Options win when max loss is the premium — and the UI never says “delta.”*
3. *Polymarket taught YES/NO. A MON-above-$X contract is that product with a price feed.*
4. *The bottleneck isn’t another options chain. It’s a solvent, 100% collateralised CLOB that doesn’t need Deribit, Paradigm, or Telegram.*
5. *We’re not claiming options volume flipped perps. We’re claiming the interface finally matches how people bet — and Monad can keep the matcher onchain.*
