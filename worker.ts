// Worker that hosts the Chrome Rift RS web shell.
//
// The game's wasm (~33 MB) is far over Cloudflare's 25 MiB per-file static
// asset cap, so it is stored in R2 (no per-file cap) as a brotli-compressed
// object and streamed here by the worker. Every other path is served from the
// static assets (./dist), which keeps the React shell and game assets on the
// asset CDN.

const WASM_PATH = "/game/chrome_rift_bg.wasm";
const WASM_KEY = "game/chrome_rift_bg.wasm";

/** @param {Request} request @param {{GAME_BUCKET: any; ASSETS: any}} env */
export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === WASM_PATH) {
      const object = await env.GAME_BUCKET.get(WASM_KEY);
      if (!object) {
        return new Response("chrome_rift_bg.wasm is missing from R2", {
          status: 404,
        });
      }
      const headers = new Headers();
      object.writeHttpMetadata(headers);
      headers.set("Content-Type", "application/wasm");
      headers.set("Cache-Control", "public, max-age=31536000, immutable");
      headers.set("ETag", object.httpEtag);
      // The object is served brotli-encoded (browsers decompress it); the
      // game's init() already expects the wasm bytes. Without the encoding
      // header the browser would reject the bytes as corrupt.
      return new Response(object.body, { headers });
    }

    // Bevy probes for a sibling `<asset>.meta` file on every asset load. With
    // the SPA fallback, a missing .meta would be answered with index.html and
    // HTTP 200, which Bevy fails to parse and then drops the asset — so the
    // game would render with no art. Return 404 so Bevy loads the asset.
    if (url.pathname.endsWith(".meta")) {
      return new Response("Not found", { status: 404 });
    }

    return env.ASSETS.fetch(request);
  },
};