// Passkey (Face ID / Touch ID / security key) accounts via Mera (Category Labs): the passkey's WebAuthn PRF output deterministically
// derives an ordinary EVM key — no seed phrase, no smart-account deployment. The same passkey reproduces the same address on every device it syncs to.
import {
  createPasskeyWithPrfOutput, getPasskeyPrfOutput, createSecp256k1SigningSession, isMeraError,
  type PasskeyCredentialMetadata, type Secp256k1SigningSession,
} from "@category-labs/mera";
import { toViemAccount } from "@category-labs/mera/viem";
import { HDKey } from "@scure/bip32";
import { entropyToMnemonic, mnemonicToSeedSync } from "@scure/bip39";
import { wordlist } from "@scure/bip39/wordlists/english.js";
import type { Account } from "viem";

const STORE_KEY = "montions.passkey.v1";
const IDLE_MS = 20 * 60 * 1000;

/** BIP-44 EVM key for account `index` from the 32-byte PRF output (index > 0 = "one passkey, many keys"). */
export function deriveEvmKey(prfOutput: Uint8Array, index = 0): Uint8Array {
  if (prfOutput.length !== 32) throw new Error("PRF output must be 32 bytes");
  const seed = mnemonicToSeedSync(entropyToMnemonic(prfOutput, wordlist));
  const node = HDKey.fromMasterSeed(seed).derive(`m/44'/60'/0'/0/${index}`);
  if (node.privateKey === null) throw new Error("key derivation produced no key");
  return node.privateKey;
}

/** WebAuthn requires a real domain (or "localhost") as the relying-party id: raw IP addresses are rejected by browsers. */
export const hostIsIpAddress = () => typeof location !== "undefined" && (/^\d{1,3}(\.\d{1,3}){3}$/.test(location.hostname) || location.hostname.includes(":"));

export function passkeySupported(): boolean {
  return typeof window !== "undefined" && window.isSecureContext && typeof window.PublicKeyCredential !== "undefined" && !hostIsIpAddress();
}

function loadStored(): PasskeyCredentialMetadata | undefined {
  try { const raw = localStorage.getItem(STORE_KEY); return raw ? (JSON.parse(raw) as PasskeyCredentialMetadata) : undefined; } catch { return undefined; }
}
function saveStored(c: PasskeyCredentialMetadata) { try { localStorage.setItem(STORE_KEY, JSON.stringify({ credentialId: c.credentialId, ...(c.transports ? { transports: c.transports } : {}) })); } catch { /* private mode */ } }
export const hasStoredPasskey = () => !!loadStored();

export interface PasskeySession { account: Account; end: () => void }

let current: Secp256k1SigningSession | undefined;
let idleTimer: ReturnType<typeof setTimeout> | undefined;
let onExpire: (() => void) | undefined;

export function endPasskeySession() { clearTimeout(idleTimer); current?.end(); current = undefined; }
/** Call on user activity: extends the idle timeout. After 20 idle minutes the in-memory key is destroyed and the next action re-prompts. */
export function touchPasskeySession() {
  if (!current) return; clearTimeout(idleTimer);
  idleTimer = setTimeout(() => { endPasskeySession(); onExpire?.(); }, IDLE_MS);
}
if (typeof window !== "undefined") window.addEventListener("pagehide", endPasskeySession);

function start(prfOutput: Uint8Array, expire?: () => void): PasskeySession {
  endPasskeySession(); onExpire = expire;
  current = createSecp256k1SigningSession({ privateKey: deriveEvmKey(prfOutput) });
  touchPasskeySession();
  return { account: toViemAccount(current) as unknown as Account, end: endPasskeySession };
}

/** Sign in with an existing passkey (this device's, or any synced passkey for this site). */
export async function signInWithPasskey(expire?: () => void): Promise<PasskeySession> {
  const stored = loadStored();
  const { prfOutput, credentialId } = await getPasskeyPrfOutput({ rpId: location.hostname, ...(stored ? { credential: stored } : {}) });
  if (!stored || stored.credentialId !== credentialId) saveStored({ credentialId });
  return start(prfOutput, expire);
}

/** Create a brand-new passkey account (shows the OS passkey prompt). */
export async function createPasskeyAccount(label = "Montions trader", expire?: () => void): Promise<PasskeySession> {
  const created = await createPasskeyWithPrfOutput({ rp: { id: location.hostname, name: "Montions" }, user: { name: label, displayName: label } });
  saveStored(created);
  return start(created.prfOutput, expire);
}

/** Human-readable reason for a passkey failure. */
export function explainPasskey(e: unknown): string {
  console.error("passkey error:", e, (e as { cause?: unknown })?.cause);
  if (isMeraError(e)) {
    switch (e.code) {
      case "PRF_UNAVAILABLE": return "This passkey provider doesn't support the PRF extension. Use iCloud Keychain, 1Password or Google Password Manager (desktop Chrome often needs the latter).";
      case "PASSKEY_OPERATION_FAILED": return "The passkey prompt was dismissed or failed. Try again.";
      case "CRYPTO_UNAVAILABLE": return "Passkeys need a secure (https) page.";
      case "SESSION_ENDED": return "Your passkey session ended. Sign in again.";
      default: return e.message;
    }
  }
  return e instanceof Error ? e.message : String(e);
}
