import {
  type Address,
  type Hex,
} from "viem";
import { erc20Abi } from "../../sdk/src/abi/erc20.js";
import { addressAt, hasFlag, isDryRun, loadBotContext, sendAndWait } from "./runtime.js";
import { meanRevertingLogStep, standardNormal } from "./priceWalk.js";

const poolAbi = [
  { type: "function", name: "baseReserve", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "quoteReserve", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "priceWad", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "swapExactIn",
    stateMutability: "nonpayable",
    inputs: [
      { name: "tokenIn", type: "address" },
      { name: "amountIn", type: "uint256" },
      { name: "minOut", type: "uint256" },
      { name: "to", type: "address" },
    ],
    outputs: [{ name: "out", type: "uint256" }],
  },
] as const;

const faucetAbi = [{ type: "function", name: "faucet", stateMutability: "nonpayable", inputs: [], outputs: [] }] as const;
interface WalkState {
  anchor: number;
  logPrice: number;
  lastTime: number;
}

function positiveNumber(value: string | undefined, fallback: number, name: string): number {
  const parsed = value === undefined ? fallback : Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) throw new Error(`${name} must be a positive number`);
  return parsed;
}

async function main(): Promise<void> {
  const dryRun = isDryRun();
  const context = loadBotContext(!dryRun);
  const { deployment, publicClient, walletClient, account } = context;
  const collateral = addressAt(deployment, "collateral");
  const intervalMs = positiveNumber(process.env.PRICE_BOT_INTERVAL_MS, 4_000, "PRICE_BOT_INTERVAL_MS");
  const annualVol = positiveNumber(process.env.PRICE_VOL, 0.55, "PRICE_VOL");
  const swapBps = BigInt(Math.floor(positiveNumber(process.env.PRICE_SWAP_BPS, 3, "PRICE_SWAP_BPS")));
  if (swapBps > 100n) throw new Error("PRICE_SWAP_BPS must not exceed 100 (1% of reserves)");
  const bias = process.env.PRICE_BOT_BIAS ?? "none";
  if (!(["none", "up", "down"] as const).includes(bias as "none" | "up" | "down")) {
    throw new Error("PRICE_BOT_BIAS must be one of none, up, down");
  }
  const forceOnce = hasFlag("--once");
  const states = new Map<string, WalkState>();
  const quoteAddress = collateral;

  for (const asset of deployment.assets) {
    const current = await publicClient.readContract({ address: asset.pool, abi: poolAbi, functionName: "priceWad" });
    const logPrice = Math.log(Number(current) / 1e18);
    states.set(asset.symbol, { anchor: logPrice, logPrice, lastTime: Date.now() / 1000 });
  }

  console.log(`DEMO PRICE BOT starting (${dryRun ? "dry-run" : "live"}); pool TWAP is manipulable and demo-only`);
  do {
    const wallNow = Date.now() / 1000;
    for (const asset of deployment.assets) {
      const pool = asset.pool;
      const baseAddress = asset.token;
      const baseReserve = await publicClient.readContract({ address: pool, abi: poolAbi, functionName: "baseReserve" });
      const quoteReserve = await publicClient.readContract({ address: pool, abi: poolAbi, functionName: "quoteReserve" });
      const spot = await publicClient.readContract({ address: pool, abi: poolAbi, functionName: "priceWad" });
      const state = states.get(asset.symbol)!;
      const elapsed = Math.max(1, wallNow - state.lastTime);
      const proposed = meanRevertingLogStep(
        state.logPrice,
        state.anchor,
        annualVol,
        elapsed,
        standardNormal(),
      );
      let up = proposed >= state.logPrice;
      if (bias === "up") up = true;
      if (bias === "down") up = false;
      state.logPrice = proposed;
      state.lastTime = wallNow;

      const tokenIn: Address = up ? quoteAddress : baseAddress;
      const reserveIn = up ? quoteReserve : baseReserve;
      const amountIn = (reserveIn * swapBps) / 10_000n || 1n;
      const oldSpot = Number(spot) / 1e18;
      if (dryRun) {
        console.log(`DEMO PRICE BOT ${asset.symbol} ${up ? "UP" : "DOWN"} dry-run amount=${amountIn} spot=$${oldSpot.toFixed(6)}`);
        continue;
      }
      if (!walletClient || !account) throw new Error("Missing funded bot signer");
      const botAddress = typeof account === "string" ? account : account.address;

      const balance = await publicClient.readContract({ address: tokenIn, abi: erc20Abi, functionName: "balanceOf", args: [botAddress] });
      if (balance < amountIn) {
        try {
          const faucetHash = await walletClient.writeContract({ address: tokenIn, abi: faucetAbi, functionName: "faucet", account, chain: undefined });
          await sendAndWait(context, faucetHash, `${asset.symbol} token faucet`);
        } catch {
          throw new Error(`Bot wallet needs more ${up ? "tUSDC" : asset.symbol} for the demo swap`);
        }
      }
      const allowance = await publicClient.readContract({
        address: tokenIn,
        abi: erc20Abi,
        functionName: "allowance",
        args: [botAddress, pool],
      });
      if (allowance < amountIn) {
        const approveHash = await walletClient.writeContract({
          address: tokenIn,
          abi: erc20Abi,
          functionName: "approve",
          args: [pool, amountIn],
          account,
          chain: undefined,
        });
        await sendAndWait(context, approveHash, `${asset.symbol} pool approval`);
      }
      const hash: Hex = await walletClient.writeContract({
        address: pool,
        abi: poolAbi,
        functionName: "swapExactIn",
        args: [tokenIn, amountIn, 0n, botAddress],
        account,
        chain: undefined,
      });
      await sendAndWait(context, hash, `${asset.symbol} demo swap`);
      const newSpot = await publicClient.readContract({ address: pool, abi: poolAbi, functionName: "priceWad" });
      console.log(
        `DEMO PRICE BOT ${asset.symbol} ${up ? "UP" : "DOWN"} amount=${amountIn} ` +
          `spot=$${oldSpot.toFixed(6)}->$${(Number(newSpot) / 1e18).toFixed(6)}`,
      );
    }
    if (!forceOnce) await new Promise((resolve) => setTimeout(resolve, intervalMs));
  } while (!forceOnce);
}

main().catch((error: unknown) => {
  console.error(`DEMO PRICE BOT failed: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
});
