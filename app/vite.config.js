import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  // Local disk: the dep optimizer's rename/rmdir fails on the SMB workspace.
  cacheDir: "/private/tmp/zyqorix-vite-cache",
  optimizeDeps: { holdUntilCrawlEnd: false },
  server: {
    // Anvil reads go through the same origin: Chrome blocks a localhost page calling the NAS IP directly.
    proxy: {
      "/rpc": {
        target: "http://192.168.100.79:8545",
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/rpc/, ""),
      },
    },
  },
});
