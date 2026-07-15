import { defineConfig } from "vite";
import { tanstackStartVite } from "@tanstack/start-vite";
import tsconfigPaths from "vite-tsconfig-paths";

export default defineConfig({
  plugins: [
    tanstackStartVite({
      deployment: {
        target: "static", // 👈 This overrides the default server configuration
      },
    }),
    tsconfigPaths(),
  ],
  base: "/SideHelper/", // 👈 Maps assets safely for your subfolder path
});
