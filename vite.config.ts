import { defineConfig, type Connect, type Plugin } from "vite";
import react from "@vitejs/plugin-react";

// Bevy (AssetMetaCheck::Always) probes for a sibling `<asset>.meta` file on
// every asset load and treats any HTTP 200 as that meta file. Vite's SPA
// fallback answers missing paths — including these .meta files — with
// index.html, which Bevy fails to parse, so it drops the asset and the game
// renders with no art. Answer .meta with 404 so Bevy loads the asset directly.
function bevyMetaNotFound(): Plugin {
  const handler: Connect.NextHandleFunction = (req, res, next) => {
    if ((req.originalUrl ?? "").split("?")[0].endsWith(".meta")) {
      res.statusCode = 404;
      res.end("Not found");
      return;
    }
    next();
  };

  return {
    name: "bevy-meta-not-found",
    configureServer(server) {
      server.middlewares.use(handler);
    },
    configurePreviewServer(server) {
      server.middlewares.use(handler);
    },
  };
}

export default defineConfig({
  plugins: [react(), bevyMetaNotFound()],
  build: {
    target: "es2022",
    outDir: "dist",
    emptyOutDir: true,
  },
});
