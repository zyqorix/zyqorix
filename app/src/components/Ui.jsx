import { createContext, useContext } from "react";

export const UiContext = createContext(null);
export const useUi = () => useContext(UiContext);

export function Sheet({ id, label, children }) {
  const { sheet } = useUi();
  const open = sheet === id;
  return (
    <div className={`sheet${open ? " is-open" : ""}`} role="dialog" aria-modal="true" aria-label={label} aria-hidden={!open} inert={!open}>
      <div className="sheet-grip" />
      {children}
    </div>
  );
}
