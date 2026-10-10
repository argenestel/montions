import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import type { Api } from "../api/types";

export const ApiCtx = createContext<Api>(null as unknown as Api);
export const useApi = () => useContext(ApiCtx);

/** Symbol of the collateral token for this deployment (USDC, AUSD, tUSDC …). */
export const CollateralCtx = createContext<string>("USDC");
export const useCollateral = () => useContext(CollateralCtx);

/** The primary action shown in the bottom dock ("Buy for $505 →"). The trade view registers it; the shell renders it. */
export type DockAction = { label: string; disabled?: boolean; onClick: () => void } | undefined;
export const DockCtx = createContext<(a: DockAction) => void>(() => {});
export function useDockAction(action: DockAction, deps: unknown[]) {
  const set = useContext(DockCtx);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { set(action); return () => set(undefined); }, deps);
}

/** Poll an async function; keeps the last good value on errors and backs off (x2, max 30s) while failing. */
export function usePoll<T>(fn: () => Promise<T>, deps: unknown[], ms = 4000): T | undefined {
  const [v, setV] = useState<T>();
  useEffect(() => {
    let alive = true, timer: ReturnType<typeof setTimeout>, fails = 0;
    const run = async () => {
      try { const r = await fn(); fails = 0; if (alive) setV(r); }
      catch (e) { fails++; if (fails === 1) console.error(e); }
      if (alive) timer = setTimeout(run, Math.min(30_000, ms * 2 ** Math.min(fails, 4)));
    };
    run();
    return () => { alive = false; clearTimeout(timer); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  return v;
}

export function useNow(ms = 1000): number {
  const [n, setN] = useState(Date.now() / 1000);
  useEffect(() => { const t = setInterval(() => setN(Date.now() / 1000), ms); return () => clearInterval(t); }, [ms]);
  return n;
}

/** A pill + anchored popover. Closes on outside click / Escape. */
export function PillPopover(props: {
  pill: (open: boolean, toggle: () => void) => ReactNode;
  children: (close: () => void) => ReactNode;
  align?: "left" | "right";
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (!open) return;
    const down = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false); };
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", down);
    document.addEventListener("keydown", key);
    return () => { document.removeEventListener("mousedown", down); document.removeEventListener("keydown", key); };
  }, [open]);
  return (
    <span className="pillwrap" ref={ref}>
      {props.pill(open, () => setOpen((o) => !o))}
      {open && <div className={`popover ${props.align === "right" ? "right" : ""}`}>{props.children(() => setOpen(false))}</div>}
    </span>
  );
}

/** Deterministic two-tone gradient from an address, for avatars. */
export function avatarStyle(address?: string) {
  const h = address ? parseInt(address.slice(2, 8), 16) : 0;
  const a = h % 360, b = (a + 70 + ((h >> 8) % 120)) % 360;
  return { background: `linear-gradient(135deg, hsl(${a} 80% 70%), hsl(${b} 85% 55%))` };
}
