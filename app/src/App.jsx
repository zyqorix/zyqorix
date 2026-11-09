import { Route, Routes } from "react-router-dom";
import { Shell } from "./components/Shell.jsx";
import { RequireAdmin, RequireMember } from "./components/Guards.jsx";
import Home from "./pages/Home.jsx";
import Wallet from "./pages/Wallet.jsx";
import Network from "./pages/Network.jsx";
import Account from "./pages/Account.jsx";
import Admin from "./pages/Admin.jsx";
import AdminContract from "./pages/AdminContract.jsx";
import Register from "./pages/Register.jsx";
import LeadershipPool from "./pages/LeadershipPool.jsx";
import Rewards from "./pages/Rewards.jsx";
import Vesting from "./pages/Vesting.jsx";
import Swap from "./pages/Swap.jsx";
import Bot from "./pages/Bot.jsx";
import Fund from "./pages/Fund.jsx";
import ComingSoon from "./pages/ComingSoon.jsx";
import { AboutLayout, AboutStory, Faq, RewardsPlan } from "./pages/About.jsx";

export default function App() {
  return (
    <Routes>
      <Route element={<Shell />}>
        <Route index element={<Home />} />
        <Route path="register" element={<Register />} />
        <Route element={<RequireMember />}>
          <Route path="wallet" element={<Wallet />} />
          <Route path="network" element={<Network />} />
          <Route path="rewards" element={<Rewards />} />
          <Route path="rewards/leadershippool" element={<LeadershipPool />} />
          <Route path="account" element={<Account />} />
          <Route path="vesting" element={<Vesting />} />
        </Route>
        <Route element={<RequireAdmin />}>
          <Route path="admin" element={<Admin />} />
          <Route path="admin/:slug" element={<AdminContract />} />
        </Route>
        <Route path="swap" element={<Swap />} />
        <Route path="bot" element={<Bot />} />
        <Route path="fund" element={<Fund />} />
        <Route path="about" element={<AboutLayout />}>
          <Route index element={<AboutStory />} />
          <Route path="rewardsplan" element={<RewardsPlan />} />
          <Route path="faq" element={<Faq />} />
        </Route>
        <Route path="*" element={<ComingSoon />} />
      </Route>
    </Routes>
  );
}
