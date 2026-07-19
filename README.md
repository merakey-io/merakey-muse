# merakey-muse

A rekordbox-oriented music acquisition and analysis CLI wrapping [yt-dlp](https://github.com/yt-dlp/yt-dlp).

`djdl` searches YouTube, YouTube Music, SoundCloud and Spotify, lets you pick tracks from a
numbered table, and downloads them into `~/Music/DJ/Incoming` in a format rekordbox will
actually import — with cleaned-up tags, no description spam in the comment field, and an
idempotent archive so re-runs never re-download.

It then **vets** what landed for laundered lossy sources, **scans** it for structural and
integrity problems, **analyses** BPM and key, and **ranks your library by what mixes next**.

```
djdl search -m "peggy gou starry night"
djdl vet                       # is it actually lossless?
djdl scan                      # is it actually an audio file?
djdl analyze                   # BPM + key (Camelot)
djdl mix "starry night"        # what plays after it
djdl rbxml                     # export a rekordbox XML collection
```

## Setup

macOS or Linux. Takes about two minutes.

### 1. Prerequisites

`ffmpeg` does the single Opus→FLAC decode and every analysis probe; `jq` parses search results.
Both are required.

```bash
# macOS
brew install ffmpeg jq

# Debian/Ubuntu
sudo apt install ffmpeg jq
```

**ffmpeg must be 8.1.2 or newer.** Versions below that carry **CVE-2026-8461** ("PixelSmash"), a
heap out-of-bounds write in the MagicYUV decoder with RCE demonstrated from a 50KB file. This is
not a theoretical exposure here: `djdl scan` and `djdl vet` exist specifically to decode
**untrusted** input, so a stale ffmpeg turns the two safety commands into the liability.
`install.sh` refuses to proceed below the floor, and `djdl doctor` re-checks it.

Optional, for specific subcommands:

```bash
brew install rsgain chromaprint aubio
```

`rsgain` backs `djdl gain`. `chromaprint` provides `fpcalc` for acoustic fingerprinting.
`aubio` is available as a second opinion on onset work — note that djdl's own analysis
deliberately does **not** use it, for the reason explained under [`djdl analyze`](#djdl-analyze--bpm-and-key).

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
- **enforces the ffmpeg 8.1.2 security floor**, refusing to install below it
- notes any missing optional tools (`rsgain`, `fpcalc`, `aubio`) without failing
- downloads the yt-dlp standalone binary to `~/.local/bin/yt-dlp` and updates it to nightly
- links `djdl`, `djdl-rbxml` and `djdl-engine` onto your PATH in `~/.local/bin`
- creates the Essentia analysis venv at `~/.local/share/muse-venv` (see below)
- creates `~/Music/DJ/Incoming`
- installs `config/yt-dlp.conf` to `~/Music/DJ/yt-dlp.conf`, **never overwriting an existing
  one** — if you've tuned yours, it says so and prints a `diff` command instead
- warns if `~/.local/bin` is not on your PATH, with the line to add to your shell rc
- finishes by running `djdl doctor`

By default the three commands are **symlinked** into the repo, so `git pull` updates them with
no re-install. The tradeoff is that moving or deleting the clone breaks them. For detached
copies instead:

```bash
MUSE_COPY=1 ./install.sh
```

### 3. The analysis venv — and why it is pinned to Python 3.14

`djdl analyze`, `mix` and `similar` run `djdl-engine` under a dedicated interpreter at
`~/.local/share/muse-venv`, holding [Essentia](https://essentia.upf.edu/).

```bash
uv venv --python 3.14 ~/.local/share/muse-venv
VIRTUAL_ENV=~/.local/share/muse-venv uv pip install essentia
```

**The Python version is not incidental — it is the entire reason this is a pinned venv rather
than a plain `pip install essentia`.** Essentia's current build ships a **cp314 arm64 wheel
only**, and there is **no sdist**. On Python 3.12 or 3.13, pip does not fail and does not warn
in any way you will notice — it silently resolves to a **much older July 2025 build**. You get a
working import, different behaviour, and no indication why. Pin to 3.14.

The installer does this for you when `uv` is present. If `uv` is missing it prints the commands
rather than failing, so the rest of the tool still installs.

### 4. Verify

```bash
djdl doctor
```

Every line should be green, ending with `extractor healthy`. `doctor` also runs the
[supply-chain checks](#supply-chain-hardening). If `~/.local/bin` wasn't on your PATH, open a new
terminal after adding it. If the extractor probe fails, run `djdl update` — that fixes it the
large majority of the time.

### 5. Optional: Spotify support

Only needed for the `spotify` subcommand.

```bash
uv tool install spotdl      # or: pipx install spotdl
```

Read the [Spotify caveat](#about-djdl-spotify) before relying on it — spotdl gives you YouTube audio
wearing Spotify metadata, not Spotify audio. And see the
[supply-chain section](#supply-chain-hardening) for the two spotdl flags you must never run.

### 6. First run

```bash
djdl search "artist track name"     # pick a row by number, Enter to cancel
djdl vet                            # check what landed
open ~/Music/DJ/Incoming            # drag into rekordbox
```

## Updating

There are **three independent things** that update on different schedules. Updating one does not
update the others, and the one that breaks most often is not the one you'd guess.

### 1. yt-dlp — the one that actually matters day to day

```bash
djdl update
```

This is the fix for roughly every "it suddenly stopped working". YouTube changes break extraction
regularly and the fix ships in nightly, often days before it reaches a stable release. **Run this
before debugging anything else** — a stale binary is the single most common cause of failure, and
it is indistinguishable from a real bug until you rule it out.

### 2. djdl itself

**If you installed with `install.sh` (the default), the three commands are symlinks into your
clone, so this is all you need:**

```bash
cd /path/to/merakey-muse && git pull
```

The new code is live immediately — no re-install step.

**If you used `MUSE_COPY=1`, or you have standalone copies**, `git pull` updates the repo but
**not** the installed commands. Check which you have:

```bash
ls -l ~/.local/bin/djdl ~/.local/bin/djdl-rbxml ~/.local/bin/djdl-engine
```

An arrow (`->`) means symlink and you're done after a pull. No arrow means a detached copy, and
you must re-run the installer to pick up changes:

```bash
cd /path/to/merakey-muse && git pull && ./install.sh
```

Re-running `install.sh` is always safe — it is idempotent.

### 3. Dependencies — only when a release adds one

`git pull` does not install new dependencies. If a release adds one, re-run `./install.sh`; it
detects what is missing and skips what is already present. To refresh Essentia specifically:

```bash
VIRTUAL_ENV=~/.local/share/muse-venv uv pip install --upgrade essentia
```

Keep ffmpeg current independently — `brew upgrade ffmpeg`. This is a **security** update, not a
feature one: see the [8.1.2 floor](#1-prerequisites). `djdl doctor` re-checks it.

### The config file is deliberately never updated

`install.sh` will **not** overwrite `~/Music/DJ/yt-dlp.conf` once it exists, on any re-run. That
file is the whole point of the tool and silently replacing a tuned copy would be destructive.

The tradeoff is that **config improvements do not reach you automatically.** After pulling a
release that changed it, diff and merge by hand:

```bash
diff ~/Music/DJ/yt-dlp.conf /path/to/merakey-muse/config/yt-dlp.conf
```

`install.sh` prints this exact command when it detects an existing config.

### After any update

```bash
djdl doctor
```

Confirms versions, the ffmpeg security floor, the yt-dlp advisory floor, plugin directories, and
that extraction still works.

## Suggested workflow

```
search  →  vet  →  scan  →  analyze  →  mix  →  rbxml  →  import
```

```bash
djdl search -m "…"     # acquire
djdl vet               # is it actually lossless? delete the flagged junk
djdl scan              # is it structurally sound and actually audio?
djdl analyze           # BPM + key, cached to .analysis.tsv
djdl mix "<track>"     # what follows it — sanity-check the crate hangs together
djdl rbxml             # emit rekordbox.xml carrying those keys
                       # import in rekordbox, let it build beatgrids
```

Vetting and scanning **before** import matters more than it sounds: once rekordbox has analysed
a track and written it into the collection, removing it cleanly is far more annoying than never
importing it. Gate at `Incoming`.

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
and `djdl mix` output to decide what to keep and what order to play it in.

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
| `djdl vet [dir]` | Quality gate. Flags lossy sources laundered into FLAC, dual-mono, mono, and true-peak clipping — plus integrated LUFS for every track. |
| `djdl scan [dir]` | Integrity check: container vs extension, executable headers, decode errors, malformed cover art, appended payloads, quarantine xattr. Explicitly **not** antivirus. |
| `djdl analyze [dir]` | BPM + key as Camelot via Essentia. Cached to `.analysis.tsv`. |
| `djdl mix <track\|bpm camelot>` | Rank the analysed library by what mixes next. |
| `djdl similar <artist>` | Related artists via Deezer. Keyless — no signup, no token, no OAuth. |
| `djdl gain [dir]` | Write ReplayGain 2.0 tags via `rsgain`. Read the caveat — **rekordbox ignores these**. |
| `djdl rbxml [dir] [out.xml]` | Export a rekordbox-importable XML collection, carrying detected keys. |
| `djdl ls` | What's staged in `Incoming`, with sizes and archive count. |
| `djdl update` | `yt-dlp --update-to nightly`. First thing to try when extraction breaks. |
| `djdl doctor` | Health check — versions, config, free space, supply-chain checks, live extractor probe. |

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

## `djdl scan` — integrity, explicitly not antivirus

```bash
djdl scan                   # ~/Music/DJ/Incoming
djdl scan ~/Music/DJ/Playlists/Warmup
```

`vet` asks *"is this good audio?"*. `scan` asks *"is this actually an audio file, and is it
intact?"* — a different question with different failure modes. Every check either passes or
names something concrete; nothing here is decorative.

| # | Check | What it catches |
|---|---|---|
| 1 | Container vs extension | A renamed file, or a polyglot whose extension misrepresents its contents |
| 2 | Executable magic | Mach-O, ELF, PE/DOS and shebangs at the head of something claiming to be music |
| 3 | Full decode | Truncated or corrupt files that import fine and then fail mid-set |
| 4 | Embedded cover art validity | Malformed images — a far bigger parser attack surface than audio decoders, and handed straight to an image parser by every player that shows artwork |
| 5 | Foreign payload grep | Appended ZIP/ELF/script/HTA content, **reported with its byte offset** |
| 6 | Quarantine xattr | Provenance only — see below |

### `ffprobe` is not authoritative for content type

This was a real bug in the first version, and it is the single most useful thing in this section.

**`ffprobe` falls back to extension-based detection.** Hand it a shell script named `.flac` and
it reports the format as `flac`. It is not silent about it — it emits
`Format flac detected only with low score of 1` — but that line is at **warning** level, so the
near-universal habit of running `ffprobe -v quiet` hides **exactly the signal that matters**.

`file(1)` is the authority. `scan` uses `file -b --mime-type` for the verdict and runs ffprobe at
`-v warning` specifically so the low-score line can be captured as corroboration rather than
discarded.

### Validated against hostile files

Every one of these was constructed and run:

| Test file | Result |
|---|---|
| `/bin/ls` renamed to `.flac` | Mach-O header caught |
| Shell script named `.mp3` | Shebang **and** ffprobe low-score caught |
| Truncated FLAC | Invalid residual on full decode |
| FLAC with a ZIP appended | Payload pinpointed at **byte offset 75674258** — exactly the original file size |
| Genuine 72MB FLAC with embedded JPEG art | **Zero false positives** |

The byte offset is the point of check 5: it marks precisely where the audio ended and something
else began. Do **not** try to derive this from ffprobe packet offsets — the demuxer absorbs
appended junk, so trailing bytes always compute to zero.

The payload half of a polyglot like this is typically Windows-targeted and inert on macOS, but a
hit is a high-confidence "deliberately constructed" signal either way.

### On the quarantine xattr

Provenance only, **never** a verdict. Opening a quarantined non-executable triggers no Gatekeeper
check, and yt-dlp does not set the xattr at all — so its **absence means nothing**. A present
xattr just tells you the file arrived via browser or AirDrop rather than through yt-dlp.

### There is deliberately no green "SAFE" badge

A clean run prints `no structural problems found`, not `SAFE`. That wording is deliberate and
worth defending.

These checks cover **file shape**. They do not and cannot cover **malformed-bitstream parser
exploits** — the CoreAudio zero-click class — where the malicious input is a valid-looking
stream that trips a bug inside the decoder, and the trigger is *indistinguishable from ordinary
corruption*. No scanner at this layer can separate the two. Claiming otherwise would be exactly
the security theater this is trying to avoid.

The control for that class is patching: keep macOS and ffmpeg current. See the ffmpeg 8.1.2 floor
above.

**And the larger real risk is supply chain, not the audio files.** yt-dlp and spotdl execute code
on your machine. The downloaded FLACs do not.

## Supply-chain hardening

This matters more than scanning the audio. `djdl doctor` checks all of it.

### yt-dlp plugins are off, on every single call

Every yt-dlp invocation in `djdl` funnels through one function that passes
**`--no-plugin-dirs --no-remote-components`**. This is not paranoia:

- yt-dlp plugins are **arbitrary Python**.
- They are **imported whether or not they are invoked**.
- **No checks are performed on their code.**
- **Extractor plugins take priority over built-ins** — so a file dropped into a user-writable
  plugin directory silently hijacks YouTube handling.
- **No flag is needed to enable them.** They are on by default if present, which is precisely why
  they have to be explicitly turned off.

`djdl doctor` additionally reports any plugin directories yt-dlp finds, so you learn about them
even though djdl itself is immune.

### `--exec` is never used. Neither is `--netrc-cmd` or `--write-*-link`

`--exec` has had **four** separate shell-injection breaks:

`CVE-2023-40581` → `CVE-2024-22423` → `CVE-2025-54072` → `GHSA-69qj-pvh9-c5wg`

Four rounds of "we fixed the quoting" is the argument. The rule here is **never use it**, not
*use it carefully* — a feature that hands user-controlled strings to a shell is not made safe by
the next patch. `--netrc-cmd` and `--write-*-link` are absent for the same reason.

### Version floors, checked by `doctor`

| Component | Floor | Why |
|---|---|---|
| ffmpeg | **8.1.2** | CVE-2026-8461 "PixelSmash" — heap OOB write in the MagicYUV decoder, RCE from a 50KB file. `scan` and `vet` decode untrusted input. |
| yt-dlp | **2026.07.04** | Advisory floor: fixes the `--exec` shell injection (GHSA-69qj-pvh9-c5wg) and `--write-link` (CVE-2026-55404). |

Both comparisons are strictly-less-than. `sort -V -C` alone treats equal as sorted, so an
exactly-patched version would otherwise report as vulnerable.

### If you use spotdl: two flags to never run

```
spotdl --download-ffmpeg      # ← never
spotdl --download-deno        # ← never
```

Both **fetch executables at runtime and `chmod +x` them, with no hash and no signature check**.
That is an unauthenticated code-execution path opened by a convenience flag. Provision those
dependencies through Homebrew instead, where you get a package manager's integrity guarantees:

```bash
brew install ffmpeg deno
```

## `djdl analyze` — BPM and key

```bash
djdl analyze                # ~/Music/DJ/Incoming
djdl analyze ~/Music/DJ/Playlists/Warmup
```

Runs [Essentia](https://essentia.upf.edu/) over every track and writes BPM, rhythm confidence,
key in **Camelot** notation, key in classical notation, and key confidence to
`~/Music/DJ/.analysis.tsv`. rekordbox does its own authoritative analysis on import, so this
exists to inform decisions **before** that — which tracks sit in the same tempo range, what
actually mixes with what, and what to feed `rbxml`.

```
TRACK                                          BPM   CONF    KEY  CLASS
Invasion - Abdução                          144.86    ...     7B      F
```

Verified end to end on a real track: **Invasion – Abdução → 144.86 BPM, 7B (F major)**, with all
three profiles agreeing (no `*` on the key confidence).

### Constrain the tempo search to one octave

This is the single most important setting in the whole analysis path, and it is the reason for
the tool choice.

`RhythmExtractor2013` runs in `multifeature` mode with `minTempo=110, maxTempo=180`. **Every**
tempo detector defaults into the wrong octave on ambiguous material — 174 BPM drum & bass
reported as 87, or 140 reported as 70. It is not a bug in any particular library; it is inherent
to the problem, because half-time and double-time are genuinely both correct answers to "what is
the pulse here?" until you constrain the range.

**This one setting fixes more errors than any tool choice.**

Which is exactly why **aubio was dropped**: it has **no tempo-range flag at all**. A faster,
lighter detector that cannot be constrained to an octave is the wrong trade for this job, and no
amount of post-processing recovers the information cleanly.

### Key: the `edma` profile, and never `edmm`

Key detection uses `KeyExtractor(profileType="edma")` — a Beatport/EDM-derived profile — **never
the classical default**, which is tuned for tonal repertoire that shares very little with club
music's static harmony and prominent bass.

**Never use `edmm`, despite the promising name.** It carries a severe **minor-key bias** and
mislabels clean major progressions as their relative minor. The extra `m` is not "more EDM"; it
is a different and, for this purpose, worse profile.

### Two profiles, and the `*` marker

`analyze` runs **two** profiles — `edma` and `bgate` — and reports whether they agreed. A
trailing **`*`** on the key confidence means **they disagreed**, which is the honest signal that
the key is a guess rather than a reading.

Here is the useful part: where they disagree, they usually disagree into the **relative
major/minor** — the same Camelot number, different letter. Camelot treats that as a valid mix
anyway. So the most common disagreement is **the cheapest possible error**, and a `*` is a
caution rather than a rejection.

### Rhythm confidence

`CONF` below **1.5** means the BPM is a guess: beatless, rubato, ambient or free-time material
where there is no stable pulse to find. The column is highlighted when it drops below that.
Treat those BPMs as decoration, not data.

## `djdl mix` — what plays next

```bash
djdl mix "starry night"     # seed from an analysed track (substring match)
djdl mix 140 8A             # seed from an explicit BPM + Camelot key
```

Ranks every analysed track by how well it follows the seed, and **says why**:

```
 SCORE  HARM   BPM  TRACK                              BPM   KEY  WHY
  96.1    95   100  Perfect Fifth Track              140.4    9A  adjacent (perfect 5th), 0.3% pitch
  92.3    90   100  Relative Minor Track             141.0    8B  relative major/minor, 0.7% pitch
  31.3     8   100  Tritone Track                    140.0    2A  TRITONE CLASH, 0.0% pitch
  23.0    22    44  Same Key, Too Fast               148.0    8A  clash (7 steps) via 3A, 5.7% pitch
```

Note the last row: that track is in **8A, the same key as the seed** — and it ranks near the
bottom, because reaching 140 BPM from 148 pitches it into 3A. That is the transposition
correction doing its job.

The seed is excluded from its own ranking — it would always score 100.

### The weights, and why they are what they are

**0.45 harmonic · 0.35 BPM · 0.20 energy**

The ordering is not arbitrary:

- **Harmonic errors are what the audience hears as wrong.** A key clash is audible to people who
  have never thought about keys in their lives. It gets the largest vote.
- **Tempo errors are what you can fix with the pitch fader.** A recoverable problem should not
  outrank an unrecoverable one.
- **Energy is a weak estimator**, so it gets the smallest vote. See
  [Limitations](#limitations--stated-honestly-1) — it is currently fed a constant, and the 0.20
  weight is a deliberate ceiling on how much a weak signal can move the ranking.

### 1. Gating is mandatory — a weighted mean alone recommends key clashes

This is load-bearing. **Any scoring function without gating will recommend tritone clashes**, and
here is the measurement that proves it.

Take a tritone clash (harmonic score 8) with *perfect* BPM and *perfect* energy match:

```
plain weighted mean:  0.45×8 + 0.35×100 + 0.20×100  =  58.6
```

**58.6 out of 100.** That lands it in recommended territory. Perfect tempo and energy simply
**outvote** the worst harmonic relationship in music, because that is what averaging does — it
lets strong dimensions compensate for a fatal one.

Real mixing does not average. A key clash is **disqualifying**, and the gate is what encodes
that. The weighted sum is passed through two **multiplicative** gates:

```python
total *= 0.35 + 0.65 * (h / 100) ** 0.5     # harmonic gate
total *= 0.40 + 0.60 * (b / 100) ** 0.5     # tempo gate
```

```
after gating:  58.6 × 0.534  =  31.3
```

**58.6 → 31.3.** Both numbers were measured, not estimated. The track drops out of contention,
which is the correct behaviour. The square root keeps the gates from being cliffs — a merely
*mediocre* match is attenuated proportionally rather than annihilated.

### 2. Pitching to match tempo transposes the track

The detail almost every "harmonic mixing" tool gets wrong: **if you speed a track up to match
tempo, you have changed its key.**

**±6% is the CDJ default pitch range**, and:

```
12 × log2(1.06)  =  1.009 semitones
```

One semitone is **+7 positions around the Camelot wheel** (a semitone up is a perfect fifth's
worth of wheel movement — see the units note below). So at the edge of the default pitch range,
**a track is 7 Camelot steps away from where it is labelled**.

`mix` accounts for this. It computes the drift, transposes the candidate's key, and reports the
key it will *actually* be in when it is playing:

```
seed 140 BPM / 8A, candidate at 148 BPM  →  clash (7 steps) via 3A
```

That candidate is **also in 8A**. On paper it is a perfect key match. Pitched up 5.7% to reach
140, it arrives in **3A** — and 8A against 3A is a 7-step clash. A tool that ignores this would
rank it first.

**The 0.25-semitone deadzone.** Below a quarter semitone the shift is inaudible and is completely
standard DJ practice, so it must cost **nothing**. Penalising it was measurably wrong: a same-key
match at 0.4% pitch scored 92 instead of 100, and — worse — it pushed a **perfect-fifth move
below a relative major/minor one**, inverting the correct ordering. The penalty exists for
landing *between* semitones at large drift, where the track is out of tune with **itself** (worse
than either neighbouring key), not for touching the pitch fader at all.

Half-time and double-time are recognised as legitimate moves and scored at a small (×0.85)
discount — valid, but deliberate.

### The Camelot wheel

| Camelot | Key | | Camelot | Key |
|---|---|---|---|---|
| **1A** | A♭ / G♯ minor | | **1B** | B major |
| **2A** | E♭ / D♯ minor | | **2B** | F♯ / G♭ major |
| **3A** | B♭ / A♯ minor | | **3B** | D♭ / C♯ major |
| **4A** | F minor | | **4B** | A♭ / G♯ major |
| **5A** | C minor | | **5B** | E♭ / D♯ major |
| **6A** | G minor | | **6B** | B♭ / A♯ major |
| **7A** | D minor | | **7B** | F major |
| **8A** | A minor | | **8B** | C major |
| **9A** | E minor | | **9B** | G major |
| **10A** | B minor | | **10B** | D major |
| **11A** | F♯ / G♭ minor | | **11B** | A major |
| **12A** | C♯ / D♭ minor | | **12B** | E major |

The table is validated on two invariants: **relative major/minor = −3 semitones**, and **+1 wheel
step = +7 semitones** (a perfect fifth).

### Move safety, best to worst

| Move | Score | Meaning |
|---|---|---|
| Same key | 100 | 8A → 8A |
| ±1, same letter | 95 | 8A → 9A or 7A — **perfect fifth**, the classic move |
| Same number, other letter | 90 | 8A → 8B — relative major/minor |
| +2, same letter | 78 | 8A → 10A — **energy boost** |
| −2, same letter | 74 | 8A → 6A — energy drop |
| ±1, other letter | 70 | 8A → 9B — diagonal |
| ±3, same letter | 40 | distant |
| Tritone (6 apart) | **8** | 8A → 2A — **avoid** |

### A units confusion worth naming: "+7 semitones"

You will see advice online to move **"+7 semitones"** for an energy boost. This is a
**units error**, and following it does the wrong thing.

**+7 semitones *is* +1 on the Camelot wheel** — that is the perfect fifth, the standard smooth
move. Someone has confused the semitone interval with the wheel position.

**The energy boost is +2 on the wheel**, which is +2 fifths — i.e. +14 semitones, or a whole tone
in pitch-class terms. If you actually shift +7 wheel *positions* you land on the clash shown in
the pitch example above.

## `djdl similar` — related artists, keyless

```bash
djdl similar "Infected Mushroom"
```

Uses the **Deezer** related-artists endpoint. **Keyless: no signup, no token, no OAuth, no
registered app.** It just works from a clean machine.

Verified — seeding "Infected Mushroom" returns:

> Astrix · Ace Ventura · Blastoyz · Captain Hook · Liquid Soul · Skazi

That is a genuinely good psytrance neighbourhood, not a generic "electronic" spray.

### Why not Spotify — the approach nearly every guide suggests

**Spotify's `/recommendations` and `/audio-features` endpoints were withdrawn on 2024-11-27 for
new and development-mode applications.** That is the API almost every "build a DJ crate tool"
tutorial is built on, including ones still being published. It is simply not available to a new
app any more — you cannot get access by reading the docs more carefully or by applying. The route
is closed.

This is worth stating plainly because the failure is confusing in practice: the endpoints still
exist and are still documented, and you get a `403` that reads like a scope or auth problem
rather than a policy withdrawal.

### Why not ListenBrainz or Last.fm

- **ListenBrainz** — open and well-intentioned, but noticeably **weaker on electronic music**,
  which is the material this tool exists for.
- **Last.fm** — good similarity data, but its **terms of service cap how much data you may
  store**. Caching a similarity graph, which is the obvious way to build anything useful on top,
  **breaches those terms**. Better to not build on a foundation you have to violate to use.

Deezer has neither problem.

## `djdl gain` — ReplayGain 2.0, and the honest caveat

```bash
djdl gain                   # ~/Music/DJ/Incoming
```

Writes ReplayGain 2.0 tags (EBU R128, −18 LUFS reference) in place via `rsgain`.

### Read this before using it: rekordbox does not read ReplayGain tags

**At all.** Not partially, not with a preference toggle — rekordbox ignores ReplayGain tags
entirely. It computes its **own** Auto Gain value into its **own** database, and that value does
**not even survive USB export to CDJs**.

So for the **rekordbox → CDJ path this command is near-pointless**, and it is opt-in for exactly
that reason. It is not part of the suggested workflow.

It has genuine value if — and only if — your library is *also* used for listening:
**Mixxx, foobar2000 and VLC all honour ReplayGain properly.** If the same folder feeds both a DJ
workflow and a listening workflow, tag it. If it only ever feeds rekordbox, don't bother.

### The useful half is already in `vet` and `analyze`

**Reporting** LUFS and true peak is actionable at download time — it tells you which tracks are
mastered hot, which will clip, and how to gain-stage before you are mid-transition. That is what
`vet` already does for every file it touches.

**A tag nothing in your chain reads is not actionable.** That is the whole distinction, and it is
why the measurement lives in `vet` while the tagging is a separate opt-in command.

### Avoid `metaflac --add-replay-gain`

It uses the **pre-R128 algorithm** (the original 2001 ReplayGain, −89 dB SPL reference), not
ReplayGain 2.0 / EBU R128. Mixing the two across a library gives you inconsistent gain values
that are worse than none. Use `rsgain`.

## `djdl rbxml` — rekordbox XML export

```bash
djdl rbxml                              # Incoming -> ~/Music/DJ/rekordbox.xml
djdl rbxml ~/Music/DJ/Playlists/Warmup  # any folder
djdl rbxml ~/Music/DJ/Incoming out.xml  # explicit output path
```

Emits a rekordbox-importable XML collection. Import is **additive and non-destructive**:
rekordbox shows it as a separate browsable panel, and nothing enters your real collection until
you explicitly import. Tracks are **referenced in place, never copied**.

To import in rekordbox 7:

1. **Preferences → View → Layout** → tick **rekordbox xml**
2. **Preferences → Advanced → Database → Imported Library → Browse** → select
   `~/Music/DJ/rekordbox.xml`
3. The tree appears in the left sidebar under **rekordbox xml**. Right-click tracks →
   **Import To Collection**.

**Known rekordbox bug:** tracks already in your collection are **not** updated on re-import.
Select the tracks *inside* the playlist and import those, rather than importing the playlist
node, or the update is silently skipped.

### It writes your detected keys — in classical notation

If `.analysis.tsv` exists, `rbxml` writes each track's detected key into the **`Tonality`**
attribute, in **classical** notation (`Am`, `F#m`, `F`) — **never Camelot**.

This is not a style preference. **`Tonality` is a free string field**, so a Camelot value like
`8A` does not error — it **fails silently**, leaving you a blank or junk key with no indication
anything went wrong. Camelot is a *display* preference inside the rekordbox UI, never a storage
format.

**Why supply keys at all?** Because **rekordbox's own key detection benchmarks around 70%
accuracy (59.9% strict)**. An externally computed key is a real improvement, not a redundancy.
So you can untick **KEY** in **Preferences → Analysis** and use these instead, via right-click →
**Reload Tags**.

Note the division of labour precisely: **rekordbox stays authoritative for the beatgrid**, not
for key.

### TEMPO elements are deliberately not emitted

`AverageBpm` is written — it is useful for sorting and filtering. **`TEMPO` (beatgrid) elements
are not.**

A `TEMPO` marker requires an accurate first-downbeat position (`Inizio`). A slightly wrong
`Inizio` produces a **phase-shifted grid**, which is **actively worse than no grid at all** —
because rekordbox *trusts* a supplied grid and will not re-derive it. You would be shipping a
confident wrong answer in place of an absent one. Let rekordbox build the beatgrid; that is the
thing it is genuinely good at.

### Other format facts, verified against rekordbox 7.2.11

From Pioneer's `xml_format_list.pdf`, confirmed against a real binary:

- `Location` **must** be `file://localhost/` + percent-encoded UTF-8, `safe=":/"`. Never
  `quote_plus` — `+` for space breaks path resolution.
- `Rating` is **0/51/102/153/204/255** for 0–5 stars. Writing `"4"` gives you **zero** stars.
- `TotalTime` must be set or cue points misbehave.
- `COLLECTION/@Entries` and `NODE/@Count`/`@Entries` must equal the real child counts. Mismatches
  cause truncated or empty imports.
- Numbers must be **locale-independent** (dot decimal). A comma decimal from a `de_DE`/`pt_BR`
  locale corrupts the beatgrid.
- UTF-8 **without BOM**. A BOM ahead of the declaration chokes the parser.
- Paths are **not** Unicode-normalized. The filesystem's own byte sequence is the only
  representation guaranteed correct across APFS, HFS+ and exFAT — and **exFAT, the DJ USB
  standard, is normalization-sensitive**, so normalizing here would break exactly the case that
  matters most.
- Attribute values are escaped by ElementTree. An unescaped `&` in an artist name is the top
  cause of a hard parse failure ("unable to be read properly").

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

## Limitations — stated honestly

### Energy scoring is a placeholder

The `mix` formula carries energy at a **0.20 weight**, and it is currently **fed a constant**.
Every candidate gets the same energy value, so that term contributes nothing to the ranking today.
It is in the formula because the shape is right, not because the input is.

Why it is not implemented yet:

- **Essentia's `Danceability` is inverted for this purpose** and unusable. Ambient tracks score
  *higher* than hardcore. It is measuring something real — it just isn't measuring what a DJ
  means by "energy".
- A **z-scored blend of spectral flux + RMS + spectral centroid + BPM does rank correctly** in
  testing. The blocker is calibration: z-scoring needs a stable reference distribution, and that
  takes roughly **200 analysed tracks** before the scores stop moving around as the library
  grows. Shipping it under-calibrated would mean rankings that change meaning as you add music.

### LUFS is not energy — it is mastering era

Tempting shortcut, actively wrong. **Integrated LUFS measures how hard a track was mastered**,
which tracks the loudness war far more closely than it tracks musical intensity. Feed LUFS into
an energy score and **you sort your crate by release year**. A 1994 original and a 2019 remaster
of the same record land in completely different places.

LUFS is reported by `vet` because it is genuinely useful for **gain staging**. It is kept out of
the energy term on purpose.

### YouTube Music radio expansion: researched, not implemented

An obvious-looking discovery feature — seed a track, pull its YouTube Music radio, harvest the
queue. It was researched and rejected: **the radio returns roughly 68% the seed artist**.

That makes it a **discography expander**, not a discovery tool. It is a reasonable feature to
have, but it is not the feature it appears to be, and shipping it as "find similar music" would
misrepresent what it does. `djdl similar` (Deezer) is the discovery path.

### Scope limits carried over

- `vet` characterises a **60-second window from 0:30**, not the whole track.
- `scan` checks **file shape, not exploits** — see [that section](#there-is-deliberately-no-green-safe-badge).
- Both **report rather than delete**. Nothing is ever removed automatically.

## Layout

```
~/Music/DJ/
├── Incoming/        # search / get land here
├── Playlists/       # sync lands here, one folder per playlist
├── yt-dlp.conf      # the rekordbox-safe config
├── rekordbox.xml    # written by `djdl rbxml`
├── .analysis.tsv    # BPM + key cache, written by `djdl analyze`
└── .archive.txt     # dedupe ledger — delete to force re-download

~/.local/bin/        # djdl, djdl-rbxml, djdl-engine, yt-dlp
~/.local/share/muse-venv/    # Python 3.14 + Essentia
```

Environment overrides: `DJ_ROOT` (default `~/Music/DJ`), `YTDLP` (default
`~/.local/bin/yt-dlp`), `MUSE_VENV` (default `~/.local/share/muse-venv`, install-time).

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
