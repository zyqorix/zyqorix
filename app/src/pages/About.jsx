import {
  ArrowDownToLine, ArrowUpFromLine, BadgeCheck, CalendarClock, Crown, Gift, Hourglass, Layers, Network, Sparkles, TrendingUp, Users,
} from "lucide-react";
import { Link, NavLink, Outlet } from "react-router-dom";

const TABS = [
  { to: "/about", label: "About" },
  { to: "/about/rewardsplan", label: "Rewards plan" },
  { to: "/about/faq", label: "FAQ" },
];

const TIERS = [
  { usd: 50, cap: "3x · 150", unlock: "At registration" },
  { usd: 100, cap: "3x · 300", unlock: "At registration" },
  { usd: 200, cap: "3x · 600", unlock: "60 days, or $50 and $100 both capped" },
  { usd: 400, cap: "3x · 1,200", unlock: "60 days, or $50 and $100 both capped" },
  { usd: 800, cap: "3x · 2,400", unlock: "120 days, or $200 and $400 both capped" },
  { usd: 1600, cap: "2x · 3,200", unlock: "120 days, or $200 and $400 both capped" },
];

/** The About section: the story, the rewards plan and the FAQ, each on its own route under /about. */
export function AboutLayout() {
  return (
    <>
      <section className="section pb-0">
        <div className="tabs-pills">
          {TABS.map((t) => (
            <NavLink key={t.to} to={t.to} end className={({ isActive }) => `chip shrink-0${isActive ? " is-active" : ""}`}>{t.label}</NavLink>
          ))}
        </div>
      </section>
      <Outlet />
    </>
  );
}

function Card({ title, children }) {
  return (
    <div className="card card-body mt-3 first:mt-0">
      {title && <h3 className="text-[15px] font-extrabold">{title}</h3>}
      <div className="mt-2 space-y-3 text-[13.5px] leading-relaxed text-muted">{children}</div>
    </div>
  );
}

const Strong = ({ children }) => <strong className="font-bold text-ink">{children}</strong>;

export function AboutStory() {
  return (
    <section className="section">
      <div className="card card-gradient card-body">
        <p className="eyebrow text-on-brand/75">The Market Hunting Network</p>
        <h2 className="mt-2 text-2xl font-black leading-tight">From Human Instinct to Artificial Intelligence.</h2>
        <p className="mt-2 text-[13.5px] italic opacity-85">Scan the market. Learn its patterns. Train the intelligence. Signal the move.</p>
      </div>

      <div className="mt-3">
        <Card title="The Story of a Trader Who Refused to Stop Learning">
          <p>Every great trader begins with a question: <Strong>“How does the market really work?”</Strong></p>
          <p>At first, there was only a man, a chart, and the determination to understand the market.</p>
          <p>He studied candlesticks. He watched prices rise and fall. He learned support and resistance, tracked volume, examined trends, and searched for the patterns hidden behind every movement.</p>
          <p>He made mistakes. He experienced losses. He questioned his decisions and returned to the charts, determined to understand what he had missed.</p>
          <p>Every loss became a lesson. Every winning trade revealed another piece of the puzzle. Slowly, he developed something no textbook could give him alone: experience.</p>
          <p>He began to recognize market behavior. He learned to distinguish meaningful movements from random noise, to identify potential breakouts, and to recognize the warning signs of a reversal.</p>
          <p>He was no longer simply looking at charts. <Strong>He was learning to read the language of the market.</Strong></p>
          <p>But experience also revealed a hard truth.</p>
          <p>The market never sleeps for long. Opportunities can emerge in seconds. Patterns appear across thousands of charts, timeframes, trading pairs, and market conditions. Even the most experienced trader has limits.</p>
          <p>Human attention is finite. Emotions interfere. Fatigue clouds judgment. And a pattern recognized today might behave differently tomorrow.</p>
          <p>He had learned how to hunt. Now, he needed a better way to see.</p>
        </Card>

        <Card title="Then Came Artificial Intelligence">
          <p>The next chapter began with a different question: <Strong>“What if I could teach a machine to see what I have spent years learning to recognize?”</Strong></p>
          <p>He turned to artificial intelligence. Not to replace his judgment. Not to hand over his money to a machine and hope for the best. He wanted to give his experience a new form.</p>
          <p>He began training AI to analyze historical price movements, examine market conditions, identify recurring patterns, and test the strategies he had developed through years of manual trading.</p>
          <p>He fed the system data. He defined rules. He challenged its assumptions. Then he simulated.</p>
          <p>Thousands of scenarios. Different market conditions. Trending markets, sideways markets, sudden surges, sharp reversals, and unexpected crashes.</p>
          <p>Strategies were tested. Weaknesses were exposed. Parameters were adjusted. Failed approaches were discarded. Better models were tested again.</p>
          <p>Every result raised a new question. Every failed simulation offered another lesson.</p>
          <p>The goal was not to build a machine that could predict everything. The goal was to discover which patterns held up under rigorous testing, which strategies survived changing conditions, and which signals deserved attention.</p>
          <p><Strong>Human experience provided the questions. Mathematics provided the tests. AI expanded the search.</Strong></p>
          <p>Together, they began turning instinct into measurable rules, observations into data, and strategies into systems that could be evaluated rather than merely believed.</p>
        </Card>

        <Card title="Searching for the Code Behind the Market">
          <p>The deeper he went, the more he understood that the market was not a simple puzzle with one secret answer.</p>
          <p>It was a constantly changing system shaped by liquidity, psychology, momentum, news, uncertainty, and the decisions of countless participants.</p>
          <p>There would be no magical formula that won every trade. But there could be something more valuable: a disciplined process for finding an edge.</p>
          <p>A strategy had to prove itself against historical data. It had to account for fees, slippage, drawdowns, and the danger of fitting a model too closely to past results. It had to be tested beyond the conditions in which it was created.</p>
          <p>The objective was to push the analysis further, test more possibilities, recognize meaningful changes sooner, and respond with greater discipline.</p>
          <p>The machine could process the patterns. The mathematics could challenge the assumptions. The trader could provide direction, judgment, and responsibility.</p>
          <p>And together, they could become better prepared for the uncertainty of the market.</p>
          <p>The code was never about controlling the market. <Strong>It was about understanding the odds.</Strong></p>
        </Card>

        <Card title="The Birth of Zyqorix">
          <p>From this evolution came an idea: what if the intelligence built through experience, analysis, and experimentation could become a network that helps other traders see market movements more clearly?</p>
          <p>What if significant surges, sudden drops, unusual activity, and emerging patterns could be detected and delivered as timely signals to a community of traders?</p>
          <p>That idea became <Strong>Zyqorix — The Market Hunting Network.</Strong></p>
          <p>Zyqorix represents the evolution from staring at charts to systematically analyzing them; from relying on instinct alone to combining human insight with AI-assisted intelligence; from hunting for opportunities individually to sharing signals with a community.</p>
          <p>The mission is simple: scan the market, identify movements worth investigating, and deliver useful information so traders can make more informed decisions.</p>
          <p>Not blind copying. Not promises of guaranteed profits. Not the illusion that every market move can be predicted.</p>
          <p>A smarter way to observe. A more disciplined way to analyze. A faster way to become aware.</p>
          <p>Because the advantage is not simply seeing a price move. It is understanding what the signal might mean, recognizing its limitations, and deciding what to do next.</p>
        </Card>

        <Card title="The Next Generation of Traders">
          <p>The journey began with one man learning to read a chart. It evolved into a trader teaching a machine to test what experience had taught him.</p>
          <p>Now, the vision reaches beyond one trader.</p>
          <p>Zyqorix is built on the belief that the future belongs to those willing to keep learning, embrace better tools, challenge their assumptions, and adapt when the market changes.</p>
          <p>Human wisdom gave the hunt its direction. Artificial intelligence expanded its vision. Mathematics brought discipline to its strategies. And the network made the signals shareable.</p>
          <p><Strong>This is more than the evolution of a trader. It is the evolution of the way traders hunt for opportunity.</Strong></p>
        </Card>
      </div>

      <div className="card card-body mt-3 text-center">
        <p className="eyebrow">Zyqorix · The Market Hunting Network</p>
        <p className="mt-2 text-[16px] font-extrabold">Scan the market. Lock on the move. Signal the pack.</p>
        <p className="mt-1 text-[12.5px] text-muted">Human wisdom. AI intelligence. Mathematical precision.</p>
        <p className="mt-3 text-[13px] font-bold">The market keeps moving. We keep learning.</p>
        <Link to="/about/rewardsplan" className="btn btn-primary mt-4">See the rewards plan</Link>
      </div>
    </section>
  );
}

function Step({ n, icon: Icon, title, children }) {
  return (
    <div className="flex gap-3 border-b border-line py-3 first:pt-0 last:border-0 last:pb-0">
      <span className="icon-box icon-box-sm shrink-0 bg-brand text-white"><Icon className="size-4" /></span>
      <div className="min-w-0">
        <p className="text-[14px] font-bold">{n}. {title}</p>
        <div className="mt-0.5 space-y-1.5 text-[12.5px] leading-relaxed text-muted">{children}</div>
      </div>
    </div>
  );
}

function Income({ n, icon: Icon, title, rate, children }) {
  return (
    <div className="card card-body">
      <div className="flex items-center gap-3">
        <span className="icon-box icon-box-sm shrink-0 bg-brand text-white"><Icon className="size-4" /></span>
        <p className="min-w-0 flex-1 text-[14.5px] font-extrabold">{n}) {title}</p>
        <span className="chip chip-soft shrink-0">{rate}</span>
      </div>
      <div className="mt-3 space-y-2 text-[13px] leading-relaxed text-muted">{children}</div>
    </div>
  );
}

export function RewardsPlan() {
  return (
    <section className="section">
      <div className="section-head">
        <div>
          <h2 className="section-title">Rewards plan</h2>
          <p className="section-sub">How a member earns, from the first deposit to the first withdrawal.</p>
        </div>
      </div>

      <div className="card card-body">
        <Step n={1} icon={ArrowDownToLine} title="Register and deposit">
          <p>Sign up under a sponsor and deposit USDT (BEP-20) into your ZYQORIX wallet. The minimum deposit is 50 USDT.</p>
        </Step>
        <Step n={2} icon={Layers} title="Activate a tier">
          <p>Use your wallet balance to activate a tier. Tiers open in order, $50 first, and each one opens once. The $1,600 tier can be activated again whenever its capping runs out.</p>
          <p>Each tier gives you a <Strong>capping</Strong>: the most it can earn. It is 3x the tier, or 2x for $1,600.</p>
          <p>Every activation also gives you ZQR tokens of the same value, released monthly in vesting mode.</p>
        </Step>
        <Step n={3} icon={TrendingUp} title="Earn rewards">
          <p>Your active tiers earn referral, daily, generation and leadership rewards, explained below. Earnings use your oldest tier's capping first; a tier stops earning when its capping reaches zero.</p>
        </Step>
        <Step n={4} icon={Gift} title="Collect your rewards">
          <p>On the Rewards page, collect daily rewards once every 24 hours, and collect generation and leadership rewards when they are available. Collected rewards land in your wallet balance.</p>
        </Step>
        <Step n={5} icon={ArrowUpFromLine} title="Withdraw or reactivate">
          <p>Withdraw from your wallet balance in amounts of 20, 40, 60, 80 or 100 USDT, once every 24 hours, with a 10% fee. Or use the balance to activate your next tier.</p>
        </Step>
      </div>

      <div className="card card-body mt-3">
        <p className="eyebrow">Tiers</p>
        <div className="mt-2">
          {TIERS.map((t) => (
            <div key={t.usd} className="flex items-start justify-between gap-3 border-b border-line py-2 last:border-0">
              <div className="min-w-0">
                <p className="text-[13.5px] font-bold">${t.usd.toLocaleString()}</p>
                <p className="text-[11.5px] text-muted">{t.unlock}</p>
              </div>
              <p className="shrink-0 text-right text-[13px] font-extrabold">{t.cap} USDT</p>
            </div>
          ))}
        </div>
      </div>

      <div className="section-head mt-6">
        <div>
          <h2 className="section-title">Four ways to earn</h2>
          <p className="section-sub">All of them need an active tier with capping left.</p>
        </div>
      </div>

      <div className="space-y-3">
        <Income n={1} icon={Users} title="Referral" rate="5–10%">
          <p>When a member you sponsored directly activates a tier, you earn a share of it.</p>
          <p><Strong>5%</Strong> on your first five active directs. From your <Strong>sixth active direct</Strong> onward, you earn <Strong>10%</Strong>.</p>
        </Income>
        <Income n={2} icon={CalendarClock} title="Daily" rate="1% passive">
          <p>Every active tier earns <Strong>1% of its value each day</Strong>. Collect it once every 24 hours.</p>
          <p>Example: a $100 tier earns 1 USDT a day until its 300 USDT capping is used up.</p>
        </Income>
        <Income n={3} icon={Network} title="Generation income" rate="10% · 10 levels">
          <p>Each time a member in your <Strong>1st to 10th level</Strong> collects a daily reward, you earn <Strong>10% of it</Strong>.</p>
          <p>Example: a member on your 4th level collects 2 USDT, so you earn 0.20 USDT.</p>
        </Income>
        <Income n={4} icon={Crown} title="Leadership pool bonus" rate="5%">
          <p><Strong>5% of every activation</Strong> goes into a monthly leadership pool.</p>
          <p>The direct activations of each active sponsor count as their volume for the month. The <Strong>top 10 sponsors</Strong> share the pool by volume, and can claim it after the month ends (00:00 UTC on the 1st).</p>
        </Income>
      </div>

      <div className="card card-body mt-3 bg-amber-400/12">
        <p className="flex items-center gap-2 text-[14px] font-extrabold"><Sparkles className="size-4 text-amber-500" />Where daily and generation income come from</p>
        <p className="mt-2 text-[13px] leading-relaxed text-muted">
          Daily and generation income are paid from <Strong>trading profits</Strong>, never from member deposits. Trading profits fund the reward pool. When you withdraw, that part of your balance is paid from the pool, so it can wait until the pool is funded.
        </p>
      </div>

      <div className="section-head mt-6">
        <div>
          <h2 className="section-title flex items-center gap-2"><Hourglass className="size-4 text-brand" />Vesting mode</h2>
          <p className="section-sub">Every tier you activate also earns ZQR tokens.</p>
        </div>
      </div>

      <div className="card card-body">
        <Step n={1} icon={Layers} title="Activation creates a vesting position">
          <p>When you activate a tier, you receive ZQR worth the same amount, at the token's market price at that time.</p>
        </Step>
        <Step n={2} icon={CalendarClock} title="Released over 60 months">
          <p>The ZQR is split into 60 equal monthly parts. A new part unlocks every 30 days, counted from your activation date.</p>
        </Step>
        <Step n={3} icon={BadgeCheck} title="Claim every month">
          <p>Open the Vesting page and tap <Strong>Claim</Strong>. You receive every month that has unlocked. If you skip a month, nothing is lost: unclaimed months add up until you claim.</p>
          <p>Each activation is its own position. One claim collects all of them.</p>
        </Step>
        <p className="mt-3 rounded-2xl bg-surface-2 p-3 text-[12.5px] text-muted">
          Example: a $100 activation with ZQR at $0.001 gives 100,000 ZQR, or about 1,666.67 ZQR a month for 60 months.
        </p>
      </div>

      <Link to="/about/faq" className="btn btn-neutral btn-block mt-4">Questions? Read the FAQ</Link>
    </section>
  );
}

const FAQ = [
  {
    group: "About Zyqorix",
    items: [
      ["What is Zyqorix?", "Zyqorix, The Market Hunting Network, combines human trading experience with AI-assisted analysis to scan the market, spot movements worth investigating, and share signals with a community of traders."],
      ["Who started it?", "A trader who learned the market by hand through charts, losses and lessons, then trained AI to test what experience had taught him across thousands of simulated market conditions."],
      ["Does Zyqorix promise guaranteed profits?", "No. Trading carries risk, and no system predicts every move. Zyqorix is about disciplined analysis and understanding the odds, not guarantees."],
      ["Does the AI replace the trader?", "No. The AI expands the search and the mathematics tests the strategies, but direction, judgment and responsibility stay with the trader."],
      ["Are signals meant to be copied blindly?", "No. A signal is information. The advantage is understanding what it might mean, knowing its limits, and deciding what to do next."],
    ],
  },
  {
    group: "Getting started",
    items: [
      ["How do I join?", "Connect your wallet on BNB Smart Chain, register under a sponsor, and deposit USDT (BEP-20). The minimum deposit is 50 USDT."],
      ["What does activating a tier mean?", "You use your wallet balance to switch on a tier: $50, $100, $200, $400, $800 or $1,600. An active tier is what earns rewards."],
      ["Do I have to activate the tiers in order?", "Yes. Tiers open from $50 upward, and none can be skipped."],
      ["When do the higher tiers open: after the days or when capping runs out?", "Whichever comes first. $50 and $100 are open from registration. $200 and $400 open 60 days after your first activation, or earlier once your $50 and $100 tiers have both reached zero capping. $800 and $1,600 open 120 days after your first activation, or earlier once your $200 and $400 tiers have both reached zero capping. The days count from the first tier you ever activated, not from registration or your latest activation. The Rewards page shows a countdown to each opening."],
      ["Can you give an example?", "You activate $50 for the first time, then $100. If both reach zero capping 40 days later, $200 and $400 open that day. If they still have capping left, $200 and $400 open 60 days after that first $50 activation anyway. Either way you still activate $200 before $400."],
      ["Can I activate with my rewards?", "Yes. You can activate from your whole wallet balance, whether it came from deposits or from collected rewards. Deposits are used first and always work. The part paid from daily and generation rewards needs the reward pool to hold 80% of it (the trading and liquidity shares), first come, first served. Referral, agent and leadership income earned from that part arrive as rewards too."],
      ["Can I activate the same tier twice?", "Each tier opens once. The $1,600 tier is the exception: you can activate it again whenever its capping reaches zero."],
    ],
  },
  {
    group: "Rewards",
    items: [
      ["What is capping?", "The most a tier can earn: 3x its value (2x for the $1,600 tier). A $50 tier can earn up to 150 USDT. Earnings use your oldest tier first, and a tier stops earning when its capping reaches zero."],
      ["How does the referral reward work?", "When a member you sponsored directly activates a tier, you earn 5% of it on your first five active directs, and 10% from your sixth active direct onward."],
      ["How much is the daily reward?", "1% of your active tier value per day. Collect it once every 24 hours on the Rewards page."],
      ["What is generation income?", "When anyone on your 1st to 10th level collects a daily reward, you earn 10% of that amount."],
      ["How does the leadership pool work?", "5% of every activation goes into the monthly pool. The top 10 active sponsors by their directs' activation volume share it, and can claim it after the month ends at 00:00 UTC on the 1st."],
      ["Where do daily and generation income come from?", "From trading profits, never from member deposits. Trading profits fund the reward pool that pays them."],
      ["What happens when my capping reaches zero?", "That tier stops earning new rewards. Rewards you already earned stay yours to collect. Activate your next tier to keep earning."],
    ],
  },
  {
    group: "Vesting",
    items: [
      ["What is vesting mode?", "Every tier you activate also gives you ZQR tokens worth the same amount, at the market price at activation. They are released over 60 months."],
      ["How do I claim my ZQR?", "Open the Vesting page and tap Claim. A new monthly part unlocks every 30 days from your activation date, and one claim collects every part that has unlocked across all your positions."],
      ["What if I miss a month?", "Nothing is lost. Unclaimed months add up and you collect them all with your next claim."],
    ],
  },
  {
    group: "Withdrawals",
    items: [
      ["How do I withdraw?", "From your wallet balance, in amounts of 20, 40, 60, 80 or 100 USDT, once every 24 hours. A deposit restarts the 24-hour wait."],
      ["Is there a withdrawal fee?", "Yes, 10% of the amount withdrawn."],
      ["Why can a withdrawal of my rewards wait?", "Daily and generation income are paid from the reward pool, which is funded by trading profits. If the pool is short, that part of your balance can be withdrawn once the pool is funded. Referral, agent and leadership income earned from an activation paid with rewards waits for the pool the same way."],
      ["Who controls the treasury?", "The treasury contract (the funder) holds members' unactivated wallet balances, the reward pool and the share of each activation that stays behind. 60% of every activation goes to the project's trading wallet and is not returned. The contract owner and its admins can also send USDT held in the treasury to the trading wallet at any time, and that USDT can include unactivated member balances. If more is sent than the treasury can spare, withdrawals can fail (\"insufficient funder\") until the treasury is refilled. Trading carries risk of loss, and returns are not guaranteed."],
      ["Can I use my balance instead of withdrawing?", "Yes. You can use your wallet balance to activate your next tier."],
    ],
  },
];

export function Faq() {
  return (
    <section className="section">
      <div className="section-head">
        <div>
          <h2 className="section-title">FAQ</h2>
          <p className="section-sub">Quick answers about Zyqorix and the rewards plan.</p>
        </div>
      </div>
      {FAQ.map(({ group, items }) => (
        <div key={group} className="mb-4">
          <p className="eyebrow mb-2 px-1">{group}</p>
          <div className="accordion">
            {items.map(([q, a]) => (
              <details key={q}>
                <summary>{q}</summary>
                <div className="acc-body">{a}</div>
              </details>
            ))}
          </div>
        </div>
      ))}
      <Link to="/about/rewardsplan" className="btn btn-neutral btn-block">Read the rewards plan</Link>
    </section>
  );
}
