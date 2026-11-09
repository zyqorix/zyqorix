# Set aside (2026-11-05)

The standalone funding-puller design, kept in case the owner switches back after testing.
The live design merges the funding-wallet list into `funder.sol` and drops funder migration.

- `fundingpuller.sol` — ZyqorixFundingPuller (multi-wallet, audit GO with L-1/I-1 fixed).
- `rewards.puller.sol`, `funder.migration.sol`, `gateway.migration.sol` — the matching versions of
  rewards/funder/gateway (funder.migration.sol = the build of mainnet funder 0x219c…B5B9).
- `*.t.sol` — the matching tests (ZyqorixFlow with the puller tests, ZyqorixGateway with migration tests).

Not synced to `chain/`. To restore: copy back over the live files and re-run `/chain-test zyqorix`.
