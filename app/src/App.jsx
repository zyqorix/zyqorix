import { Navigate, Route, Routes } from "react-router-dom";
import { Shell } from "./components/Shell.jsx";
import { RequireAdmin, RequireMember } from "./components/Guards.jsx";
import Home from "./pages/Home.jsx";
import Wallet from "./pages/Wallet.jsx";
import Network from "./pages/Network.jsx";
import Account from "./pages/Account.jsx";
import Admin from "./pages/Admin.jsx";
import Register from "./pages/Register.jsx";
import LeadershipPool from "./pages/LeadershipPool.jsx";
import Rewards from "./pages/Rewards.jsx";

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
        </Route>
        <Route element={<RequireAdmin />}>
          <Route path="admin" element={<Admin />} />
        </Route>
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}
