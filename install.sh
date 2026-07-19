#!/usr/bin/env bash
# merakey-muse installer — idempotent, safe to re-run.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
DJ_ROOT="${DJ_ROOT:-$HOME/Music/DJ}"

c_ok=$'\033[0;32m'; c_wa=$'\033[0;33m'; c_er=$'\033[0;31m'
c_dm=$'\033[0;90m'; c_hd=$'\033[1;36m'; c_rs=$'\033[0m'

info() { printf "%s→ %s%s\n" "$c_dm" "$*" "$c_rs"; }
ok()   { printf "%s✓ %s%s\n" "$c_ok" "$*" "$c_rs"; }
warn() { printf "%s⚠ %s%s\n" "$c_wa" "$*" "$c_rs"; }
die()  { printf "%s✗ %s%s\n" "$c_er" "$*" "$c_rs" >&2; exit 1; }

printf "%s── installing merakey-muse ──%s\n" "$c_hd" "$c_rs"

# ── prerequisites ──────────────────────────────────────────────────────────
# ffmpeg does the one Opus->FLAC decode; jq parses the search JSON.
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg not found. Install it:  brew install ffmpeg"
command -v jq     >/dev/null 2>&1 || die "jq not found. Install it:  brew install jq"
ok "ffmpeg and jq present"

mkdir -p "$BIN_DIR"

# ── yt-dlp ─────────────────────────────────────────────────────────────────
# Standalone binary rather than a brew/pip package: --update-to nightly can
# then self-update in place, which matters because YouTube extractor breakage
# is routinely fixed in nightly days before it reaches a stable release.
YTDLP="$BIN_DIR/yt-dlp"
if [[ ! -x "$YTDLP" ]]; then
  info "downloading yt-dlp standalone binary ..."
  case "$(uname -s)" in
    Darwin) asset="yt-dlp_macos" ;;
    Linux)  asset="yt-dlp" ;;
    *)      die "unsupported platform: $(uname -s)" ;;
  esac
  curl -fsSL -o "$YTDLP" \
    "https://github.com/yt-dlp/yt-dlp/releases/latest/download/${asset}"
  chmod +x "$YTDLP"
  ok "yt-dlp installed to $YTDLP"
else
  ok "yt-dlp already present at $YTDLP"
fi

info "updating yt-dlp to nightly ..."
"$YTDLP" --update-to nightly || warn "yt-dlp self-update failed (continuing)"

# ── djdl ───────────────────────────────────────────────────────────────────
# Symlink by default so a git pull updates the installed command; set
# MUSE_COPY=1 to install a detached copy instead.
if [[ "${MUSE_COPY:-0}" == "1" ]]; then
  cp "$REPO_DIR/bin/djdl" "$BIN_DIR/djdl"
  ok "djdl copied to $BIN_DIR/djdl"
else
  ln -sf "$REPO_DIR/bin/djdl" "$BIN_DIR/djdl"
  ok "djdl symlinked to $BIN_DIR/djdl -> $REPO_DIR/bin/djdl"
fi
chmod +x "$BIN_DIR/djdl"

# ── library layout ─────────────────────────────────────────────────────────
mkdir -p "$DJ_ROOT/Incoming"
ok "library root ready: $DJ_ROOT/Incoming"

# Never clobber a config the user has tuned. This file is the whole point of
# the tool, and an overwrite on re-install would be silently destructive.
if [[ -f "$DJ_ROOT/yt-dlp.conf" ]]; then
  info "existing $DJ_ROOT/yt-dlp.conf left untouched"
  info "compare with:  diff \"$DJ_ROOT/yt-dlp.conf\" \"$REPO_DIR/config/yt-dlp.conf\""
else
  cp "$REPO_DIR/config/yt-dlp.conf" "$DJ_ROOT/yt-dlp.conf"
  ok "config installed to $DJ_ROOT/yt-dlp.conf"
fi

# ── PATH check ─────────────────────────────────────────────────────────────
case ":${PATH}:" in
  *":$BIN_DIR:"*) ok "$BIN_DIR is on PATH" ;;
  *) warn "$BIN_DIR is NOT on PATH. Add to your shell rc:"
     printf "    export PATH=\"%s:\$PATH\"\n" "$BIN_DIR" ;;
esac

printf "\n"
exec "$BIN_DIR/djdl" doctor
