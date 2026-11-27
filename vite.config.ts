import { defineConfig } from "vite";
import { resolve } from "node:path";

// @ts-expect-error process is a nodejs global
const host = process.env.TAURI_DEV_HOST;

// https://vite.dev/config/
// In dev only, every page loads the demo backend first; it stays inert unless
// the page is opened in a plain browser with `?demo` (src/demo/demoBackend.ts).
const demoBackend = {
  name: "bark-demo-backend",
  apply: "serve" as const,
  transformIndexHtml: () => [
    { tag: "script", attrs: { type: "module", src: "/src/demo/demoBackend.ts" }, injectTo: "head-prepend" as const },
  ],
};

export default defineConfig(async () => ({
  plugins: [demoBackend],

  // Vite options tailored for Tauri development and only applied in `tauri dev` or `tauri build`
  //
  // 1. prevent Vite from obscuring rust errors
  clearScreen: false,
  // 2. tauri expects a fixed port, fail if that port is not available
  server: {
    port: 1420,
    strictPort: true,
    host: host || false,
    hmr: host
      ? {
          protocol: "ws",
          host,
          port: 1421,
        }
      : undefined,
    watch: {
      // 3. tell Vite to ignore watching `src-tauri`
      ignored: ["**/src-tauri/**"],
    },
  },
  build: {
    rollupOptions: {
      input: {
        main: resolve(__dirname, "index.html"),
        home: resolve(__dirname, "home.html"),
        "cursor-preview": resolve(__dirname, "cursor-preview.html"),
        "transcript-shelf": resolve(__dirname, "transcript-shelf.html"),
        onboarding: resolve(__dirname, "onboarding.html"),
      },
    },
  },
}));
