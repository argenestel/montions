import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { createPublicClient, custom, decodeFunctionData, encodeFunctionResult, multicall3Abi, type Address, type Hex } from 'viem';
import { montionsBookAbi, quoterAbi } from '../src/abi/index.js';
import { MULTICALL3_ADDRESS, monadTestnet } from '../src/chain.js';
import { MontionsClient } from '../src/client.js';
import { loadDeployments } from '../src/deployments-node.js';

const BOOK = '0x0000000000000000000000000000000000000011' as const;
const QUOTER = '0x0000000000000000000000000000000000000022' as const;
const USER = '0x0000000000000000000000000000000000000033' as const;
const SERIES = `0x${'ab'.repeat(32)}` as Hex;
const info = { resolver: QUOTER, data: '0x' as Hex, expiry: 1_800_000_000n,
  status: 1, yes: false, yesId: 987n, noId: 654n, createdAt: 1_700_000_000n };
const snapshot = { seriesId: SERIES, info, bidTick: 35, bidQty: 6n,
  askTick: 40, askQty: 8n, lastTick: 37, fairTick: 38, probWad: 380_000_000_000_000_000n,
  volWad: 800_000_000_000_000_000n, spotWad: 1_000_000_000_000_000_000n, title: 'DEMO MON above $1' };

function fixtureClient() {
  const calls: Array<{ address: Address; functionName: string; args: readonly unknown[] }> = [];
  const requests: string[] = [];
  const respond = (address: Address, data: Hex): Hex => {
    if (address.toLowerCase() === QUOTER.toLowerCase()) {
      const decoded = decodeFunctionData({ abi: quoterAbi, data });
      calls.push({ address, functionName: decoded.functionName, args: decoded.args ?? [] });
      if (decoded.functionName === 'snapshots') {
        return encodeFunctionResult({ abi: quoterAbi, functionName: 'snapshots', result: [snapshot] });
      }
      throw new Error('unexpected quoter read');
    }
    expect(address.toLowerCase()).toBe(BOOK.toLowerCase());
    const decoded = decodeFunctionData({ abi: montionsBookAbi, data });
    calls.push({ address, functionName: decoded.functionName, args: decoded.args ?? [] });
    switch (decoded.functionName) {
      case 'seriesInfo': return encodeFunctionResult({ abi: montionsBookAbi, functionName: 'seriesInfo', result: info });
      case 'balanceOf': {
        expect(decoded.args[0]).toBe(USER);
        expect([987n, 654n]).toContain(decoded.args[1]);
        return encodeFunctionResult({ abi: montionsBookAbi, functionName: 'balanceOf', result: decoded.args[1] === 987n ? 12n : 34n });
      }
      case 'cash': return encodeFunctionResult({ abi: montionsBookAbi, functionName: 'cash', result: 1_234_567n });
      case 'lockedCash': return encodeFunctionResult({ abi: montionsBookAbi, functionName: 'lockedCash', result: 123n });
      case 'depth': return encodeFunctionResult({ abi: montionsBookAbi, functionName: 'depth', result: decoded.args[1] === 0 ? [{ tick: 35, qty: 6n }] : [{ tick: 40, qty: 8n }] });
      case 'ordersOf': return encodeFunctionResult({ abi: montionsBookAbi, functionName: 'ordersOf', result: [{ id: 9n, maker: USER, seriesId: SERIES, side: 0, tick: 35, fromHeld: false, qty: 3n, origQty: 4n, placedAt: 1_700_000_000n, open: true }] });
      default: throw new Error(`unexpected book read: ${decoded.functionName}`);
    }
  };
  const transport = custom({ request: async ({ method, params }) => {
    requests.push(method);
    if (method !== 'eth_call') throw new Error(`unexpected RPC method: ${method}`);
    const call = (params as readonly [{ to: Address; data: Hex }])[0];
    if (call.to.toLowerCase() !== MULTICALL3_ADDRESS.toLowerCase()) return respond(call.to, call.data);
    const decoded = decodeFunctionData({ abi: multicall3Abi, data: call.data });
    if (decoded.functionName !== 'aggregate3') throw new Error('expected aggregate3');
    return encodeFunctionResult({ abi: multicall3Abi, functionName: 'aggregate3', result: decoded.args[0].map(item => {
      return { success: true, returnData: respond(item.target, item.callData) };
    }) });
  } });
  return { calls, requests, client: new MontionsClient({ addresses: { book: BOOK, quoter: QUOTER }, publicClient: createPublicClient({ chain: monadTestnet, transport }) }) };
}

describe('contract views without log scanning', () => {
  it('reads paginated snapshots and orders from the frozen views', async () => {
    const { client, calls, requests } = fixtureClient();
    expect(await client.snapshots(2, 10)).toEqual([snapshot]);
    expect((await client.orders(USER, 3, 5))[0]).toMatchObject({ id: 9n, maker: USER, qty: 3n });
    expect(calls.map(call => [call.functionName, call.args])).toEqual([['snapshots', [2n, 10n]], ['ordersOf', [USER, 3n, 5n]]]);
    expect(requests.every(method => method === 'eth_call')).toBe(true);
  });

  it('uses series token IDs and batches balances and both depth sides', async () => {
    const { client, calls, requests } = fixtureClient();
    expect(await client.positions(SERIES, USER)).toEqual({ seriesId: SERIES, owner: USER, yes: 12n, no: 34n, cash: 1_234_567n, lockedCash: 123n });
    expect(await client.orderBookDepth(SERIES)).toEqual({ bids: [{ tick: 35, qty: 6n }], asks: [{ tick: 40, qty: 8n }] });
    expect(calls.filter(call => call.functionName === 'balanceOf').map(call => call.args)).toEqual([[USER, 987n], [USER, 654n]]);
    expect(requests).toHaveLength(3); // seriesInfo + balance aggregate + depth aggregate
  });
});

describe('deployment file loader', () => {
  it('loads a SPEC 10 manifest and reports invalid JSON and traversal', () => {
    const directory = mkdtempSync(join(dirname(fileURLToPath(import.meta.url)), '.deployment-'));
    try {
      writeFileSync(join(directory, '10143.json'), JSON.stringify({ chainId: 10143, rpc: 'https://testnet-rpc.monad.xyz', contracts: { MontionsBook: BOOK, Quoter: QUOTER }, assets: [], startBlock: '9007199254740993' }));
      const loaded = loadDeployments(10143, directory);
      expect(loaded.startBlock).toBe(9_007_199_254_740_993n);
      expect(new MontionsClient({ deployment: loaded }).addresses.book).toBe(BOOK);
      writeFileSync(join(directory, 'broken.json'), '{');
      expect(() => loadDeployments('broken', directory)).toThrow(/parse/);
      expect(() => loadDeployments('../10143', directory)).toThrow(/path segment/);
      expect(() => loadDeployments('missing', directory)).toThrow(/read/);
    } finally {
      rmSync(directory, { recursive: true });
    }
  });
});
