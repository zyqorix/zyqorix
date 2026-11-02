import { AccentPicker } from "../components/AccentPicker.jsx";
import { useUi } from "../components/Ui.jsx";

const MODES = [["light", "Light"], ["dark", "Dark"], ["auto", "Auto"]];

export default function Account() {
  const { theme } = useUi();
  return (
    <>
      <section className="section">
        <div className="section-head"><div><h2 className="section-title">Appearance</h2></div></div>
        <div className="card card-body">
          <p className="label">Theme</p>
          <div className="tabs-pills">
            {MODES.map(([value, label]) => (
              <button key={value} type="button" className={theme.mode === value ? "is-active" : ""} aria-pressed={theme.mode === value} onClick={() => theme.setMode(value)}>{label}</button>
            ))}
          </div>
          <p className="label mt-5">Highlight color</p>
          <AccentPicker theme={theme} />
        </div>
      </section>
    </>
  );
}
