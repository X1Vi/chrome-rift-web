# Chrome Rift Web

React + Vite shell that hosts the browser (WebAssembly) build of
[Chrome Rift RS](../chrome-rift-rs) and deploys it to Cloudflare.

The Rust game is compiled to WebAssembly, optimized, and copied into
`public/game/`. The React app serves a landing page and launches the game
fullscreen in an iframe. `public/game/` and `dist/` are generated and
git-ignored.

## How it's hosted on Cloudflare

- The React shell and the game's static assets are served from **Workers
  static assets** (`./dist`).
- The game's wasm is ~77 MiB raw / ~7.4 MiB brotli — far over Cloudflare's
  **25 MiB per-file cap** for static assets — so it lives in an **R2 bucket**
  and is streamed by the Worker in `worker.ts`. Only the wasm path
  (`/game/chrome_rift_bg.wasm`) is served from R2; every other request falls
  through to the static assets, so both local dev and cheap edge serving keep
  working.
- The R2 object is brotli-compressed and served with `Content-Encoding: br`
  (browsers decompress it transparently) plus `Content-Type: application/wasm`
  so `WebAssembly.instantiateStreaming` works.

## Layout

```
chrome-rift-web/
├── index.html            # React entry (Vite)
├── src/                  # Landing page + game launcher
├── worker.ts             # Worker: R2 wasm for /game/*.wasm, assets for the rest
├── public/game/          # generated: wasm build of the game (git-ignored)
├── scripts/build-game.sh # build + shrink + stage the game, then deploy
├── wrangler.jsonc        # Workers config: assets + R2 binding
└── vite.config.ts
```

## Quick start

```bash
npm install
npm run game        # compile the game to wasm, shrink it, stage in public/game
npm run dev         # http://localhost:5173
```

`npm run game` expects the Rust repo as a sibling (`../chrome-rift-rs`). Point
elsewhere with an env var:

```bash
GAME_ROOT=/path/to/chrome-rift-rs npm run game
```

## Deploy

```bash
npx wrangler login            # once (needs a Cloudflare account with R2 access)
npm run deploy                # slow path: full wasm build + stage + deploy
```

`npm run deploy` runs `scripts/build-game.sh --deploy`, which:

1. builds `chrome-rift-rs` for `wasm32-unknown-unknown` (release, `web` feature),
   unless `--skip-build` (the full Rust release link takes ~4-12 minutes),
2. generates JS bindings with a matching `wasm-bindgen` and (optionally) runs
   `wasm-opt -Oz` — skip with `--no-opt`; brotli on R2 is the real size win,
3. copies assets, dropping the `assets/*/source` authoring folders,
4. re-encodes the radio `*.mp3` to 96 kbps with `ffmpeg` (`--skip-audio`),
5. brotli-compresses the wasm and uploads it to R2
   (`chrome-rift-web` bucket, key `game/chrome_rift_bg.wasm`),
6. builds the React shell, removes the wasm from `dist/` so every uploaded
   asset stays under the 25 MiB cap, and runs `wrangler deploy`.

### Fast iteration deploy

Skips the slow Rust rebuild by reusing the previously built wasm:

```bash
scripts/build-game.sh --skip-build --no-opt --deploy
```

Useful flags:

```bash
scripts/build-game.sh --skip-build        # restage without recompiling Rust
scripts/build-game.sh --no-opt            # skip wasm-opt
scripts/build-game.sh --no-audio          # skip mp3 re-encoding
scripts/build-game.sh --bitrate 80k       # different mp3 bitrate
scripts/build-game.sh --serve             # test the raw game on :8000
scripts/build-game.sh --deploy --preview  # upload a version without promoting
```

## Requirements

- Rust with `wasm32-unknown-unknown` (`rustup target add wasm32-unknown-unknown`)
- `wasm-bindgen-cli` matching the game's `Cargo.lock` (installed on demand)
- Node 20+ and npm
- `ffmpeg` (optional) to shrink audio
- A Cloudflare account: `npx wrangler login`, with an R2 bucket created on first
  deploy

## Notes

- The game was fixed to boot on wasm: no `std::fs` or `SystemTime` calls on
  wasm32 (see `chrome-rift-rs`), and a `console_error_panic_hook` logs the real
  panic message to the browser console instead of a bare `unreachable executed`.
- The game's own `web/index.html` shows its loading overlay, so the React shell
  hands off to the iframe without a second loader.
- `wrangler.jsonc` uses `not_found_handling: single-page-application` so the
  React app owns client-side routes while `/game/*` stays a real directory of
  static files.