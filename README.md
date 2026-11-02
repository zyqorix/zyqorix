# ZYQORIX

ZYQORIX is a membership and rewards system on BNB Smart Chain.

- `contracts/` holds the Solidity 0.8.36 contracts and their Foundry tests (`contracts/test`).
- `app/` holds the React 19, Vite, Tailwind v4, wagmi and Reown AppKit web app.

## Status
The contracts run on a test network only and are not on BSC mainnet. https://zyqorix.net currently runs the testnet build.

On the test network a reward day lasts 60 seconds and a month lasts 30 minutes, so the full reward cycle can be tested quickly. The contracts refuse these short times on any other chain.

## App
```bash
cd app
npm ci
npm run dev            # local development
npm run build:testnet  # testnet build
npm run deploy         # publish the testnet build to GitHub Pages
```
