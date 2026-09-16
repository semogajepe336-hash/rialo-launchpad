import {defineConfig} from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  // GitHub Pages serves at https://<user>.github.io/<repo>/ — set VITE_BASE_PATH when building there.
  base: process.env.VITE_BASE_PATH || "/",
  plugins: [react()],
  server: {
    port: 5173,
    host: true,
  },
});
