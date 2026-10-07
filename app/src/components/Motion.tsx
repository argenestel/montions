import { useEffect, useRef, useState } from "react";

const easeOut = (t: number) => 1 - Math.pow(1 - t, 3);

/** Tween a number toward `target`. First render shows the target immediately (no count-up from zero). */
export function useTween(target: number, ms = 380): number {
  const [v, setV] = useState(target);
  const from = useRef(target);
  const raf = useRef(0);
  useEffect(() => {
    if (typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) { setV(target); from.current = target; return; }
    const start = performance.now(), a = from.current, b = target;
    if (a === b) return;
    cancelAnimationFrame(raf.current);
    const step = (now: number) => {
      const t = Math.min(1, (now - start) / ms);
      const val = a + (b - a) * easeOut(t);
      from.current = val; setV(val);
      if (t < 1) raf.current = requestAnimationFrame(step);
    };
    raf.current = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf.current);
  }, [target, ms]);
  return v;
}

export function Num(props: { value: number; format: (n: number) => string; ms?: number }) {
  return <>{props.format(useTween(props.value, props.ms))}</>;
}

/** Returns "up" | "down" for ~700ms after the value changes (used for row flashes). */
export function useFlash(value: number): "up" | "down" | "" {
  const prev = useRef(value);
  const [dir, setDir] = useState<"up" | "down" | "">("");
  useEffect(() => {
    if (value === prev.current) return;
    setDir(value > prev.current ? "up" : "down");
    prev.current = value;
    const t = setTimeout(() => setDir(""), 700);
    return () => clearTimeout(t);
  }, [value]);
  return dir;
}

export function Skel(props: { w?: number | string; h?: number | string; r?: number; className?: string }) {
  return <span className={`skel ${props.className ?? ""}`} style={{ width: props.w ?? 72, height: props.h ?? "1em", borderRadius: props.r ?? 8 }} />;
}

/** Pulses a class briefly whenever `trigger` changes (block ticks etc.). */
export function useBlip(trigger: unknown, ms = 420): boolean {
  const [on, setOn] = useState(false);
  const first = useRef(true);
  useEffect(() => {
    if (first.current) { first.current = false; return; }
    setOn(true); const t = setTimeout(() => setOn(false), ms); return () => clearTimeout(t);
  }, [trigger, ms]);
  return on;
}
