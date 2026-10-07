import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";

// Production-only Content-Security-Policy (dev needs inline HMR scripts). Static page; talks to RPC nodes over https/wss only.
const CSP = [
  "default-src 'self'", "script-src 'self'", "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com", "font-src https://fonts.gstatic.com",
  "img-src 'self' data:", "connect-src 'self' https: wss:", "base-uri 'self'", "form-action 'none'", "object-src 'none'",
].join("; ");

export default defineConfig({
  plugins: [
    react(),
    { name: "montions-csp", apply: "build", transformIndexHtml: (html) => html.replace("</head>", `  <meta http-equiv="Content-Security-Policy" content="${CSP}" />\n  </head>`) },
  ],
  resolve: { alias: { "@montions/sdk": fileURLToPath(new URL("../sdk/src/index.ts", import.meta.url)) } },
  server: { fs: { allow: [".."] } },
  build: { rollupOptions: { output: { manualChunks: { viem: ["viem"] } } }, chunkSizeWarningLimit: 800 },
});
