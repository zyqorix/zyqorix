import { erc20Abi } from "viem";
import { getPublicClient, waitForTransactionReceipt, writeContract } from "wagmi/actions";
import { ACTIVE_CHAIN_ID, BLOCK_TAG, network, wagmiConfig } from "./appkit.js";

const chainId = ACTIVE_CHAIN_ID;

const REASONS = [
  ["CALLER_NOT_EOA", "Use a regular wallet. Smart contract wallets aren't supported."],
  ["SPONSOR_NOT_FOUND", "That sponsor isn't a registered member."],
  ["SPONSOR_NOT_ACTIVE", "That sponsor isn't valid. They have no capping left and aren't an agent."],
  ["ALREADY_REGISTERED", "This wallet is already registered."],
  ["PAUSED", "This is paused right now."],
  ["TIER_LOCKED", "This tier isn't open yet."],
  ["TIER_SKIPPED", "Activate the tiers in order."],
  ["TIER_USED", "You've already used this tier."],
  ["TIER_ACTIVE", "This tier still has capping."],
  ["INSUFFICIENT_WALLET", "Your wallet balance is too low."],
  ["INSUFFICIENT_REWARD_POOL", "The reward pool is waiting for funding. The rewards part of your wallet can be withdrawn only once the pool covers it, and activating with it needs the pool to hold 80% of that part. Deposits always work. Try again after the pool is funded."],
  ["NO_LIQUIDITY", "The token price isn't available yet."],
  ["BAD_PRICE", "The price must be above zero."],
  ["NO_PRICE", "The token price isn't available yet."],
  ["TwapPriceFailed", "The token price isn't available yet."],
  ["Pool not initialized", "The token price isn't available yet."],
  // Before COOLDOWN: reasons match by substring, so the longer key must come first.
  ["CLAIM_COOLDOWN", "You've already claimed. Your next claim isn't open yet."],
  ["COOLDOWN", "Your withdrawal cooldown hasn't finished yet."],
  ["NOT_AGENT", "Only a current agent can collect agent rewards."],
  ["BAD_WITHDRAWAL_AMOUNT", "Choose one of the listed withdrawal amounts."],
  ["INSUFFICIENT_AGENT", "Your agent balance is too low."],
  ["LOW_GAS_FOR_BURN", "The network fee limit was too low for the swap and burn. Try again."],
  ["INSUFFICIENT_FUNDER", "Payouts are low on funds right now. Try again later."],
  ["TRADING_WALLET_NOT_SET", "The trading wallet isn't set yet."],
  ["TRADING_WALLET", "The trading wallet can't be a funding wallet."],
  ["FUNDING_WALLET", "A funding wallet can't be the trading wallet."],
  ["TRANSFER_FROM_FAILED", "The USDT approval didn't cover this amount. Try again."],
  ["BELOW_MIN_DEPOSIT", "That's below the minimum deposit."],
  ["NOTHING_TO_CLAIM", "There's nothing to claim yet."],
];

/** Send a contract write and wait for it. Gas gets a 30% margin: anvil's block time can make estimates low.
 *  `minGas` sets a floor for calls whose estimate can land below what an inner try/catch step needs. */
export async function send(request, account, { minGas = 0n } = {}) {
  const client = getPublicClient(wagmiConfig, { chainId });
  const estimate = await client.estimateContractGas({ ...request, account, blockTag: BLOCK_TAG });
  const padded = (estimate * 13n) / 10n;
  const hash = await writeContract(wagmiConfig, { ...request, chainId, gas: padded > minGas ? padded : minGas });
  const receipt = await waitForTransactionReceipt(wagmiConfig, { hash, chainId });
  if (receipt.status !== "success") throw new Error("The transaction failed.");
}

/** Approve `spender` for `amount` of `token` unless the chain already allows it. Reads the allowance fresh: the
 *  cached UI read can still show the allowance a previous deposit or swap just spent, so a second one in a row
 *  would skip the approve and revert TRANSFER_FROM_FAILED. Returns true when it sent an approval. */
export async function ensureAllowance(token, spender, amount, account) {
  const client = getPublicClient(wagmiConfig, { chainId });
  const allowance = await client.readContract({ address: token, abi: erc20Abi, functionName: "allowance", args: [account, spender], blockTag: BLOCK_TAG });
  if (allowance >= amount) return false;
  await send({ address: token, abi: erc20Abi, functionName: "approve", args: [spender, amount] }, account);
  return true;
}

/** A short message for a failed write. */
export function reason(error) {
  const text = `${error?.shortMessage || ""} ${error?.message || ""}`;
  if (/reject|denied/i.test(text)) return "You cancelled in your wallet.";
  if (/insufficient funds/i.test(text)) return `You don't have enough ${network.nativeCurrency.symbol} for the network fee.`;
  const known = REASONS.find(([key]) => text.includes(key));
  return known ? known[1] : error?.shortMessage || "The transaction failed. Please try again.";
}
