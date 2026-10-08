# Partner integrations

What is actually wired in, and what it takes to use it. Nothing here is claimed that does not exist in the code.

| Partner | Status | Where |
|---|---|---|
| **Pyth** | Settlement oracle for the 34 mainnet markets (first price at/after expiry). Needs a Hermes API key for the keeper. | `src/oracle/pyth`, `src/resolvers/PythSettlementResolver.sol`, `bots/src/pyth.ts` |
| **Mera** (Monad Foundation) | Passkey sign-in (WebAuthn PRF → EOA) **and "one passkey, many keys"**: five accounts derived from the same passkey, switchable from the account menu without another passkey prompt. | `app/src/lib/passkey.ts`, `app/src/components/AccountSheet.tsx` |
| **Agora / AUSD** | Alternative collateral: `COLLATERAL=AUSD scripts/mainnet-deploy.sh`. The permit signer reads AUSD's ERC-5267 domain (`"Agora Dollar"`, v1) and verifies it against `DOMAIN_SEPARATOR()`. Mobile-first PWA. **AUSD exists on mainnet only** — there is no AUSD on Monad testnet, so the testnet uses a mintable test token. | `sdk/src/client.ts` (`matchPermitDomain`), `scripts/mainnet-deploy.sh` |
| **RPC providers** | The app fails over across several endpoints. Keyless public endpoints are in every manifest (`scripts/finish-manifest.mjs`). Provider endpoints that carry an API key (Chainstack, Alchemy, QuickNode, Dwellir, BlockVision, Crouton, Spectrum) can be put in front with `RPCS=…` at manifest time, or `VITE_RPC_URLS=…` at build time. Keys in a static page are visible to users: use domain-restricted keys. | `app/src/api/chain.ts`, `scripts/finish-manifest.mjs` |

## Using sponsor RPC endpoints

```bash
# at build time (Vercel: Project → Settings → Environment Variables)
VITE_RPC_URLS="https://monad-testnet.g.alchemy.com/v2/<domain-restricted-key>,https://<chainstack-endpoint>"
# keepers / bots
RPC_URL="https://<your-provider-endpoint>"
```

## Not integrated (deliberately)

Perpl, Kuru, Chainlink CRE, Nansen, Zerion, MetaMask agent wallet and Aurora do not fit a binary-options book. Privy/Dynamic overlap with Mera. Envio would add an indexer to a project whose point is that it needs none.
