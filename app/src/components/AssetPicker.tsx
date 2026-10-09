import { useMemo, useState } from "react";
import type { Asset } from "../api/types";
import { price } from "../lib/format";

const GROUPS: { key: string; label: string }[] = [
  { key: "stock", label: "Stocks" }, { key: "crypto", label: "Crypto" }, { key: "major", label: "Majors" }, { key: "alt", label: "Alts" }, { key: "wrapped", label: "Wrapped & liquid-staked" }, { key: "", label: "Demo markets" },
];

/** Searchable, grouped asset list (the app supports dozens of assets). */
export function AssetPicker(props: { assets: Asset[]; current: string; onPick: (symbol: string) => void }) {
  const [q, setQ] = useState("");
  const groups = useMemo(() => {
    const needle = q.trim().toLowerCase();
    const match = (a: Asset) => !needle || a.symbol.toLowerCase().includes(needle) || a.name.toLowerCase().includes(needle);
    return GROUPS.map((g) => ({ ...g, items: props.assets.filter((a) => (a.tier ?? "") === g.key && match(a)).sort((x, y) => (y.liquid ?? 0) - (x.liquid ?? 0)) })).filter((g) => g.items.length);
  }, [props.assets, q]);
  return (
    <div style={{ minWidth: 300 }}>
      <input className="search" autoFocus placeholder={`Search ${props.assets.length} assets…`} value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search assets" />
      <div className="opt-list" style={{ maxHeight: 340 }}>
        {groups.length === 0 && <div className="subnote" style={{ padding: 12 }}>No asset matches “{q}”.</div>}
        {groups.map((g) => (
          <div key={g.key || "demo"}>
            <div className="grp">{g.label}</div>
            {g.items.map((a) => (
              <button key={a.symbol} className={`opt ${a.symbol === props.current ? "sel" : ""}`} onClick={() => props.onPick(a.symbol)}>
                <div><div className="l1">{a.symbol}{a.mock && <span className="tag soft" style={{ marginLeft: 8 }}>demo</span>}</div><div className="l2">{a.name}{a.liquid ? ` · ${a.liquid} quoted` : ""}</div></div>
                <span className="mono">{a.stale ? <span className="tag soft" title="Price feed is not updating right now">stale</span> : a.spot ? price(a.spot) : "—"}</span>
              </button>
            ))}
          </div>
        ))}
      </div>
    </div>
  );
}
