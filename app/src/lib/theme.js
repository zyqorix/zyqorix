import { useCallback, useEffect, useState } from "react";

export const ACCENTS = {
  violet: "#6d5efc", blue: "#2563eb", sky: "#0284c7", teal: "#0d9488", green: "#16a34a",
  amber: "#d97706", orange: "#ea580c", rose: "#e11d48", pink: "#db2777", graphite: "#334155",
};

const read = (key, fallback) => {
  try { return localStorage.getItem(key) ?? fallback; } catch { return fallback; }
};
const write = (key, value) => {
  try { localStorage.setItem(key, value); } catch { /* private window */ }
};

/** Light / Dark / Auto + accent pack, remembered per device (Lumen's theme runtime in React). */
export function useTheme() {
  const [mode, setModeState] = useState(() => read("zyqorix-theme", "auto"));
  const [accent, setAccentState] = useState(() => read("zyqorix-accent", "violet"));

  useEffect(() => {
    const mq = matchMedia("(prefers-color-scheme: dark)");
    const apply = () => document.documentElement.classList.toggle("dark", mode === "dark" || (mode === "auto" && mq.matches));
    apply();
    mq.addEventListener("change", apply);
    return () => mq.removeEventListener("change", apply);
  }, [mode]);

  useEffect(() => {
    document.documentElement.setAttribute("data-accent", accent);
  }, [accent]);

  const setMode = useCallback((v) => { write("zyqorix-theme", v); setModeState(v); }, []);
  const setAccent = useCallback((v) => { write("zyqorix-accent", v); setAccentState(v); }, []);
  const toggle = useCallback(() => {
    setMode(document.documentElement.classList.contains("dark") ? "light" : "dark");
  }, [setMode]);

  return { mode, accent, setMode, setAccent, toggle };
}
