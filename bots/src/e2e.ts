import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  http,
  parseAbiParameters,
  getAddress,
  isAddress,
  type Address,
  type Hex,
} from "viem";
import { erc20Abi, montionsBookAbi } from "../../sdk/src/abi/index.js";
import { MontionsClient } from "../../sdk/src/client.js";
import { parseDeployment } from "../../sdk/src/deployments.js";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const manifestPath = resolve(root, process.env.DEPLOYMENT ?? "deployments/31337.json");
const deployment = parseDeployment(JSON.parse(readFileSync(manifestPath, "utf8")) as unknown);
const rpcUrl = process.env.RPC_URL ?? deployment.rpc;
const chain = defineChain({
  id: deployment.chainId,
  name: "Montions local e2e",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [rpcUrl] } },
});
const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });
const sdkPublicClient = new Proxy(publicClient, {
  get(target, property, receiver) {
    if (property === "multicall") {
      return async (parameters: { contracts: readonly Record<string, unknown>[] }) =>
        Promise.all(parameters.contracts.map((contract) => target.readContract(contract as never)));
    }
    return Reflect.get(target, property, receiver);
  },
}) as typeof publicClient;
const maker = requiredAddress("DEPLOYER_ADDRESS");
const user = requiredAddress("BOT_ADDRESS");
const makerWallet = createWalletClient({ account: maker, chain, transport: http(rpcUrl) });
const userWallet = createWalletClient({ account: user, chain, transport: http(rpcUrl) });
const book = deployment.contracts.book!;
const quoter = deployment.contracts.quoter!;
const collateral = deployment.contracts.collateral!;
const hub = deployment.contracts.oracleHub!;
const resolver = deployment.contracts.twapResolver!;

function requiredAddress(name: "DEPLOYER_ADDRESS" | "BOT_ADDRESS"): Address {
  const value = process.env[name];
  if (!value || !isAddress(value)) throw new Error(`${name} must be an RPC-unlocked EVM address`);
  return getAddress(value);
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(`E2E assertion failed: ${message}`);
}

async function wait(hash: Hex, label: string): Promise<void> {
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  assert(receipt.status === "success", `${label} transaction reverted (${hash})`);
}

async function rpc(method: string, params: unknown[] = []): Promise<unknown> {
  return publicClient.request({ method: method as never, params: params as never } as never);
}

async function runPriceBotUp(): Promise<void> {
  const result = spawnSync("pnpm", ["--dir", "bots", "exec", "tsx", "src/price-bot.ts", "--once"], {
    cwd: root,
    stdio: "inherit",
    env: {
      ...process.env,
      DEPLOYMENT: manifestPath,
      RPC_URL: rpcUrl,
      PRICE_BOT_BIAS: "up",
      PRICE_SWAP_BPS: "25",
    },
  });
  if (result.error) throw result.error;
  assert(result.status === 0, "price-bot --once exited successfully");
}

async function runKeeperOnce(): Promise<void> {
  const result = spawnSync("pnpm", ["--dir", "bots", "exec", "tsx", "src/keeper.ts", "--once"], {
    cwd: root,
    stdio: "inherit",
    env: { ...process.env, DEPLOYMENT: manifestPath, RPC_URL: rpcUrl },
  });
  if (result.error) throw result.error;
  assert(result.status === 0, "keeper --once exited successfully");
}

async function main(): Promise<void> {
  const client = new MontionsClient({
    deployment,
    chain,
    rpcUrl,
    publicClient: sdkPublicClient,
    walletClient: userWallet,
    account: user,
  });

  const faucetHash = await userWallet.writeContract({ address: collateral, abi: erc20Abi, functionName: "faucet" });
  await wait(faucetHash, "tUSDC faucet");
  const faucetBalance = await publicClient.readContract({ address: collateral, abi: erc20Abi, functionName: "balanceOf", args: [user] });
  assert(faucetBalance >= 10_000_000_000n, "test user received tUSDC from faucet");

  const mon = deployment.assets.find((asset) => asset.symbol.toUpperCase() === "MON");
  assert(mon, "MON demo asset exists in manifest");
  const spotPoolAbi = [
    { type: "function", name: "priceWad", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  ] as const;
  const spot = await publicClient.readContract({ address: mon.pool, abi: spotPoolAbi, functionName: "priceWad" });
  const strike = (spot * 1_002n) / 1_000n;
  const currentBlock = await publicClient.getBlock();
  const expiry = currentBlock.timestamp + 130n;
  const data = encodeAbiParameters(parseAbiParameters("address, bytes32, uint256, bool, uint32"), [
    hub,
    mon.assetId,
    strike,
    true,
    60,
  ]);

  const createHash = await makerWallet.writeContract({
    address: book,
    abi: montionsBookAbi,
    functionName: "createSeries",
    args: [resolver, data, expiry],
  });
  await wait(createHash, "short expiry series creation");
  const seriesId = await publicClient.readContract({
    address: book,
    abi: montionsBookAbi,
    functionName: "seriesIdOf",
    args: [resolver, data, expiry],
  });

  const makerAskHash = await makerWallet.writeContract({
    address: book,
    abi: montionsBookAbi,
    functionName: "placeOrder",
    args: [{ seriesId, side: 1, tick: 65, qty: 10n, fromHeld: false, tif: 0, maxFills: 0 }],
  });
  await wait(makerAskHash, "test maker ask");

  const snapshots = [];
  for (let offset = 0; ; offset += 50) {
    const page = await client.snapshots(offset, 50);
    snapshots.push(...page);
    if (page.length < 50) break;
  }
  const snapshot = snapshots.find((item) => item.seriesId.toLowerCase() === seriesId.toLowerCase());
  assert(snapshot?.info.status === 1, "short series appears in Quoter.snapshots as Open");
  const quote = await client.quoteBuy(seriesId, true, 1n, 75);
  assert(quote.filled === 1n && quote.cost > 0n, "Quoter returns a complete YES buy quote");

  const cashBefore = await client.cashBalances(user);
  const externalUsdcBeforeDeposit = await client.collateralBalance(user);
  const orderHash = await client.depositWithPermitAndPlaceOrder(
    10_000_000n,
    { seriesId, side: "bid", tick: 75, qty: 1n, tif: "ioc" },
    { owner: user },
  );
  await wait(orderHash, "permit deposit and YES buy multicall");
  const positionAfterBuy = await client.positions(seriesId, user);
  const cashAfterBuy = await client.cashBalances(user);
  const externalUsdcAfterBuy = await client.collateralBalance(user);
  assert(positionAfterBuy.yes === 1n, "user owns one YES token after the buy");
  assert(positionAfterBuy.no === 0n, "user owns no NO tokens after the buy");
  assert(cashAfterBuy.free < 10_000_000n && cashAfterBuy.free > 0n, "Book cash reflects the premium paid");
  assert(cashAfterBuy.free > cashBefore.free, "permit deposit credits internal Book cash");
  assert(externalUsdcBeforeDeposit - externalUsdcAfterBuy === 10_000_000n, "permit multicall transfers exactly the deposit");

  const warpBlock = await publicClient.getBlock();
  const priceMoveAt = expiry - 65n;
  assert(priceMoveAt > warpBlock.timestamp, "enough time remains to warm the TWAP before expiry");
  await rpc("anvil_setNextBlockTimestamp", [Number(priceMoveAt)]);
  await rpc("anvil_mine", ["0x1"]);
  for (let attempt = 0; attempt < 4; attempt++) {
    await runPriceBotUp();
    const movedSpot = await publicClient.readContract({ address: mon.pool, abi: spotPoolAbi, functionName: "priceWad" });
    if (movedSpot > strike) break;
  }
  const finalSpot = await publicClient.readContract({ address: mon.pool, abi: spotPoolAbi, functionName: "priceWad" });
  assert(finalSpot > strike, "DEMO price-bot swaps move MON spot above the test strike");

  const expiryBlock = await publicClient.getBlock();
  const targetTimestamp = expiry + 1n;
  assert(expiryBlock.timestamp < targetTimestamp, "series expiry has not passed before final warp");
  await rpc("anvil_setNextBlockTimestamp", [Number(targetTimestamp)]);
  await rpc("anvil_mine", ["0x1"]);
  await runKeeperOnce();

  const info = await publicClient.readContract({ address: book, abi: montionsBookAbi, functionName: "seriesInfo", args: [seriesId] });
  const status = Array.isArray(info) ? Number(info[3]) : Number((info as { status: number }).status);
  const yesOutcome = Array.isArray(info) ? Boolean(info[4]) : Boolean((info as { yes: boolean }).yes);
  assert(status === 2 && yesOutcome, "keeper resolves the market YES");

  const cashBeforeRedeem = await client.cashBalances(user);
  const externalUsdcBeforeRedeem = await client.collateralBalance(user);
  const redeemHash = await client.redeem(seriesId, 1n, 0n);
  await wait(redeemHash, "redeem winning YES token");
  const finalPosition = await client.positions(seriesId, user);
  const finalCash = await client.cashBalances(user);
  const externalUsdcFinal = await client.collateralBalance(user);
  assert(finalPosition.yes === 0n, "redeemed YES token is burned");
  assert(finalCash.free === cashBeforeRedeem.free + 1_000_000n, "winning YES redeems for exactly 1 tUSDC");
  assert(externalUsdcFinal === externalUsdcBeforeRedeem, "payout is credited to internal Book cash");
  console.log(`E2E PASS: BUY YES, resolve YES, redeem 1.000000 tUSDC (series ${seriesId})`);
}

main().catch((error: unknown) => {
  console.error(`E2E FAIL: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
  process.exitCode = 1;
});
