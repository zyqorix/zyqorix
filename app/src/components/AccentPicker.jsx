import { Check } from "lucide-react";
import { ACCENTS } from "../lib/theme.js";

export function AccentPicker({ theme, size = "size-9" }) {
  return (
    <div className="flex flex-wrap gap-2.5">
      {Object.entries(ACCENTS).map(([name, hex]) => (
        <button
          key={name}
          type="button"
          aria-label={`${name} accent`}
          aria-pressed={theme.accent === name}
          onClick={() => theme.setAccent(name)}
          className={`grid ${size} place-items-center rounded-full ring-offset-2 ring-offset-surface transition active:scale-90${theme.accent === name ? " ring-2 ring-ink" : ""}`}
          style={{ background: hex }}
        >
          {theme.accent === name && <Check className="size-4 text-white" />}
        </button>
      ))}
    </div>
  );
}
