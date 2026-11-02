import { Link2, UserRoundCheck, UsersRound } from "lucide-react";

export default function Network() {
  return (
    <>
      <section className="section">
        <div className="card">
          <div className="list">
            <div className="list-item"><span className="icon-box icon-box-sm"><UserRoundCheck className="size-5" /></span><span className="list-body"><span className="list-title block">Sponsor</span></span><span className="font-bold">—</span></div>
            <div className="list-item"><span className="icon-box icon-box-sm bg-sky-500/12 text-sky-500"><UsersRound className="size-5" /></span><span className="list-body"><span className="list-title block">Direct referrals</span></span><span className="font-bold">—</span></div>
            <div className="list-item"><span className="icon-box icon-box-sm bg-amber-500/12 text-amber-500"><Link2 className="size-5" /></span><span className="list-body"><span className="list-title block">Referral link</span><span className="list-sub block">Shown after you register</span></span></div>
          </div>
        </div>
      </section>
      <section className="section">
        <div className="section-head"><div><h2 className="section-title">Your referrals</h2></div></div>
        <div className="card card-body text-center">
          <UsersRound className="mx-auto size-8 text-muted" />
          <p className="mt-2 text-[14px] font-bold">No referrals yet</p>
          <p className="text-[13px] text-muted">People you sponsor will appear here.</p>
        </div>
      </section>
    </>
  );
}
