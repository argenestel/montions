import { type Address, type Hex } from "viem";
import { makerVaultAbi, montionsBookAbi, quoterAbi } from "../../sdk/src/abi/index.js";
import {
  addressAt,
  envFlag,
  envInt,
  hasFlag,
  isDryRun,
  loadBotContext,
  logLine,
  sendAndWait,
  SerialTx,
  sleep,
  withRpcRetry,
  requirePool,
  type BotContext,
} from "./runtime.js";
import {
  defaultHermesTransport,
  hermesBaseUrl,
  hermesFetchUpdateData,
  iPythAbi,
  pythFeedIdForSymbol,
  pythOracleAbi,
  pythSettlementAbi,
  settlePythWindow,
  MONAD_PYTH_CORE,
  type PythSettleDeps,
} from "./pyth.js";
import {
  CREATE_BATCH_SIZE,
  SERIES_STATUS,
  chunk,
  createSeriesCalldata,
  decodePriceSeriesData,
  encodePlannedSeries,
  readAllSeries,
  selectMissingSeries,
  type OnchainSeries,
} from "./seriesOps.js";
import {
  POOL_SERIES_WINDOW_SECONDS,
  PYTH_SERIES_MAX_DELAY_SECONDS,
  planSeriesLadder,
  type LadderAsset,
} from "./seriesLadder.js";

const hubAbi = [
  {
    type: "function",
    name: "checkpoint",
    stateMutability: "nonpayable",
    inputs: [{ name: "assetId", type: "bytes32" }],
    outputs: [],
  },
] as const;
const poolAbi = [
  { type: "function", name: "priceWad", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

type KeeperMode = "pool" | "pyth";

interface KeeperConfig {
  mode: KeeperMode;
  create: boolean;
  refreshLimit: number;
  intervalMs: number;
  once: boolean;
  dryRun: boolean;
}

interface KeeperClients {
  context: BotContext;
  tx: SerialTx;
  book: Address;
  hub: Address;
  vault?: Address;
  quoter?: Address;
  twapResolver: Address;
  oracleHub: Address;
  pythResolver?: Address;
  pythOracle?: Address;
  pythCore?: Address;
}

function parseMode(raw: string | undefined): KeeperMode {
  const mode = (raw ?? "pool").toLowerCase();
  if (mode !== "pool" && mode !== "pyth") throw new Error("KEEPER_MODE must be pool or pyth");
  return mode;
}

function loadConfig(): KeeperConfig {
  return {
    mode: parseMode(process.env.KEEPER_MODE),
    create: envFlag("KEEPER_CREATE", true),
    refreshLimit: envInt("KEEPER_REFRESH_LIMIT", 40, 0),
    intervalMs: envInt("KEEPER_INTERVAL_MS", 15_000, 250),
    once: hasFlag("--once"),
    dryRun: isDryRun(),
  };
}

function optionalAddress(deployment: BotContext["deployment"], ...names: string[]): Address | undefined {
  for (const name of names) {
    const value = deployment.contracts[name];
    if (value) return value;
  }
  return undefined;
}

async function sendTx(
  clients: KeeperClients,
  config: KeeperConfig,
  label: string,
  write: () => Promise<Hex>,
): Promise<boolean> {
  if (config.dryRun) {
    logLine("keeper", { event: "dry_run", label });
    return true;
  }
  if (!clients.context.walletClient || !clients.context.account) {
    throw new Error("Write path needs BOT_PRIVATE_KEY or an unlocked BOT_ADDRESS");
  }
  await clients.tx.run(async () => {
    if (clients.tx.inFlight !== 1) throw new Error("nonce safety: expected a single in-flight transaction");
    let hash: Hex | undefined;
    await withRpcRetry(
      async () => {
        if (!hash) hash = await write();
        await sendAndWait(clients.context, hash, label);
      },
      { label },
    );
  });
  return true;
}

async function readSpot(clients: KeeperClients, config: KeeperConfig, asset: { symbol: string; assetId: Hex; pool?: Address }): Promise<bigint> {
  if (config.mode === "pyth" && clients.pythOracle) {
    try {
      const latest = await withRpcRetry(
        () =>
          clients.context.publicClient.readContract({
            address: clients.pythOracle!,
            abi: pythOracleAbi,
            functionName: "latestPrice",
            args: [asset.assetId],
          }),
        { label: "pyth latestPrice" },
      );
      const price = latest[0];
      if (price > 0n) return price;
    } catch {
      // Fall back to the demo pool.
    }
  }
  return withRpcRetry(
    () =>
      clients.context.publicClient.readContract({
        address: requirePool(asset),
        abi: poolAbi,
        functionName: "priceWad",
      }),
    { label: `${asset.symbol} priceWad` },
  );
}

async function checkpointPools(clients: KeeperClients, config: KeeperConfig): Promise<number> {
  if (config.mode !== "pool") return 0;
  let n = 0;
  for (const asset of clients.context.deployment.assets) {
    await sendTx(clients, config, `${asset.symbol} oracle checkpoint`, () =>
      clients.context.walletClient!.writeContract({
        address: clients.hub,
        abi: hubAbi,
        functionName: "checkpoint",
        args: [asset.assetId],
        account: clients.context.account!,
        chain: undefined,
      }),
    );
    n++;
  }
  return n;
}

async function createLadder(clients: KeeperClients, config: KeeperConfig, now: bigint): Promise<number> {
  if (!config.create) return 0;
  const window = config.mode === "pyth" ? PYTH_SERIES_MAX_DELAY_SECONDS : POOL_SERIES_WINDOW_SECONDS;
  const resolver = config.mode === "pyth" ? clients.pythResolver : clients.twapResolver;
  const oracle = config.mode === "pyth" ? clients.pythOracle : clients.oracleHub;
  if (!resolver || !oracle) throw new Error(`KEEPER_MODE=${config.mode} is missing resolver/oracle addresses in the manifest`);

  const assets: LadderAsset[] = [];
  for (const asset of clients.context.deployment.assets) {
    assets.push({
      symbol: asset.symbol,
      assetId: asset.assetId,
      ...(asset.tier === "major" || asset.tier === "alt" || asset.tier === "wrapped" ? { tier: asset.tier } : {}),
      spotWad: await readSpot(clients, config, asset),
    });
  }
  const plan = planSeriesLadder(now, assets, { window });
  const encoded = plan.map((item) => encodePlannedSeries(item, oracle, resolver));
  const missing = await selectMissingSeries(clients.context, clients.book, encoded);
  logLine("keeper", { event: "ladder", planned: plan.length, missing: missing.length, mode: config.mode });
  if (missing.length === 0) return 0;
  if (config.dryRun) return missing.length;

  let created = 0;
  for (const batch of chunk(missing, CREATE_BATCH_SIZE)) {
    const calls = batch.map((item) => createSeriesCalldata(resolver, item.data, item.expiry));
    await sendTx(clients, config, "rolling series creation batch", () =>
      clients.context.walletClient!.writeContract({
        address: clients.book,
        abi: montionsBookAbi,
        functionName: "multicall",
        args: [calls],
        account: clients.context.account!,
        chain: undefined,
      }),
    );
    created += batch.length;
  }
  return created;
}

async function feedIdFor(
  clients: KeeperClients,
  symbol: string,
  assetId: Hex,
): Promise<Hex> {
  if (clients.pythOracle) {
    try {
      const id = await withRpcRetry(
        () =>
          clients.context.publicClient.readContract({
            address: clients.pythOracle!,
            abi: pythOracleAbi,
            functionName: "feedIdOf",
            args: [assetId],
          }),
        { label: "feedIdOf" },
      );
      if (id && id !== "0x".padEnd(66, "0")) return id;
    } catch {
      // Fall through to the static table / env override.
    }
  }
  const fallback = pythFeedIdForSymbol(symbol);
  if (!fallback) throw new Error(`No Pyth feed id for ${symbol} (${assetId})`);
  return fallback;
}

function makePythDeps(clients: KeeperClients, config: KeeperConfig): PythSettleDeps {
  if (!clients.pythResolver) throw new Error("pythSettlementResolver is missing from the deployment manifest");
  const resolver = clients.pythResolver;
  const pythCore = clients.pythCore ?? MONAD_PYTH_CORE;
  const transport = defaultHermesTransport();
  const hermesUrl = hermesBaseUrl();
  return {
    fetchUpdateData: (feedId, unixTime) => hermesFetchUpdateData(feedId, unixTime, transport, hermesUrl),
    getUpdateFee: (updateData) =>
      withRpcRetry(
        () =>
          clients.context.publicClient.readContract({
            address: pythCore,
            abi: iPythAbi,
            functionName: "getUpdateFee",
            args: [updateData],
          }),
        { label: "getUpdateFee" },
      ),
    isSettled: (assetId, expiry) =>
      withRpcRetry(
        () =>
          clients.context.publicClient.readContract({
            address: resolver,
            abi: pythSettlementAbi(),
            functionName: "isSettled",
            args: [assetId, expiry],
          }),
        { label: "isSettled" },
      ),
    sleep,
    settle: async (assetId, expiry, updateData, value) => {
      if (config.dryRun) {
        logLine("keeper", { event: "dry_run", label: "pyth settle", assetId, expiry: expiry.toString() });
        return;
      }
      await sendTx(clients, config, "pyth settle", () =>
        clients.context.walletClient!.writeContract({
          address: resolver,
          abi: pythSettlementAbi(),
          functionName: "settle",
          args: [assetId, expiry, updateData],
          value,
          account: clients.context.account!,
          chain: undefined,
        }),
      );
    },
  };
}

async function resolveSeries(clients: KeeperClients, config: KeeperConfig, id: Hex): Promise<boolean> {
  try {
    await sendTx(clients, config, "series resolution", () =>
      clients.context.walletClient!.writeContract({
        address: clients.book,
        abi: montionsBookAbi,
        functionName: "resolve",
        args: [id],
        account: clients.context.account!,
        chain: undefined,
      }),
    );
    return true;
  } catch (error) {
    logLine("keeper", {
      event: "resolve_pending",
      series: id,
      error: error instanceof Error ? error.message : String(error),
    });
    return false;
  }
}

async function settleAndResolve(
  clients: KeeperClients,
  config: KeeperConfig,
  now: bigint,
  all: readonly OnchainSeries[],
): Promise<number> {
  const expired = all.filter((item) => item.status === SERIES_STATUS.Open && now > item.expiry);
  if (expired.length === 0) return 0;

  if (config.mode === "pool") {
    let resolved = 0;
    for (const item of expired) {
      if (await resolveSeries(clients, config, item.id)) resolved++;
    }
    return resolved;
  }

  const deps = makePythDeps(clients, config);
  const groups = new Map<string, { assetId: Hex; expiry: bigint; symbol: string; series: OnchainSeries[] }>();
  for (const item of expired) {
    const decoded = decodePriceSeriesData(item.data);
    if (!decoded) continue;
    const key = `${decoded.assetId}:${item.expiry.toString()}`;
    const existing = groups.get(key);
    if (existing) existing.series.push(item);
    else {
      const asset = clients.context.deployment.assets.find((a) => a.assetId.toLowerCase() === decoded.assetId.toLowerCase());
      groups.set(key, {
        assetId: decoded.assetId,
        expiry: item.expiry,
        symbol: asset?.symbol ?? "UNKNOWN",
        series: [item],
      });
    }
  }

  let resolved = 0;
  for (const group of groups.values()) {
    const feedId = await feedIdFor(clients, group.symbol, group.assetId);
    const result = await settlePythWindow({
      assetId: group.assetId,
      expiry: group.expiry,
      feedId,
      nowSeconds: now,
      deps,
    });
    logLine("keeper", {
      event: "pyth_settle",
      asset: group.symbol,
      expiry: group.expiry.toString(),
      status: result.status,
      attempts: result.attempts,
    });
    if (result.status === "too_early" || result.status === "not_found") continue;
    for (const item of group.series) {
      if (await resolveSeries(clients, config, item.id)) resolved++;
    }
  }
  return resolved;
}

async function refreshVault(
  clients: KeeperClients,
  config: KeeperConfig,
  now: bigint,
  all: readonly OnchainSeries[],
): Promise<number> {
  if (!clients.vault || config.refreshLimit <= 0) return 0;
  const open = all.filter((item) => item.status === SERIES_STATUS.Open && now < item.expiry);
  if (open.length === 0) return 0;

  const ranked: { id: Hex; score: number }[] = [];
  if (clients.quoter) {
    const pageSize = 50n;
    for (let offset = 0n; ; offset += pageSize) {
      const page = await withRpcRetry(
        () =>
          clients.context.publicClient.readContract({
            address: clients.quoter!,
            abi: quoterAbi,
            functionName: "snapshots",
            args: [offset, pageSize],
          }),
        { label: "quoter.snapshots" },
      );
      for (const snap of page) {
        const id = snap.seriesId as Hex;
        const status = Number(snap.info?.status ?? 0);
        if (status !== SERIES_STATUS.Open) continue;
        const fair = Number(snap.fairTick ?? 0);
        const score = fair === 0 ? 99 : Math.abs(fair - 50);
        ranked.push({ id, score });
      }
      if (page.length < Number(pageSize)) break;
    }
  } else {
    for (const item of open) ranked.push({ id: item.id, score: 50 });
  }

  ranked.sort((a, b) => a.score - b.score || (a.id < b.id ? -1 : 1));
  const seen = new Set<string>();
  const targets: Hex[] = [];
  for (const row of ranked) {
    const key = row.id.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    targets.push(row.id);
    if (targets.length >= config.refreshLimit) break;
  }

  let refreshed = 0;
  for (const id of targets) {
    try {
      await sendTx(clients, config, "vault refresh", () =>
        clients.context.walletClient!.writeContract({
          address: clients.vault!,
          abi: makerVaultAbi,
          functionName: "refresh",
          args: [id],
          account: clients.context.account!,
          chain: undefined,
        }),
      );
      refreshed++;
    } catch (error) {
      logLine("keeper", {
        event: "refresh_skip",
        series: id,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }
  return refreshed;
}

async function tick(clients: KeeperClients, config: KeeperConfig): Promise<void> {
  const checkpoints = await checkpointPools(clients, config);
  const block = await withRpcRetry(() => clients.context.publicClient.getBlock(), { label: "getBlock" });
  const now = block.timestamp;
  const created = await createLadder(clients, config, now);
  const all = await readAllSeries(clients.context, clients.book);
  const resolved = await settleAndResolve(clients, config, now, all);
  const refreshed = await refreshVault(clients, config, now, all);
  logLine("keeper", {
    event: "tick",
    mode: config.mode,
    dry_run: config.dryRun,
    checkpoints,
    created,
    resolved,
    refreshed,
    series: all.length,
  });
}

async function main(): Promise<void> {
  const config = loadConfig();
  const context = loadBotContext(!config.dryRun);
  const clients: KeeperClients = {
    context,
    tx: new SerialTx(),
    book: addressAt(context.deployment, "book"),
    hub: addressAt(context.deployment, "oracleHub"),
    vault: optionalAddress(context.deployment, "vault"),
    quoter: optionalAddress(context.deployment, "quoter"),
    twapResolver: addressAt(context.deployment, "twapResolver"),
    oracleHub: addressAt(context.deployment, "oracleHub"),
    pythResolver: optionalAddress(context.deployment, "pythSettlementResolver", "pythResolver"),
    pythOracle: optionalAddress(context.deployment, "pythOracle"),
    pythCore: optionalAddress(context.deployment, "pyth") ?? (process.env.PYTH_ADDRESS as Address | undefined),
  };
  if (config.mode === "pyth" && !clients.pythResolver) {
    throw new Error("KEEPER_MODE=pyth requires contracts.pythSettlementResolver in the deployment manifest");
  }

  logLine("keeper", {
    event: "start",
    mode: config.mode,
    create: config.create,
    refresh_limit: config.refreshLimit,
    interval_ms: config.intervalMs,
    dry_run: config.dryRun,
    once: config.once,
    chain: context.deployment.chainId,
  });

  const shutdown = (): void => {
    logLine("keeper", { event: "shutdown" });
    process.exit(0);
  };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);

  do {
    const started = Date.now();
    try {
      await tick(clients, config);
    } catch (error) {
      logLine("keeper", {
        event: "tick_error",
        error: error instanceof Error ? error.message : String(error),
      });
      if (config.once) throw error;
    }
    if (config.once) break;
    const elapsed = Date.now() - started;
    const wait = Math.max(config.intervalMs, 1_000) - Math.min(elapsed, config.intervalMs);
    await sleep(Math.max(wait, 1_000));
  } while (!config.once);
}

main().catch((error: unknown) => {
  console.error(`KEEPER failed: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
});
