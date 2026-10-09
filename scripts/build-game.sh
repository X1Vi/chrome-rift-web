#!/usr/bin/env bash
#
# Build the Chrome Rift RS browser release, shrink it, stage it under
# public/game/, then (optionally) build the React shell and deploy it to
# Cloudflare Workers static assets.
#
# Usage:
#   scripts/build-game.sh                  stage an optimized game build
#   scripts/build-game.sh --deploy         stage, vite build, wrangler deploy
#   scripts/build-game.sh --deploy --preview
#                                          upload a preview version instead
#   scripts/build-game.sh --skip-build     restage without recompiling Rust
#   scripts/build-game.sh --no-opt         skip wasm-opt
#   scripts/build-game.sh --no-audio       skip mp3 re-encoding
#   scripts/build-game.sh --bitrate 80k    target mp3 bitrate (default 96k)
#   scripts/build-game.sh --serve          serve the staged game on :8000
#   scripts/build-game.sh --out DIR        custom staging directory
#
# Environment:
#   GAME_ROOT   path to the Rust game repo (default: ../chrome-rift-rs)
#
# Requirements:
#   - rustup target add wasm32-unknown-unknown
#   - wasm-bindgen CLI matching the version in Cargo.lock (installed on demand)
#   - Node/npm (the shell, and wasm-opt from the `binaryen` dev dependency)
#   - ffmpeg (optional, shrinks the radio mp3s)
# Missing optional tools are skipped with a warning.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GAME_ROOT="${GAME_ROOT:-$PROJECT_ROOT/../chrome-rift-rs}"
OUT_DIR="$PROJECT_ROOT/public/game"

TARGET="wasm32-unknown-unknown"
BIN="chrome-rift-rs"
ARTIFACT="chrome_rift"
WASM="$GAME_ROOT/target/$TARGET/release/$BIN.wasm"

SKIP_BUILD=0
SKIP_OPT=0
SKIP_AUDIO=0
DEPLOY=0
PREVIEW=0
SERVE=0
AUDIO_BITRATE="96k"

log() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy) DEPLOY=1; shift ;;
    --preview) PREVIEW=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --no-opt) SKIP_OPT=1; shift ;;
    --no-audio|--skip-audio) SKIP_AUDIO=1; shift ;;
    --serve) SERVE=1; shift ;;
    --bitrate) AUDIO_BITRATE="${2:?--bitrate needs a value}"; shift 2 ;;
    --out) OUT_DIR="${2:?--out needs a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Resolve GAME_ROOT to an absolute path and make sure it is a Rust crate.
[[ -d "$GAME_ROOT" ]] || die "GAME_ROOT not found: $GAME_ROOT (set GAME_ROOT=/path/to/chrome-rift-rs)"
GAME_ROOT="$(cd "$GAME_ROOT" && pwd)"
[[ -f "$GAME_ROOT/Cargo.toml" ]] || die "no Cargo.toml in GAME_ROOT=$GAME_ROOT"
[[ -f "$GAME_ROOT/web/index.html" ]] || die "no web/index.html in GAME_ROOT=$GAME_ROOT"

required_bindgen() {
  awk '/^name = "wasm-bindgen"$/{getline; if ($1 == "version") {gsub(/"/, "", $3); print $3}}' \
    "$GAME_ROOT/Cargo.lock" | head -1
}

ensure_wasm_target() {
  if ! rustup target list --installed 2>/dev/null | grep -qx "$TARGET"; then
    log "Adding Rust target $TARGET"
    rustup target add "$TARGET" >/dev/null
  fi
}

ensure_wasm_bindgen() {
  local wanted installed
  wanted="$(required_bindgen || true)"
  if ! command -v wasm-bindgen >/dev/null 2>&1; then
    if [[ -n "$wanted" ]]; then
      log "Installing wasm-bindgen-cli $wanted"
      cargo install wasm-bindgen-cli --version "$wanted" --locked
    else
      log "Installing wasm-bindgen-cli"
      cargo install wasm-bindgen-cli --locked
    fi
    return
  fi
  installed="$(wasm-bindgen --version | awk '{print $2}')"
  if [[ -n "$wanted" && "$installed" != "$wanted" ]]; then
    warn "wasm-bindgen $installed found, Cargo.lock pins $wanted; installing the matching CLI"
    cargo install wasm-bindgen-cli --version "$wanted" --locked
  fi
}

# Echo the path to a wasm-opt binary, or return 1.
resolve_wasm_opt() {
  if command -v wasm-opt >/dev/null 2>&1; then
    command -v wasm-opt
    return 0
  fi
  local local_bin="$PROJECT_ROOT/node_modules/.bin/wasm-opt"
  if [[ -x "$local_bin" ]]; then
    printf '%s\n' "$local_bin"
    return 0
  fi
  return 1
}

optimize_audio() {
  local root="$OUT_DIR/assets/audio"
  [[ -d "$root" ]] || return 0
  if ! command -v ffmpeg >/dev/null 2>&1; then
    warn "ffmpeg not found; shipping original audio"
    return 0
  fi
  log "Re-encoding mp3 audio at $AUDIO_BITRATE"
  # Drop partial temp outputs from any previously aborted run.
  find "$root" -type f -name '*.opt.mp3' -delete 2>/dev/null || true
  local file tmp count=0
  while IFS= read -r -d '' file; do
    # Unique sibling temp name so concurrent runs never race on one output;
    # the .mp3 suffix lets ffmpeg pick the muxer, and the per-file timeout
    # guards against any single encoder hanging.
    tmp="$(mktemp "${file%.mp3}.XXXXXX.mp3")"
    if timeout 180 ffmpeg -nostdin -v error -y -i "$file" -vn \
        -c:a libmp3lame -b:a "$AUDIO_BITRATE" "$tmp"; then
      mv -f "$tmp" "$file"
      count=$((count + 1))
    else
      rm -f "$tmp"
      warn "could not re-encode $file"
    fi
  done < <(find "$root" -type f -iname '*.mp3' ! -iname '*.opt.mp3' -print0)
  printf '    %d file(s) re-encoded\n' "$count"
}

# --- Build ------------------------------------------------------------------

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  ensure_wasm_target
  log "Building $BIN for $TARGET (release, web features)"
  ( cd "$GAME_ROOT" && cargo build --release --target "$TARGET" \
      --no-default-features --features web --bin "$BIN" )
else
  log "Skipping cargo build"
fi

[[ -f "$WASM" ]] || die "$WASM not found; run without --skip-build"

ensure_wasm_bindgen

# --- Stage ------------------------------------------------------------------

log "Staging game into $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

log "Generating browser bindings ($ARTIFACT)"
wasm-bindgen --target web --no-typescript \
  --out-dir "$OUT_DIR" --out-name "$ARTIFACT" "$WASM"

log "Copying runtime assets"
cp -R "$GAME_ROOT/assets" "$OUT_DIR/assets"
# Authoring inputs the browser never reads.
rm -rf "$OUT_DIR/assets/textures/source" "$OUT_DIR/assets/loading/source"
cp "$GAME_ROOT/web/index.html" "$OUT_DIR/index.html"

# --- Shrink -----------------------------------------------------------------

WASM_FILE="$OUT_DIR/${ARTIFACT}_bg.wasm"
if [[ "$SKIP_OPT" -eq 0 ]]; then
  WASM_OPT=""
  if ! WASM_OPT="$(resolve_wasm_opt)"; then
    if command -v npm >/dev/null 2>&1; then
      log "Installing binaryen (provides wasm-opt)"
      ( cd "$PROJECT_ROOT" && npm install --no-save --no-package-lock \
          --no-audit --no-fund binaryen >/dev/null 2>&1 ) || true
      WASM_OPT="$(resolve_wasm_opt || true)"
    fi
  fi
  if [[ -n "$WASM_OPT" ]]; then
    log "Optimizing wasm with wasm-opt -Oz"
    before="$(stat -c%s "$WASM_FILE")"
    "$WASM_OPT" -Oz "$WASM_FILE" -o "$WASM_FILE.opt"
    mv "$WASM_FILE.opt" "$WASM_FILE"
    after="$(stat -c%s "$WASM_FILE")"
    printf '    wasm %.1f MiB -> %.1f MiB\n' \
      "$(awk "BEGIN{print $before/1048576}")" \
      "$(awk "BEGIN{print $after/1048576}")"
  else
    warn "wasm-opt unavailable; shipping unoptimized wasm (may exceed Cloudflare's 25 MiB per-file limit)"
  fi
else
  log "Skipping wasm-opt"
fi

if [[ "$SKIP_AUDIO" -eq 0 ]]; then
  optimize_audio
else
  log "Skipping audio optimization"
fi

# --- Report -----------------------------------------------------------------

log "Game staged"
du -sh "$OUT_DIR" 2>/dev/null || true
find "$OUT_DIR" -type f -printf '%s\t%p\n' 2>/dev/null \
  | sort -rn | head -5 \
  | awk -F'\t' '{printf "    %6.1f MiB  %s\n", $1/1048576, $2}'

# --- Ship -------------------------------------------------------------------

if [[ "$DEPLOY" -eq 1 ]]; then
  if [[ "$SKIP_BUILD" -eq 1 && ! -f "$OUT_DIR/index.html" ]]; then
    die "nothing staged to deploy; run without --skip-build"
  fi
  [[ -f "$OUT_DIR/${ARTIFACT}_bg.wasm" ]] || die "no staged wasm at $OUT_DIR/${ARTIFACT}_bg.wasm"

  log "Installing npm dependencies"
  ( cd "$PROJECT_ROOT" && npm install --no-audit --no-fund )

  # Brotli-compress the wasm: the R2-served copy is what browsers download, so
  # this is the real transfer size (roughly 33 MiB -> ~8 MiB).
  log "Compressing wasm with brotli (quality 9)"
  node - "$OUT_DIR/${ARTIFACT}_bg.wasm" "$OUT_DIR/${ARTIFACT}_bg.wasm.br" <<'JS'
const fs = require("fs");
const zlib = require("zlib");
const [inp, out] = process.argv.slice(2);
const data = fs.readFileSync(inp);
const br = zlib.brotliCompressSync(data, {
  params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 9 },
});
fs.writeFileSync(out, br);
process.stdout.write(
  `    brotli ${(data.length / 1048576).toFixed(1)} MiB -> ${(br.length / 1048576).toFixed(1)} MiB\n`,
);
JS

  log "Building the React shell"
  ( cd "$PROJECT_ROOT" && npm run build )

  # The wasm goes to R2, not the static bundle: keep every uploaded asset under
  # Cloudflare's 25 MiB per-file cap.
  rm -f "$PROJECT_ROOT/dist/game/${ARTIFACT}_bg.wasm" \
        "$PROJECT_ROOT/dist/game/${ARTIFACT}_bg.wasm.br"

  BUCKET="chrome-rift-web"
  R2_KEY="game/${ARTIFACT}_bg.wasm"
  log "Uploading wasm to R2 bucket '$BUCKET' ($R2_KEY)"
  ( cd "$PROJECT_ROOT" && npx --no-install wrangler r2 bucket create "$BUCKET" \
      >/dev/null 2>&1 || true )
  ( cd "$PROJECT_ROOT" && npx --no-install wrangler r2 object put "$BUCKET/$R2_KEY" \
      --file "$OUT_DIR/${ARTIFACT}_bg.wasm.br" \
      --content-type application/wasm \
      --content-encoding br \
      --cache-control "public, max-age=31536000, immutable" \
      --force )

  if [[ "$PREVIEW" -eq 1 ]]; then
    log "Uploading a preview version to Cloudflare"
    ( cd "$PROJECT_ROOT" && npx --no-install wrangler versions upload )
  else
    log "Deploying to Cloudflare Workers"
    ( cd "$PROJECT_ROOT" && npx --no-install wrangler deploy )
  fi
  log "Done"
elif [[ "$SERVE" -eq 1 ]]; then
  log "Serving $OUT_DIR at http://localhost:8000 (Ctrl-C to stop)"
  python3 -m http.server 8000 --directory "$OUT_DIR"
else
  echo
  echo "Next:"
  echo "  npm run build          # build the React shell into dist/"
  echo "  npm run deploy         # stage + build + wrangler deploy"
  echo "  scripts/build-game.sh --serve   # test the game alone on :8000"
fi
