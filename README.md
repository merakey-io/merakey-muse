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
djdl vet
```

## Setup

macOS or Linux. Takes about two minutes.

### 1. Prerequisites

`ffmpeg` does the single Opus→FLAC decode; `jq` parses search results. Both are required.

```bash
# macOS
brew install ffmpeg jq

# Debian/Ubuntu
sudo apt install ffmpeg jq
```

You do **not** need to install yt-dlp yourself — the installer handles it, and deliberately
uses the standalone binary rather than a brew or pip package so it can self-update to nightly.
That matters: YouTube extractor breakage is routinely fixed in nightly days before it reaches a
stable release, and a stale binary is the single most common cause of "it stopped working".

### 2. Install

```bash
git clone https://github.com/merakey-io/merakey-muse.git
cd merakey-muse
./install.sh
```

The installer is idempotent — safe to re-run. It:

- verifies `ffmpeg` and `jq`, failing with install hints if either is missing
- downloads the yt-dlp standalone binary to `~/.local/bin/yt-dlp` and updates it to nightly
- links `djdl` onto your PATH at `~/.local/bin/djdl`
- creates `~/Music/DJ/Incoming`
- installs `config/yt-dlp.conf` to `~/Music/DJ/yt-dlp.conf`, **never overwriting an existing
  one** — if you've tuned yours, it says so and prints a `diff` command instead
- warns if `~/.local/bin` is not on your PATH, with the line to add to your shell rc
- finishes by running `djdl doctor`

By default `djdl` is **symlinked** into the repo, so `git pull` updates the installed command
with no re-install. The tradeoff is that moving or deleting the clone breaks the command. For a
detached copy instead:

```bash
MUSE_COPY=1 ./install.sh
```

### 3. Verify

```bash
djdl doctor
```

Every line should be green, ending with `extractor healthy`. If `~/.local/bin` wasn't on your
PATH, open a new terminal after adding it. If the extractor probe fails, run `djdl update` — that
fixes it the large majority of the time.

### 4. Optional: Spotify support

Only needed for the `spotify` subcommand.

```bash
uv tool install spotdl      # or: pipx install spotdl
```

Read the [Spotify caveat](#about-djdl-spotify) before relying on it — spotdl gives you YouTube audio
wearing Spotify metadata, not Spotify audio.

### 5. First run

```bash
djdl search "artist track name"     # pick a row by number, Enter to cancel
djdl vet                            # check what landed
open ~/Music/DJ/Incoming            # drag into rekordbox
```

## Using it with Claude Code

`djdl` is built to be driven conversationally. From the repo directory:

```bash
claude
```

Then tell Claude:

> Read the README, then help me find and download music with `djdl`. Search for tracks, show me
> the results, and download the ones I pick.

Claude runs the search, shows you the numbered table, and pipes your selection back in — so you
just say *"find me Peggy Gou — Starry Night"* and then *"grab 2 and 4."* This works because the
picker reads plain stdin (see [Driving the picker non-interactively](#driving-the-picker-non-interactively)).

Claude is genuinely useful for the judgement calls here: picking the official upload over an
`(HQ)` reupload, spotting a pitch-shifted or sped-up rip in the results, and reading `djdl vet`
output to decide what to delete before importing.

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
| `djdl search [-m\|-s] [-n N] <query>` | Search, render a numbered table, pick rows, download. `-m` = YouTube Music, `-s` = SoundCloud (edits, bootlegs), default = YouTube. `-n N` sets result count (default 12). Selection accepts numbers (`1 3 5`), ranges (`1-4`), `a` for all, Enter to cancel. |
| `djdl get <url>...` | Download URLs directly, same pipeline. |
| `djdl sync <playlist-url> [name]` | Idempotent playlist sync into `~/Music/DJ/Playlists/<name>/`. Re-run any time; the archive skips what you already have. |
| `djdl spotify <url>` | Spotify playlist via `spotdl`. |
| `djdl vet [dir]` | Quality gate. Analyses every audio file in `dir` (default `~/Music/DJ/Incoming`) and flags lossy sources laundered into FLAC, dual-mono, mono, and true-peak clipping — plus integrated LUFS for every track. |
| `djdl ls` | What's staged in `Incoming`, with sizes and archive count. |
| `djdl update` | `yt-dlp --update-to nightly`. First thing to try when extraction breaks. |
| `djdl doctor` | Health check — versions, config presence, free space, and a live YouTube extractor probe. |

### There is no `ytmsearch:` prefix — another wrong-but-popular claim

`-m` used to build a `ytmsearch12:` query. That scheme **does not exist in yt-dlp** and fails with
`Unsupported url scheme: "ytmsearch"`. Plenty of guides and answers assert it works; they are wrong.
`yt-dlp --list-extractors | grep -i search` shows what is real: there is `youtube:search`,
`soundcloud:search` (so `ytsearch:` and `scsearch:` are both genuine prefixes), but for YouTube Music
only `youtube:music:search_url` — a URL extractor, not a prefix. `-m` therefore builds a
`https://music.youtube.com/search?q=…` URL instead.

Two consequences worth knowing:

- YT Music search returns album and artist *browse* entries (`MPRE…` ids, no title) mixed in with
  tracks. Untitled entries are filtered out so the picker only offers playable rows.
- `--flat-playlist` metadata from YT Music and SoundCloud omits duration and uploader, so those rows
  show `?:??` / `?` and the duration-based `long/loop?` warning cannot fire. Plain YouTube search
  returns both. Judge `-m` and `-s` results by title alone.

### Search result warnings

`search` flags uploads that are unusable in a set. The pitch- and tempo-altered ones are the
dangerous category: rekordbox will happily analyse a "sped up" or "432Hz" rip and report a key
and BPM that are simply **wrong**, silently poisoning harmonic mixing. Flagged:
`pitch-shifted` (432Hz), `tempo-altered` (nightcore / sped up / slowed / reverb),
`long/loop?` (over 12 minutes), `live rip`.

### Driving the picker non-interactively

The selection prompt reads plain stdin, so a choice can simply be piped in:

```bash
echo "1 3" | djdl search -m "artist track"
echo 2 | djdl search "artist track"
```

Same syntax as the interactive prompt — numbers, ranges, `a` for all. This makes `search`
scriptable and lets agents drive it without a terminal. (Reading from `/dev/tty` instead would
break this: the `[[ -r /dev/tty ]]` test passes under a pipe while the read itself fails, and
the selection silently cancels.)

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

## `djdl vet` — the quality gate

```bash
djdl vet                    # ~/Music/DJ/Incoming
djdl vet ~/Music/DJ/Playlists/Warmup
```

Files arrive from a lot of places, and the file extension tells you almost nothing about what
is actually inside. `vet` opens each one and reports what it finds, in a single table.

### 1. Lossy sources laundered into FLAC

This is the headline feature and the reason the command exists.

**A FLAC container proves nothing about what went into it.** Someone can take a 96kbps MP3,
decode it, and re-wrap the result as FLAC. The file is now genuinely lossless — losslessly
preserving audio that was already destroyed. It reports as 44.1kHz/16-bit FLAC, it is 30MB,
rekordbox imports it without complaint, and it sounds like a 96kbps MP3 on a club system.
Nothing in the metadata will ever tell you.

The tell is spectral. **Every lossy encoder lowpasses** — throwing away the top of the
spectrum is one of the main things that buys the bitrate saving — and the lower the bitrate,
the lower the cutoff. Roughly 15kHz at 96kbps; roughly 20kHz for YouTube's 160kbps Opus. A
genuinely lossless source has content running all the way up.

So `vet` measures the **slope** of that rolloff: it probes energy above 13kHz and above 19kHz,
and reports how many dB the signal falls between the two. A codec lowpass is a **cliff**. Real
content — however dark — **tapers**.

**The obvious approach is wrong, and it produced a real false positive.** The first version of
this thresholded on the *absolute* level above 17kHz: quiet up there meant fake. It flagged the
first genuine track it was ever run against — a solo ragtime piano piece from a perfectly
legitimate 133kbps Opus YouTube stream — as a lossy source. Quiet treble almost always means
quiet **content**, not a codec artifact. Sparse-HF material is everywhere: solo piano, dub,
ambient, anything softly played or darkly mastered. An absolute threshold condemns all of it.

Measured on three real files:

| File | 13kHz | 19kHz | Slope |
|---|---|---|---|
| genuine bright music | -30.7 dB | -49.6 dB | **-18.9 dB** |
| solo piano (legitimate, sparse HF) | -56.6 dB | -71.3 dB | **-14.7 dB** |
| 96k transcode re-wrapped as FLAC | -34.7 dB | -79.5 dB | **-44.8 dB** |

This is the whole argument in one table. The piano sits **26dB lower** than the bright track in
absolute terms — which is exactly what got it wrongly flagged — yet its slope is just as gentle,
in fact slightly gentler. Only the transcode falls off a cliff. Slope separates the codec from
the content; absolute level cannot.

| 13kHz→19kHz slope | Verdict |
|---|---|
| better than -28 dB | `ok` |
| -28 to -35 dB | `marginal HF` |
| below -35 dB | `lossy source` |

Thresholds sit in the wide gap between the measured genuine cases (-14.7, -18.9) and the
measured transcode (-44.8), with margin on both sides. All three files classify correctly.

**Implementation note, worth recording because it is easy to get wrong:** each probe point
requires a *steep* filter — a 4-stage chain of 2-pole highpasses. A single `highpass` is a
gentle rolloff, not a wall. It leaks bass energy straight into the measurement, and since bass
dominates the energy of most tracks, that leakage swamps the signal you are looking for. It
collapses the real gap to about 3dB and the test becomes useless. This applies at **both** the
13kHz and 19kHz probes — if you ever touch `hp_at`, this is what you are protecting.

### 2. Dual-mono

Two channels carrying an identical signal: a stereo file with no stereo image at all. Fine on
laptop speakers, immediately obvious on a club rig.

Detected via the **side signal** (L−R). If the side is effectively silent (below -70dB), the
two channels are identical. The obvious alternative — comparing per-channel RMS — is **wrong**,
and worth stating plainly: a wide, properly mixed stereo track can easily have near-equal RMS
in both channels while being nothing like dual-mono. Equal energy is not equal signal.

### 3. Mono

Flagged plainly as `MONO`. No detection subtlety here, but you want it in the table.

### 4. True peak above 0 dBTP

Flagged as `+peak`. Inter-sample peaks over full scale will clip on D/A conversion and again in
the CDJ's own limiter. Common in loud masters, but you want to know before it is in the mix,
not during.

### 5. Integrated LUFS

Reported for every track, whether or not anything is flagged. This is gain staging: knowing
your tracks sit at, say, -8 and -14 LUFS before you play them means you are not discovering it
by riding the trim mid-transition.

### Limitations — stated honestly

`vet` analyses a **60-second window starting at 0:30**. That skips intros and lead-in silence
(which would poison the spectral measurement) and bounds runtime across a large folder. The
consequence is real: it characterises the **body of the track**, not every moment of it. A file
that is clean in its middle minute and broken elsewhere will pass.

It also **reports rather than deletes**. Nothing is ever removed automatically — the verdicts
are information for you to act on.

### Workflow

```bash
djdl search -m "…"     # acquire
djdl vet               # inspect what actually landed
                       # delete the flagged junk yourself
                       # then import ~/Music/DJ/Incoming into rekordbox
```

Vetting before import matters more than it sounds: once rekordbox has analysed a track and
written it into the collection, removing it cleanly is far more annoying than never importing
it. Gate at `Incoming`.

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
