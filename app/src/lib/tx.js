import { getPublicClient, waitForTransactionReceipt, writeContract } from "wagmi/actions";
import { ACTIVE_CHAIN_ID, BLOCK_TAG, network, wagmiConfig } from "./appkit.js";

const chainId = ACTIVE_CHAIN_ID;

const REASONS = [
  ["CALLER_NOT_EOA", "Use a regular wallet. Smart contract wallets aren't supported."],
  ["SPONSOR_NOT_FOUND", "That sponsor isn't a registered member."],
  ["SPONSOR_NOT_ACTIVE", "That sponsor isn't active. Their capping balance is zero."],
  ["ALREADY_REGISTERED", "This wallet is already registered."],
  ["PAUSED", "This is paused right now."],
  ["TIER_LOCKED", "This tier isn't open yet."],
  ["TIER_SKIPPED", "Activate the tiers in order."],
  ["TIER_USED", "You've already used this tier."],
  ["TIER_ACTIVE", "This tier still has capping."],
  ["INSUFFICIENT_WALLET", "Your wallet balance is too low."],
  ["INSUFFICIENT_REWARD_POOL", "The reward pool can't cover this tier right now. Try again later."],
  ["NO_LIQUIDITY", "The token price isn't available yet."],
  ["NO_PRICE", "The token price isn't available yet."],
  ["TwapPriceFailed", "The token price isn't available yet."],
  ["Pool not initialized", "The token price isn't available yet."],
  ["COOLDOWN", "Your withdrawal cooldown hasn't finished yet."],
  ["NOT_AGENT", "Only a current agent can collect agent rewards."],
  ["INSUFFICIENT_AGENT", "Your agent balance is too low."],
  ["INSUFFICIENT_FUNDER", "Payouts are low on funds right now. Try again later."],
  ["BELOW_MIN_DEPOSIT", "That's below the minimum deposit."],
  ["CLAIM_COOLDOWN", "You've already claimed. Your next claim isn't open yet."],
  ["NOTHING_TO_CLAIM", "There's nothing to claim yet."],
];

/** Send a contract write and wait for it. Gas gets a 30% margin: anvil's block time can make estimates low. */
export async function send(request, account) {
  const client = getPublicClient(wagmiConfig, { chainId });
  const gas = await client.estimateContractGas({ ...request, account, blockTag: BLOCK_TAG });
  const hash = await writeContract(wagmiConfig, { ...request, chainId, gas: (gas * 13n) / 10n });
  const receipt = await waitForTransactionReceipt(wagmiConfig, { hash, chainId });
  if (receipt.status !== "success") throw new Error("The transaction failed.");
}

/** A short message for a failed write. */
export function reason(error) {
  const text = `${error?.shortMessage || ""} ${error?.message || ""}`;
  if (/reject|denied/i.test(text)) return "You cancelled in your wallet.";
  if (/insufficient funds/i.test(text)) return `You don't have enough ${network.nativeCurrency.symbol} for the network fee.`;
  const known = REASONS.find(([key]) => text.includes(key));
  return known ? known[1] : error?.shortMessage || "The transaction failed. Please try again.";
}
