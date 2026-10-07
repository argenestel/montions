import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import type { Api } from "../api/types";

export const ApiCtx = createContext<Api>(null as unknown as Api);
export const useApi = () => useContext(ApiCtx);

/** Poll an async function; returns the latest value. */
export function usePoll<T>(fn: () => Promise<T>, deps: unknown[], ms = 4000): T | undefined {
  const [v, setV] = useState<T>();
  useEffect(() => {
    let alive = true;
    const run = async () => {
      try { const r = await fn(); if (alive) setV(r); } catch (e) { console.error(e); }
    };
    run();
    const t = setInterval(run, ms);
    return () => { alive = false; clearInterval(t); };
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
