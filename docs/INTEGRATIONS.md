# Partner integrations

What is actually wired in, and what it takes to use it. Nothing here is claimed that does not exist in the code.

| Partner | Status | Where |
|---|---|---|
| **Pyth** | Settlement oracle for the 34 mainnet markets (first price at/after expiry). Needs a Hermes API key for the keeper. | `src/oracle/pyth`, `src/resolvers/PythSettlementResolver.sol`, `bots/src/pyth.ts` |
| **Mera** (Monad Foundation) | Passkey sign-in (WebAuthn PRF → EOA) **and "one passkey, many keys"**: five accounts derived from the same passkey, switchable from the account menu without another passkey prompt (account work; see "Bounty fit" below). | `app/src/lib/passkey.ts`, `app/src/components/AccountSheet.tsx` |
| **Agora / AUSD** | Alternative collateral: `COLLATERAL=AUSD scripts/mainnet-deploy.sh`. The permit signer reads AUSD's ERC-5267 domain (`"Agora Dollar"`, v1) and verifies it against `DOMAIN_SEPARATOR()`. Mobile-first PWA. **AUSD exists on mainnet only** — there is no AUSD on Monad testnet, so the testnet uses a mintable test token. | `sdk/src/client.ts` (`matchPermitDomain`), `scripts/mainnet-deploy.sh` |
| **RPC providers** | The app fails over across several endpoints. Keyless public endpoints are in every manifest (`scripts/finish-manifest.mjs`). Provider endpoints that carry an API key (Chainstack, Alchemy, QuickNode, Dwellir, BlockVision, Crouton, Spectrum) can be put in front with `RPCS=…` at manifest time, or `VITE_RPC_URLS=…` at build time. Keys in a static page are visible to users: use domain-restricted keys. | `app/src/api/chain.ts`, `scripts/finish-manifest.mjs` |

## Bounty fit (checked against the platform's actual requirements)

- **Monad Foundation — Best Mera-Powered UX:** applied for. Mera is the primary account layer (passkey-only first trade); browser wallets are an alternative.
- **Monad Foundation — Mera: One Passkey, Many Keys:** NOT applied for. It rewards PRF namespaces used for *non-account* work (not signing from a wallet). Our five derived accounts are account work.
- **Agora — Best Mobile Trading App:** NOT applied for. It requires trades executed through **Perpl** plus Mera login and an AUSD balance. Montions trades on its own book, so it does not qualify. AUSD collateral support stays as a feature.

## Wallets, PWA, logo

- **Wallets:** passkey (Mera) or any browser wallet. Wallets are discovered with EIP-6963 (MetaMask, Rabby, Phantom, Coinbase… listed side by side), with `window.ethereum` as a fallback. On a phone without an injected wallet the sheet offers "Open in MetaMask app". Passkey accounts send through the same multi-endpoint RPC failover as reads.
- **PWA:** web manifest + service worker (`app/public/sw.js`): installable, and the app shell starts offline. Trading itself needs the network. RPC, the manifest `deployment.json` and wallet traffic are never cached.
- **Logo:** designed with Codex (gpt-6-luna); sources in `docs/brand/` (mark, maskable mark, wordmark, favicon).

## Using sponsor RPC endpoints

```bash
# at build time (Vercel: Project → Settings → Environment Variables)
VITE_RPC_URLS="https://monad-testnet.g.alchemy.com/v2/<domain-restricted-key>,https://<chainstack-endpoint>"
# keepers / bots
RPC_URL="https://<your-provider-endpoint>"
```

## Where keys go

| Key | Used by | Local file | Vercel env var |
|---|---|---|---|
| Pyth Hermes | keeper / settlement bot | `.dev/hermes.key` (or `HERMES_API_KEY`) | — (never in the page) |
| Sponsor RPC endpoints (Alchemy, Chainstack, QuickNode, Dwellir, BlockVision) | app reads + bots | `app/.env.local` → `VITE_RPC_URLS=` | `VITE_RPC_URLS` (public, so domain-restrict the key) |
| Alchemy API key | app + bots (primary RPC) | `app/.env.local` → `VITE_ALCHEMY_KEY=` | `VITE_ALCHEMY_KEY` (public, so domain-restrict it) |

`.env*` files (except `.env.example`) and `.dev/` are gitignored. Anything named `VITE_*` ends up in the browser bundle.

## Not integrated (deliberately)

Perpl, Kuru, Chainlink CRE, Nansen, Zerion, MetaMask agent wallet and Aurora do not fit a binary-options book. Privy/Dynamic overlap with Mera. Envio would add an indexer to a project whose point is that it needs none.
