import { formatUnits } from "viem";

/** A token amount (18-dp) for display, at most two decimals. */
export const money = (value) => Number(formatUnits(value ?? 0n, 18)).toLocaleString(undefined, { maximumFractionDigits: 2 });
