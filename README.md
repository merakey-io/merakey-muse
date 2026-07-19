# merakey-muse

A rekordbox-oriented music acquisition CLI wrapping [yt-dlp](https://github.com/yt-dlp/yt-dlp).

`djdl` searches YouTube, YouTube Music, SoundCloud and Spotify, lets you pick tracks from a
numbered table, and downloads them into `~/Music/DJ/Incoming` in a format rekordbox will
actually import — with cleaned-up tags, no description spam in the comment field, and an
idempotent archive so re-runs never re-download.

```
djdl search -m "peggy gou starry night"
djdl get https://soundcloud.com/…
djdl sync https://youtube.com/playlist?list=… "Warmup"
```

## Install

```bash
git clone https://github.com/merakey-io/merakey-muse.git
cd merakey-muse
./install.sh
```

The installer checks for `ffmpeg` and `jq`, installs the yt-dlp standalone binary to
`~/.local/bin/yt-dlp` and updates it to nightly, links `djdl` onto your PATH, creates
`~/Music/DJ/Incoming`, and installs the config — **without overwriting an existing
`~/Music/DJ/yt-dlp.conf`**. It finishes by running `djdl doctor`.

`spotdl` is optional and only needed for the `spotify` subcommand: `uv tool install spotdl`.

## The core design constraint: rekordbox cannot import Opus

This is the entire reason the project exists.

YouTube's best audio stream is **Opus in a webm container** (itag 251, ~160kbps VBR). It is
better than the AAC alternative (itag 140, 128kbps CBR). It is also a format **rekordbox
will not import**. It doesn't error loudly — tracks simply fail to appear, or the collection
quietly refuses them.

The advice you will find everywhere is:

```bash
yt-dlp -x --audio-format best <url>     # ← produces a library rekordbox rejects
```

`--audio-format best` means "don't convert, keep the best available" — so it **stream-copies
the Opus straight through**. You end up with a folder of `.opus`/`.webm` files that are
technically the highest quality available and completely useless in a DJ booth.

The fix is a conditional format rule:

```
-f bestaudio[ext=webm]/bestaudio/best
-x
--audio-format webm>flac/best
```

`webm>flac/best` reads as: *if the extracted audio is webm, convert it to FLAC; otherwise,
best (stream copy, untouched)*.

| Source stream | Action | Result |
|---|---|---|
| webm / Opus (YouTube) | decode once to FLAC | **one decode, NO re-encode** — no generation loss |
| m4a / AAC (YouTube fallback) | stream copy | bit-identical, untouched |
| mp3 (SoundCloud) | stream copy | bit-identical, untouched |

Opus → FLAC is a lossy-to-lossless transcode: the Opus stream is decoded exactly once to PCM
and then losslessly packed into FLAC. Nothing is re-compressed, so no second round of lossy
artifacts is introduced. Formats that are already rekordbox-compatible are never touched at all.

One rule, correct for YouTube and SoundCloud alike. Nothing that leaves this tool is ever Opus.

## Commands

| Command | What it does |
|---|---|
| `djdl search [-m\|-s] [-n N] <query>` | Search, render a numbered table, pick rows, download. `-m` = YouTube Music (cleanest tags), `-s` = SoundCloud (edits, bootlegs), default = YouTube. `-n N` sets result count (default 12). Selection accepts numbers (`1 3 5`), ranges (`1-4`), `a` for all, Enter to cancel. |
| `djdl get <url>...` | Download URLs directly, same pipeline. |
| `djdl sync <playlist-url> [name]` | Idempotent playlist sync into `~/Music/DJ/Playlists/<name>/`. Re-run any time; the archive skips what you already have. |
| `djdl spotify <url>` | Spotify playlist via `spotdl`. |
| `djdl ls` | What's staged in `Incoming`, with sizes and archive count. |
| `djdl update` | `yt-dlp --update-to nightly`. First thing to try when extraction breaks. |
| `djdl doctor` | Health check — versions, config presence, free space, and a live YouTube extractor probe. |

### Search result warnings

`search` flags uploads that are unusable in a set. The pitch- and tempo-altered ones are the
dangerous category: rekordbox will happily analyse a "sped up" or "432Hz" rip and report a key
and BPM that are simply **wrong**, silently poisoning harmonic mixing. Flagged:
`pitch-shifted` (432Hz), `tempo-altered` (nightcore / sped up / slowed / reverb),
`long/loop?` (over 12 minutes), `live rip`.

### About `djdl spotify`

`spotdl` reads Spotify **metadata**, then sources the audio from YouTube. It does not decrypt
Spotify. What you get is a YouTube match wearing Spotify tags, and the known failure mode is
version mismatch — a radio edit where you wanted the extended mix. Verify what lands.

## Quality ceiling — read this honestly

**YouTube audio tops out at roughly 160kbps Opus.** That is the source. It is lossy.

The FLAC files this tool produces are a **compatibility container, not recovered fidelity**.
Wrapping a 160kbps Opus stream in FLAC makes it importable by rekordbox and stops any further
quality loss from occurring — it does **not** make it sound better than the source, and it never
will. A 40MB FLAC from YouTube contains exactly as much musical information as the 4MB Opus it
came from.

For tracks you actually intend to play out on a real system, **buy them**: Bandcamp, Beatport,
Qobuz, or the artist directly. This tool is for discovery, references, edits and bootlegs that
have no commercial release — not for building the library you rely on.

## Gotchas discovered the hard way

Four real bugs found during development. All are non-obvious, all fail *silently*, and all will
bite anyone editing the config.

**a. yt-dlp's config parser splits on whitespace — quote your output template.**
An unquoted `-o` template containing `" - "` silently truncates at the first space, and the
remainder of the line is parsed as bogus URLs. `-o Incoming/%(artist)s - %(title)s.%(ext)s`
becomes an output template of `Incoming/%(artist)s` plus two "URLs" named `-` and
`%(title)s.%(ext)s`. No error. Always quote it.

**b. The config parser strips backslashes and lets multi-arg options swallow the next line.**
`--replace-in-metadata FIELD REGEX REPLACEMENT` takes three arguments, but the config parser does
not require them all on one line — a missing third argument is filled by **eating the following
line of the config file**. Combined with backslash stripping, this mangles regexes into
nonsense and silently produces raw untouched tags. **This is why every regex and metadata rule
lives in the `djdl` script, not in `yt-dlp.conf`**, where shell quoting is unambiguous. Keep
`yt-dlp.conf` to single-argument options only.

**c. `-P` does not apply to `--download-archive`.**
`-P` sets output paths, but the archive path is resolved independently — against the **current
working directory**. A relative `--download-archive .archive.txt` therefore scatters archive
files into whatever directory you happened to run the command from, and every one of them
starts empty, so nothing is ever deduplicated. `djdl` passes an absolute path
(`$DJ_ROOT/.archive.txt`), and the option is deliberately kept out of the config file entirely.

**d. `--break-on-existing` is deliberately NOT used for playlist sync.**
It aborts the whole run at the first already-known track. Since playlists get insertions in the
*middle*, not just appended to the end, that means everything after the first known track is
silently skipped — you sync a playlist, it exits successfully, and you're missing half of it.
The `--download-archive` filter alone is correct: it skips known tracks individually and keeps
walking the full playlist.

### Also worth knowing

**`--audio-format aiff` does not exist in yt-dlp.** Despite AIFF being a classic DJ format with
excellent rekordbox support, it is not among yt-dlp's conversion targets. The lossless options
are **FLAC** and **ALAC**. Convert to AIFF afterwards with ffmpeg if you need it.

The config lives at `~/Music/DJ/yt-dlp.conf` and is picked up via `-P ~/Music/DJ`, deliberately
**not** at `~/.config/yt-dlp/config` — a global config containing `-x` silently breaks every
video download you ever attempt with yt-dlp for any other purpose.

## Layout

```
~/Music/DJ/
├── Incoming/        # search / get land here
├── Playlists/       # sync lands here, one folder per playlist
├── yt-dlp.conf      # the rekordbox-safe config
└── .archive.txt     # dedupe ledger — delete to force re-download
```

Environment overrides: `DJ_ROOT` (default `~/Music/DJ`), `YTDLP` (default `~/.local/bin/yt-dlp`).

## Legal

This is a tool for acquiring content you have the right to download — your own uploads, freely
licensed and promo material, Creative Commons releases, and tracks the rights holder has made
available for download. Check what applies to you; terms of service and local copyright law both
matter, and they aren't the same thing.

Downloading and public performance are separate questions. Playing tracks in a paid venue carries
its own licensing requirements — typically handled by the venue's PRO license (ASCAP/BMI/PRS or
your local equivalent) — regardless of how the file was obtained or whether you paid for it.

## License

MIT — see [LICENSE](LICENSE).
