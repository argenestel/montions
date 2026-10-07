import { describe, expect, it } from "vitest";
import {
  decodeFunctionData,
  encodeAbiParameters,
  encodeFunctionResult,
  custom,
  createPublicClient,
  createWalletClient,
  recoverTypedDataAddress,
  type Hex,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { montionsBookAbi } from "../src/abi/index.js";
import {
  MontionsClient,
  encodeDepositWithPermit,
  encodePlaceOrder,
  type PermitSignature,
} from "../src/client.js";
import { MULTICALL3_ADDRESS, monadTestnet } from "../src/chain.js";
import { parseDeployment } from "../src/deployments.js";

const BOOK = "0x00000000000000000000000000000000000000b0" as const;
const QUOTER = "0x00000000000000000000000000000000000000c0" as const;
const TOKEN = "0x00000000000000000000000000000000000000d0" as const;
const SERIES = `0x${"11".repeat(32)}` as Hex;

describe("MontionsClient calldata", () => {
  it("encodes an IOC YES bid with the frozen PlaceParams tuple", () => {
    const data = encodePlaceOrder({
      seriesId: SERIES,
      side: "bid",
      tick: 35,
      qty: 4n,
      tif: "ioc",
      maxFills: 7,
    });
    const decoded = decodeFunctionData({ abi: montionsBookAbi, data });
    expect(decoded.functionName).toBe("placeOrder");
    expect(decoded.args?.[0]).toMatchObject({
      seriesId: SERIES,
      side: 0,
      tick: 35,
      qty: 4n,
      fromHeld: false,
      tif: 1,
      maxFills: 7,
    });
  });

  it("encodes the EIP-2612 signature fields in depositWithPermit", () => {
    const permit: Pick<PermitSignature, "deadline" | "v" | "r" | "s"> = {
      deadline: 123456n,
      v: 28,
      r: `0x${"22".repeat(32)}`,
      s: `0x${"33".repeat(32)}`,
    };
    const decoded = decodeFunctionData({ abi: montionsBookAbi, data: encodeDepositWithPermit(1_000_000n, permit) });
    expect(decoded.functionName).toBe("depositWithPermit");
    expect(decoded.args).toEqual([1_000_000n, 123456n, 28, permit.r, permit.s]);
  });
});

describe("MontionsClient multicall reads", () => {
  it("routes cash reads through the canonical Multicall3 address", async () => {
    const requests: Array<{ method: string; params?: readonly unknown[] }> = [];
    const transport = custom({
      request: async ({ method, params }) => {
        requests.push({ method, params });
        if (method === "eth_call") {
          const call = (params as readonly [{ to: string; data: Hex }])[0];
          expect(call.to.toLowerCase()).toBe(MULTICALL3_ADDRESS.toLowerCase());
          const results = [111n, 22n].map((value) => ({
            success: true,
            returnData: encodeFunctionResult({ abi: [{ type: "function", name: "value", inputs: [], outputs: [{ type: "uint256" }] }] as const, functionName: "value", result: value }),
          }));
          return encodeAbiParameters([
            {
              type: "tuple[]",
              components: [
                { name: "success", type: "bool" },
                { name: "returnData", type: "bytes" },
              ],
            },
          ], [results]);
        }
        if (method === "eth_chainId") return "0x279f";
        throw new Error(`unexpected RPC method ${method}`);
      },
    });
    const publicClient = createPublicClient({ chain: monadTestnet, transport });
    const client = new MontionsClient({ publicClient, addresses: { book: BOOK, quoter: QUOTER, collateral: TOKEN } });
    const balances = await client.cashBalances("0x0000000000000000000000000000000000000001");
    expect(balances.free).toBe(111n);
    expect(balances.locked).toBe(22n);
    expect(requests.filter(({ method }) => method === "eth_call")).toHaveLength(1);
  });

  it("encodes nested Book multicall calls and keeps a local signer account", async () => {
    const account = privateKeyToAccount(`0x${"02".repeat(32)}`);
    const writes: Array<Record<string, unknown>> = [];
    const walletClient = {
      account,
      writeContract: async (parameters: Record<string, unknown>) => {
        writes.push(parameters);
        return `0x${"44".repeat(32)}` as Hex;
      },
    } as unknown as WalletClient;
    const publicClient = { chain: monadTestnet } as never;
    const client = new MontionsClient({ publicClient, walletClient, addresses: { book: BOOK, quoter: QUOTER, collateral: TOKEN } });
    const permit: PermitSignature = {
      owner: account.address,
      spender: BOOK,
      value: 1_000_000n,
      deadline: 2_000_000n,
      v: 27,
      r: `0x${"55".repeat(32)}`,
      s: `0x${"66".repeat(32)}`,
      signature: `0x${"00".repeat(65)}`,
    };
    await client.depositWithPermitAndPlaceOrder(1_000_000n, {
      seriesId: SERIES,
      side: "bid",
      tick: 35,
      qty: 1n,
      tif: "ioc",
    }, { permit });
    expect(writes).toHaveLength(1);
    expect(writes[0]?.account).toBe(account);
    const outerArgs = writes[0]?.args as readonly [readonly [Hex, Hex]];
    expect(outerArgs).toHaveLength(1);
    expect(outerArgs[0]).toHaveLength(2);
    expect(decodeFunctionData({ abi: montionsBookAbi, data: outerArgs[0][0] }).functionName).toBe("depositWithPermit");
    expect(decodeFunctionData({ abi: montionsBookAbi, data: outerArgs[0][1] }).functionName).toBe("placeOrder");
  });

  it("sends the nested Book multicall as one eth_sendTransaction", async () => {
    const account = "0x0000000000000000000000000000000000000003" as const;
    const requests: Array<{ method: string; params?: readonly unknown[] }> = [];
    const transport = custom({
      request: async ({ method, params }) => {
        requests.push({ method, params });
        if (method === "eth_chainId") return "0x279f";
        if (method === "eth_sendTransaction") return `0x${"77".repeat(32)}`;
        throw new Error(`unexpected wallet RPC method ${method}`);
      },
    });
    const walletClient = createWalletClient({ account, chain: monadTestnet, transport });
    const publicClient = createPublicClient({ chain: monadTestnet, transport });
    const client = new MontionsClient({ publicClient, walletClient, addresses: { book: BOOK, quoter: QUOTER, collateral: TOKEN } });
    const permit: PermitSignature = {
      owner: account,
      spender: BOOK,
      value: 1_000_000n,
      deadline: 2_000_000n,
      v: 27,
      r: `0x${"88".repeat(32)}`,
      s: `0x${"99".repeat(32)}`,
      signature: `0x${"00".repeat(65)}`,
    };
    const hash = await client.depositWithPermitAndPlaceOrder(1_000_000n, {
      seriesId: SERIES,
      side: "bid",
      tick: 35,
      qty: 1n,
      tif: "ioc",
    }, { permit });
    expect(hash).toBe(`0x${"77".repeat(32)}`);
    const request = requests.find(({ method }) => method === "eth_sendTransaction");
    expect(request).toBeDefined();
    const transaction = (request?.params as readonly [{ to: string; data: Hex }])[0];
    expect(transaction.to.toLowerCase()).toBe(BOOK);
    const decoded = decodeFunctionData({ abi: montionsBookAbi, data: transaction.data });
    expect(decoded.functionName).toBe("multicall");
    expect(decoded.args?.[0]).toHaveLength(2);
  });

  it("normalizes snapshots and batches outcome balances by their series ids", async () => {
    const calls: Array<{ functionName: string; args?: readonly unknown[] }> = [];
    const info = {
      resolver: "0x00000000000000000000000000000000000000a0",
      data: "0x",
      expiry: 1000n,
      status: 1,
      yes: false,
      yesId: 101n,
      noId: 202n,
      createdAt: 1n,
    };
    const publicClient = {
      chain: monadTestnet,
      readContract: async (parameters: { functionName: string; args?: readonly unknown[] }) => {
        calls.push(parameters);
        if (parameters.functionName === "seriesInfo") return info;
        if (parameters.functionName === "snapshots") return [{
          seriesId: SERIES,
          info,
          bidTick: 30,
          bidQty: 2n,
          askTick: 35,
          askQty: 3n,
          lastTick: 34,
          fairTick: 33,
          probWad: 330000000000000000n,
          volWad: 800000000000000000n,
          spotWad: 1000000000000000000n,
          title: "MON above $1",
        }];
        throw new Error(`unexpected read ${parameters.functionName}`);
      },
      multicall: async (parameters: { contracts: readonly { functionName: string; args?: readonly unknown[] }[] }) => {
        calls.push(...parameters.contracts);
        if (parameters.contracts[0]?.functionName === "balanceOf") return [5n, 7n, 11n, 13n];
        return [[{ tick: 35, qty: 3n }], [{ tick: 65, qty: 4n }]];
      },
    } as unknown as PublicClient;
    const client = new MontionsClient({ publicClient, addresses: { book: BOOK, quoter: QUOTER } });
    const snapshots = await client.snapshots(2, 3);
    expect(snapshots[0]?.info.yesId).toBe(101n);
    const positions = await client.positions(SERIES, "0x0000000000000000000000000000000000000001");
    expect(positions).toMatchObject({ yes: 5n, no: 7n, cash: 11n, lockedCash: 13n });
    expect(calls.find((call) => call.functionName === "balanceOf")?.args).toEqual([
      "0x0000000000000000000000000000000000000001",
      101n,
    ]);
    const book = await client.orderBookDepth(SERIES, 4);
    expect(book.bids[0]).toEqual({ tick: 35, qty: 3n });
    expect(book.asks[0]).toEqual({ tick: 65, qty: 4n });
  });
});

describe("permit domain", () => {
  it("signs Solady's versioned EIP-2612 domain", async () => {
    const account = privateKeyToAccount(`0x${"01".repeat(32)}`);
    const transport = custom({
      request: async ({ method }) => {
        if (method === "eth_call") {
          const results = [
            encodeFunctionResult({ abi: [{ type: "function", name: "name", inputs: [], outputs: [{ type: "string" }] }] as const, functionName: "name", result: "Test USDC" }),
            encodeFunctionResult({ abi: [{ type: "function", name: "value", inputs: [], outputs: [{ type: "uint256" }] }] as const, functionName: "value", result: 0n }),
          ];
          return encodeAbiParameters([
            {
              type: "tuple[]",
              components: [
                { name: "success", type: "bool" },
                { name: "returnData", type: "bytes" },
              ],
            },
          ], [results.map((returnData) => ({ success: true, returnData }))]);
        }
        if (method === "eth_chainId") return "0x279f";
        throw new Error(`unexpected RPC method ${method}`);
      },
    });
    const walletClient = createWalletClient({ account, chain: monadTestnet, transport });
    const publicClient = createPublicClient({ chain: monadTestnet, transport });
    const client = new MontionsClient({ publicClient, walletClient, addresses: { book: BOOK, quoter: QUOTER, collateral: TOKEN } });
    const permit = await client.signPermit({ amount: 1_000_000n, deadline: 2_000_000n });
    expect(permit.owner).toBe(account.address);
    expect(permit.v === 27 || permit.v === 28).toBe(true);
    expect(permit.signature).toMatch(/^0x[0-9a-f]{130}$/);
    const recovered = await recoverTypedDataAddress({
      domain: { name: "Test USDC", version: "1", chainId: 10143, verifyingContract: TOKEN },
      types: {
        Permit: [
          { name: "owner", type: "address" },
          { name: "spender", type: "address" },
          { name: "value", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      },
      primaryType: "Permit",
      message: {
        owner: permit.owner,
        spender: BOOK,
        value: permit.value,
        nonce: 0n,
        deadline: permit.deadline,
      },
      signature: permit.signature,
    });
    expect(recovered).toBe(account.address);
  });
});

describe("deployment validation", () => {
  it("normalizes addresses and bigint startBlock", () => {
    const parsed = parseDeployment({
      chainId: 10143,
      rpc: "https://testnet-rpc.monad.xyz",
      contracts: { Book: BOOK, Quoter: QUOTER },
      assets: [{ symbol: "MON", assetId: `0x${"aa".repeat(32)}`, pool: TOKEN, token: TOKEN, decimals: 18 }],
      startBlock: "42",
    });
    expect(parsed.chainId).toBe(10143);
    expect(parsed.startBlock).toBe(42n);
    expect(parsed.contracts.Book?.toLowerCase()).toBe(BOOK);
  });

  it("rejects malformed chain, URL, and decimal fields", () => {
    const valid = {
      chainId: 10143,
      rpc: "https://testnet-rpc.monad.xyz",
      contracts: { Book: BOOK },
      assets: [{ symbol: "MON", assetId: `0x${"aa".repeat(32)}`, pool: TOKEN, token: TOKEN, decimals: 18 }],
      startBlock: 42,
    };
    expect(() => parseDeployment({ ...valid, chainId: 0 })).toThrow(/chainId/);
    expect(() => parseDeployment({ ...valid, rpc: "deployments/10143.json" })).toThrow(/URL/);
    expect(() => parseDeployment({ ...valid, assets: [{ ...valid.assets[0], decimals: 256 }] })).toThrow(/uint8/);
  });

  it("rejects a deployment on a different chain before constructing RPC clients", () => {
    expect(() => new MontionsClient({
      deployment: {
        chainId: 1,
        rpc: "https://example.invalid",
        contracts: { Book: BOOK, Quoter: QUOTER },
        assets: [],
        startBlock: 0n,
      },
      addresses: { book: BOOK, quoter: QUOTER },
      chain: monadTestnet,
    })).toThrow(/does not match/);
  });

  it("rejects a permit whose value differs from the deposit", async () => {
    const account = privateKeyToAccount(`0x${"03".repeat(32)}`);
    const walletClient = {
      account,
      writeContract: async () => `0x${"aa".repeat(32)}` as Hex,
    } as unknown as WalletClient;
    const publicClient = { chain: monadTestnet } as never;
    const client = new MontionsClient({ publicClient, walletClient, addresses: { book: BOOK, quoter: QUOTER, collateral: TOKEN } });
    await expect(client.depositWithPermit(1_000_000n, {
      owner: account.address,
      spender: BOOK,
      value: 1n,
      deadline: 2_000_000n,
      v: 27,
      r: `0x${"11".repeat(32)}`,
      s: `0x${"22".repeat(32)}`,
      signature: `0x${"00".repeat(65)}`,
    })).rejects.toThrow(/value does not match/);
  });
});
