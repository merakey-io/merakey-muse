#!/usr/bin/env bash
# merakey-muse installer — idempotent, safe to re-run.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
DJ_ROOT="${DJ_ROOT:-$HOME/Music/DJ}"
VENV="${MUSE_VENV:-$HOME/.local/share/muse-venv}"

c_ok=$'\033[0;32m'; c_wa=$'\033[0;33m'; c_er=$'\033[0;31m'
c_dm=$'\033[0;90m'; c_hd=$'\033[1;36m'; c_rs=$'\033[0m'

info() { printf "%s→ %s%s\n" "$c_dm" "$*" "$c_rs"; }
ok()   { printf "%s✓ %s%s\n" "$c_ok" "$*" "$c_rs"; }
warn() { printf "%s⚠ %s%s\n" "$c_wa" "$*" "$c_rs"; }
die()  { printf "%s✗ %s%s\n" "$c_er" "$*" "$c_rs" >&2; exit 1; }

printf "%s── installing merakey-muse ──%s\n" "$c_hd" "$c_rs"

# ── prerequisites ──────────────────────────────────────────────────────────
# Hard requirements: ffmpeg does the one Opus->FLAC decode and every analysis
# probe; jq parses the search JSON. Everything else degrades gracefully.
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg not found. Install it:  brew install ffmpeg"
command -v jq     >/dev/null 2>&1 || die "jq not found. Install it:  brew install jq"
ok "ffmpeg and jq present"

# ── ffmpeg version floor: 8.1.2 ────────────────────────────────────────────
# Below 8.1.2, ffmpeg carries CVE-2026-8461 ("PixelSmash") — a heap
# out-of-bounds write in the MagicYUV decoder, with RCE demonstrated from a
# 50KB file. `djdl scan` and `djdl vet` exist to decode UNTRUSTED input, so a
# stale ffmpeg turns the two safety commands into the liability. This is a
# refusal, not a warning, for that reason.
#
# Strictly-less-than: `sort -V -C` alone treats equal as sorted, so an
# exactly-patched 8.1.2 would otherwise report as vulnerable.
FFMIN="8.1.2"
fv=$(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}' | sed 's/^n//')
if [[ ! "$fv" =~ ^[0-9] ]]; then
  warn "cannot determine ffmpeg version (got '${fv:-none}') — ensure it is >= $FFMIN"
  warn "versions below $FFMIN carry CVE-2026-8461 (RCE via crafted media)"
elif [[ "$fv" != "$FFMIN" ]] && printf '%s\n%s\n' "$fv" "$FFMIN" | sort -V -C; then
  printf "%s✗ ffmpeg %s is below the %s security floor.%s\n" "$c_er" "$fv" "$FFMIN" "$c_rs" >&2
  printf "%s  CVE-2026-8461 (\"PixelSmash\"): heap OOB write in the MagicYUV decoder,%s\n" "$c_wa" "$c_rs" >&2
  printf "%s  RCE demonstrated from a 50KB file. 'djdl scan' and 'djdl vet' decode%s\n" "$c_wa" "$c_rs" >&2
  printf "%s  untrusted input, so this is not a theoretical exposure here.%s\n" "$c_wa" "$c_rs" >&2
  printf "%s  Fix:  brew upgrade ffmpeg%s\n" "$c_wa" "$c_rs" >&2
  printf "%s  Override (not recommended):  MUSE_ALLOW_OLD_FFMPEG=1 ./install.sh%s\n" "$c_dm" "$c_rs" >&2
  [[ "${MUSE_ALLOW_OLD_FFMPEG:-0}" == "1" ]] || exit 1
  warn "continuing with a vulnerable ffmpeg because MUSE_ALLOW_OLD_FFMPEG=1"
else
  ok "ffmpeg $fv (>= $FFMIN, PixelSmash patched)"
fi

# ── optional analysis tooling ──────────────────────────────────────────────
# Not fatal: only specific subcommands need these, and the rest of djdl works
# without them. rsgain backs `djdl gain`. chromaprint (fpcalc) is there for
# acoustic fingerprinting / duplicate identification. aubio is a second
# opinion on onset/tempo work — note that djdl's own analysis deliberately
# does NOT use it, because aubio has no tempo-range flag and octave errors are
# the dominant failure mode (see README, "djdl analyze").
missing_opt=()
for t in rsgain fpcalc aubio; do
  command -v "$t" >/dev/null 2>&1 || missing_opt+=("$t")
done
if [[ ${#missing_opt[@]} -eq 0 ]]; then
  ok "rsgain, chromaprint and aubio present"
else
  warn "optional tools missing: ${missing_opt[*]}"
  info "install with:  brew install rsgain chromaprint aubio"
fi

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

# ── djdl + helpers ─────────────────────────────────────────────────────────
# Symlink by default so a git pull updates the installed commands; set
# MUSE_COPY=1 to install detached copies instead.
# djdl locates its helpers next to itself, so all three must land in BIN_DIR.
for cmd in djdl djdl-rbxml djdl-engine; do
  if [[ "${MUSE_COPY:-0}" == "1" ]]; then
    cp "$REPO_DIR/bin/$cmd" "$BIN_DIR/$cmd"
    ok "$cmd copied to $BIN_DIR/$cmd"
  else
    ln -sf "$REPO_DIR/bin/$cmd" "$BIN_DIR/$cmd"
    ok "$cmd symlinked to $BIN_DIR/$cmd"
  fi
  chmod +x "$BIN_DIR/$cmd"
done

# ── analysis venv (Essentia) ───────────────────────────────────────────────
# `djdl analyze`, `mix` and `similar` run djdl-engine under this interpreter.
#
# The Python version is NOT incidental — it is the whole reason this is a
# pinned venv and not a plain `pip install essentia`. Essentia's current build
# ships a cp314 arm64 wheel ONLY, and there is no sdist. On 3.12 or 3.13 pip
# does not fail: it silently resolves to a much older July 2025 build. So the
# venv is pinned to 3.14 and left out of the way of any system Python.
if [[ -x "$VENV/bin/python" ]] && "$VENV/bin/python" -c "import essentia" 2>/dev/null; then
  ok "muse venv ready: $VENV ($("$VENV/bin/python" -V 2>&1))"
elif command -v uv >/dev/null 2>&1; then
  info "creating analysis venv at $VENV (Python 3.14 + Essentia) ..."
  if uv venv --python 3.14 "$VENV" && VIRTUAL_ENV="$VENV" uv pip install essentia; then
    ok "Essentia installed into $VENV"
  else
    warn "venv setup failed — 'djdl analyze', 'mix' and 'similar' will not run"
    info "retry manually:"
    info "  uv venv --python 3.14 $VENV"
    info "  VIRTUAL_ENV=$VENV uv pip install essentia"
  fi
else
  warn "uv not found — skipping the Essentia venv"
  info "'djdl analyze', 'mix' and 'similar' need it. Install uv:"
  info "  curl -LsSf https://astral.sh/uv/install.sh | sh"
  info "then:"
  info "  uv venv --python 3.14 $VENV && VIRTUAL_ENV=$VENV uv pip install essentia"
  info "pip fallback (must be a 3.14 interpreter — see note above):"
  info "  python3.14 -m venv $VENV && $VENV/bin/pip install essentia"
fi

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
