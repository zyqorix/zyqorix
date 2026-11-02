// Sponsor referral links: <origin>/#/<sponsorAddress>. The fragment never reaches the server, so the link
// works on any host. A visitor who opens one has the sponsor remembered for the register form.
import { getAddress, isAddress } from "viem";

const SPONSOR_KEY = "zyqorix_sponsor";
const SPONSOR_TTL_MS = 7 * 24 * 60 * 60 * 1000;

export function clearStoredSponsor() {
  try { localStorage.removeItem(SPONSOR_KEY); } catch { /* private window */ }
}

/** The remembered sponsor (checksummed), or "" if none or expired. */
export function getStoredSponsor() {
  try {
    const record = JSON.parse(localStorage.getItem(SPONSOR_KEY));
    if (record && isAddress(record.addr) && Date.now() <= record.exp) return getAddress(record.addr);
  } catch { /* bad value */ }
  clearStoredSponsor();
  return "";
}

/** Remember the sponsor from a `#/0x…` link and clean the URL. Returns true when a link was captured. */
export function captureSponsorFromHash() {
  const match = window.location.hash.match(/^#\/?(0x[0-9a-fA-F]{40})$/);
  if (!match || !isAddress(match[1])) return false;
  try {
    localStorage.setItem(SPONSOR_KEY, JSON.stringify({ addr: getAddress(match[1]), exp: Date.now() + SPONSOR_TTL_MS }));
  } catch { /* private window */ }
  window.history.replaceState(null, "", "/register");
  return true;
}
