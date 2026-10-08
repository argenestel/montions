#!/usr/bin/env python3
"""Builds and verifies config/pyth-feeds.json: every Pyth price feed pushed on Monad mainnet (source: monad-crypto/protocols mainnet/pyth.jsonc),
classified for options markets, then verified LIVE (exists, price > 0, fresh, tight confidence) with read-only eth_calls.
Usage: python3 scripts/feeds.py [--no-verify]"""
import json, subprocess, sys, time, re, os
RPC = os.environ.get("MAINNET_RPC", "https://rpc.monad.xyz"); PYTH = "0x2880aB155794e7179c9eE2e38200202908C17B43"
RAW = """BTC/USD e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
ETH/USD ff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace
MON/USD 31491744e2dbf6df7fcf4ac0820d18a609b49076d45066d3568424e62f686cd1
SOL/USD ef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d
AAVE/USD 2b9ab1e972a281585084148ba1389800799bd4be63b957507db1349314e47445
ADA/USD 2a01deaec9e51a579277b34b122399984d0bbf57e2458a7e42fecd2829867a0d
APT/USD 03ae4db29ed4ae33d323568895aa00337e658e348b37509f5372ae51f0af00d5
ARB/USD 3fa4252848f9f0a1480be62745a4629d9eb1322aebab8a791e344b3b9c1adcf5
AUSD/USD d9912df360b5b7f21a122f15bdd5e27f62ce5e72bd316c291f7c86620e07fb2a
AVAX/USD 93da3352f9f1d105fdfe4971cfa80e9dd777bfc5d0f683ebb6e1294b92137bb7
AXL/USD 60144b1d5c9e9851732ad1d9760e3485ef80be39b984f6bf60f82b28a2b7f126
BERA/USD 962088abcfdbdb6e30db2e340c8cf887d9efb311b1f2f17b155a63dbb6d40265
BNB/USD 2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f
CAKE/USD 2356af9529a1064d41e32d617e2ce1dca5733afa901daba9e2b68dee5d53ecf9
CBBTC/USD 2817d7bfe5c64b8ea956e9a26f573ef64e72e4d7891f2d6af9bcc93f7aff9a97
DAI/USD b0948a5e5313200c632b51bb5ca32f6de0d36e9950a942d19751e833f70dabfd
DOGE/USD dcef50dd0a4cd2dcc17e45df1676dcb336a11a61c69df7a0299b0150c672d25c
EBTC/USD be3dd0cf4a168f82e4912952b24420211ad52641b7365d49866d59e20c948288
ETHX/ETH_RR 1b8eb073e2a900cdf1f6ee37ddab4869a4400499ec6e52f3e268a93f46c55429
EZETH/USD 06c217a791f5c4f988b36629af4cb88fad827b2485400a358f3b02886b54de92
FDUSD/USD ccdc1a08923e2e4f4b1e6ea89de6acbc5fe1948e9706f5604b8cb50bc1ed3979
HYPE/USD 4279e31cc369bbcc2faf022b382b080e32a8e689ff20fbc530d2a603eb6cd98b
LBTC/USD 8f257aab6e7698bb92b15511915e593d6f8eae914452f781874754b03d0c612b
LINK/USD 8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221
OP/USD 385f64d993f7b77d8182ed5003d97c60aa3361f3cecfe711544d2d59165e9bdf
POL/USD ffd11c5a1cfd42f80afb2df4d9f264c15f956d68153335374ec10722edd70472
PYTH/USD 0bbf28e9a841a1cc788f6a361b17ca072d0ea3098a1e5df1c3922d06719579ff
PYUSD/USD c1da1b73d7f01e7ddd54b3766cf7fcd644395ad14f70aa706ec5384c59e76692
RED/USD 0bb28b82f08477fadbf9607fc8408ff61ca129fae40adc7a8d2ab8945f97ee74
RSETH/ETH_RR 56e9b5eb08e62dd4b445f29e4ec7d3b3d49617d64f2d331d36a2101d4904e3c4
RSETH/USD 0caec284d34d836ca325cf7b3256c078c597bc052fbd3c0283d52b581d68d71f
S/USD f490b178d0c85683b7a0f2388b40af2e6f7c90cbe0f96b31f315f08d0e5a2d6d
SEI/USD 53614f1cb0c031d4af66c04cb9c756234adad0e1cee85303795091499a4084eb
SMON/MON_RR 7fbf66b9b4e8b0e5723fc7001b00848c7d25225982ab33f6a5d111fdbf528001
SOLVBTC/USD f253cf87dc7d5ed5aa14cba5a6e79aee8bcfaef885a0e1b807035a0bbecc36fa
STETH/ETH_RR cf40822c7635ddbde64c831982c65b3b37247f139e8e53078d1602e886badd2f
STG/USD 008546b175392b878c5c7ff0b6327b1cb12669be012fc2935c09a16fc8f6c58f
STONE/ETH_RR 7a508a94c9276cbc60d04e1a8cf839d20d835bb869a74487dfffa8f1bfd1ce42
SUI/USD 23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744
SUSDE/USD ca3ba9a619a4b3755c10ac7d5e760275aa95e9823d38a84fedd416856cdba37c
SUSDE/USDE_RR 271c64ce459937abf721d42552035713b6c58f80eeceab716a624607fda4b10f
SUSDS/USDS_RR 6968a8641208463d17ae3b9cfa0e4841a7aa7a5d54122b9f692b84fe9ce3409f
TIA/USD 09f7c1d7dfbb7df2b8fe3d3d87ee94a2259d212da4f30c1f0540d066dfa44723
UNI/USD 78d185a741d07edb3412b09008b7c5cfb9bbbd7d568bf00ba737b456ba171501
USDC/USD eaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a
USDE/USD 6ec879b1e9963de5ee97e9c8710b742d6228252a5e2ca12d4ae81d7fe5ee8c5d
USDS/USD 77f0971af11cc8bac224917275c1bf55f2319ed5c654a1ca955c82fa2d297ea1
USDT/USD 2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b
USDY/USD e393449f6aff8a4b6d3e1165a7c9ebec103685f3b41e60db4277b5b6d10e7326
W/USD eff7446475e218517566ea99e72a4abec2e1bd8498b43b7d8331e29dcb059389
WBTC/USD c9d8b075a5c69303365ae23633d4e085199bf5c520a3b90fed1322a0342ffc33
WEETH/EETH_RR 343558e79f587e098c321218ecb34d031ba709ab3e84133126f3c98511b91f64
WEETH/USD 9ee4e7c60b940440a261eb54b6d8149c23b580ed7da3139f7f08f4ea29dad395
WETH/USD 9d4294bbcd1174d6f2003ec365831e64cc31d9f6f15a2b85399db8d5000960f6
WSTETH/STETH_RR f59ead01ed0faba85332a1e2feae8ddb14a1c94ebac259f1c982c92fc7ce333e
WSTETH/USD 6df640f3b8963d8f8358f791f352b8364513f6ab1cca5ed3f1f7b5448980e784
XAG/USD f2fb02c32b055c805e7238d628e5e9dadef274376114eb1f012337cabe93871e
XAU/USD 765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2
XRP/USD ec5d399846a9209f3fe5881d70aae9268c94339ff9817e8d18ff19fa05eea1c8
ZRO/USD 3bd860bea28bf982fa06bcf358118064bb114086cc03993bd76197eaab0b8018"""
MAJOR = {"BTC":0.55,"ETH":0.70,"SOL":0.90,"MON":1.20,"BNB":0.60,"XRP":0.90,"DOGE":1.10,"ADA":1.00,"AVAX":1.00,"LINK":0.90,"SUI":1.20,"HYPE":1.30}
ALT = {"AAVE":1.0,"APT":1.1,"ARB":1.1,"AXL":1.2,"BERA":1.4,"CAKE":1.1,"OP":1.1,"POL":1.1,"PYTH":1.3,"RED":1.4,"S":1.2,"SEI":1.3,"STG":1.2,"TIA":1.2,"UNI":1.0,"W":1.3,"ZRO":1.3}
WRAPPED = {"WBTC":0.55,"CBBTC":0.55,"LBTC":0.55,"EBTC":0.55,"SOLVBTC":0.55,"WETH":0.70,"WSTETH":0.70,"WEETH":0.72,"EZETH":0.72,"RSETH":0.72}
STABLE = {"USDC","USDT","DAI","USDE","USDS","PYUSD","AUSD","FDUSD","USDY","SUSDE"}
METAL = {"XAU":0.18,"XAG":0.35}
feeds = []
for line in RAW.splitlines():
    pair, fid = line.split(); sym, quote = pair.split("/")
    f = {"symbol": sym, "pair": pair, "feedId": "0x" + fid, "heartbeatSec": 3600}
    if quote.endswith("_RR"): f.update(category="exchange-rate", tier="n/a", enabled=False, reason="ratio feed (not a USD price); different semantics")
    elif sym in STABLE: f.update(category="stablecoin", tier="n/a", enabled=False, reason="stablecoin: depeg markets need a different volatility model than the fixed-vol digital pricer")
    elif sym in METAL: f.update(category="metal", tier="session", volWad=METAL[sym], enabled=False, reason="market-hours feed: an expiry inside a closure cannot settle (first price after expiry may be past the 300s window) and would void; needs session-aware expiries")
    elif sym in MAJOR: f.update(category="crypto", tier="major", volWad=MAJOR[sym], enabled=True)
    elif sym in ALT: f.update(category="crypto", tier="alt", volWad=ALT[sym], enabled=True)
    elif sym in WRAPPED: f.update(category="crypto", tier="wrapped", volWad=WRAPPED[sym], enabled=True)
    else: f.update(category="crypto", tier="alt", volWad=1.2, enabled=True)
    feeds.append(f)
RPCS = [RPC, "https://rpc1.monad.xyz", "https://rpc-mainnet.monadinfra.com"]
def call(sig, *args):
    for attempt in range(6):                      # public RPCs rate-limit; retry across providers with backoff
        try:
            r = subprocess.run(["cast","call",PYTH,sig,*args,"--rpc-url",RPCS[attempt % len(RPCS)]],capture_output=True,text=True,timeout=25)
            if r.returncode == 0 and r.stdout.strip(): return r.stdout.strip()
        except subprocess.TimeoutExpired: pass
        time.sleep(0.5 * (attempt + 1))
    return ""
if "--no-verify" not in sys.argv:
    now = int(time.time()); bad = 0
    for f in feeds:
        ex = call("priceFeedExists(bytes32)(bool)", f["feedId"]) == "true"
        out = call("getPriceUnsafe(bytes32)((int64,uint64,int32,uint256))", f["feedId"]) if ex else ""
        nums = re.findall(r"-?\d+", out.replace("[", " [").split("[")[0] if False else out)
        # cast prints e.g. "(2596750 [2.596e6], 752, -8, 1791387446 [1.791e9])" -> strip bracketed sci-notation first
        clean = re.sub(r"\[[^\]]*\]", "", out); nums = re.findall(r"-?\d+", clean)
        live = {"exists": ex}
        if ex and len(nums) >= 4:
            price, conf, expo, pt = int(nums[0]), int(nums[1]), int(nums[2]), int(nums[3])
            live.update(price=price*10**expo, conf_bps=round(conf*10000/price,1) if price>0 else None, expo=expo, ageSec=max(0, int(time.time())-pt))
        f["live"] = live
        if f["enabled"]:
            why = None
            if not ex or live.get("price", 0) <= 0: why = "feed missing or non-positive price"
            elif (live.get("ageSec") or 0) > 2 * f["heartbeatSec"]: why = f"STALE: last update {live['ageSec']//86400}d ago (heartbeat is {f['heartbeatSec']}s) — nobody is pushing this feed"
            elif (live.get("conf_bps") or 0) > 200: why = "confidence interval wider than 2% of price"
            if why: f["enabled"] = False; f["reason"] = why; bad += 1
    print(f"verified {len(feeds)} feeds on {RPC}; enabled={sum(f['enabled'] for f in feeds)} disabled={sum(not f['enabled'] for f in feeds)} failed-live={bad}")
for f in feeds:
    if "volWad" in f: f["vol"] = f["volWad"]; f["volWad"] = int(round(f["volWad"] * 1000)) * 10**15   # integer for on-chain use; keep float as "vol" for display
json.dump({"chainId":143,"pyth":PYTH,"source":"monad-crypto/protocols mainnet/pyth.jsonc","verifiedAt":int(time.time()),"maxAgeSec":3900,"feeds":feeds}, open("config/pyth-feeds.json","w"), indent=2); open("config/pyth-feeds.json","a").write("\n")
for f in feeds:
    if not f["enabled"] and f.get("live") and f["category"] == "crypto": print(f"  DISABLED {f['symbol']:7s} {f['reason'][:110]}")
for f in feeds:
    if f["enabled"]: print(f"  ENABLED  {f['symbol']:7s} {f['tier']:8s} vol={f['vol']:.2f}  price={f.get('live',{}).get('price')}  age={f.get('live',{}).get('ageSec')}s  conf={f.get('live',{}).get('conf_bps')}bps")
