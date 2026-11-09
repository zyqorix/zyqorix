import { Sparkles } from "lucide-react";
import { Link } from "react-router-dom";

/** Shown for any route that doesn't exist yet (the app's 404), worded as a feature on the way. */
export default function ComingSoon() {
  return (
    <section className="section">
      <div className="card card-body flex flex-col items-center py-10 text-center">
        <span className="icon-box icon-box-lg bg-brand text-white shadow-glow"><Sparkles className="size-6" /></span>
        <h2 className="mt-4 text-xl font-extrabold">Coming soon</h2>
        <p className="mt-1 max-w-xs text-[13.5px] text-muted">We're still building this part of ZYQORIX. Check back soon.</p>
        <Link to="/" className="btn btn-primary mt-5">Back to Home</Link>
      </div>
    </section>
  );
}
