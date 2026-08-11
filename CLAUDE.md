# CLAUDE.md

Guidance for Claude Code (or any Claude instance) working in this repo.

## What this is

A single-purpose Docker container: pulls an RTSP stream from a Eufycam
and restreams it to YouTube Live via RTMP, restarting itself
automatically on failure. Everything is configured through environment
variables — there is intentionally no CLI, no config file format to
design, no web UI. Keep it that way; resist scope creep.

The image is published to GHCR
(`ghcr.io/ssumichrast/eufycam-youtube-restream`) by GitHub Actions;
most users pull it rather than building.

## Files and their job

- `rootfs/usr/local/bin/entrypoint.sh` — the entire logic lives here:
  builds the RTSP URL from the address/username/password, auto-detects
  whether the camera has an audio track, builds the ffmpeg command, and
  supervises it in a restart loop. This is the file that almost every
  change will touch. The `rootfs/` prefix mirrors where it lands in the
  image.
- `Dockerfile` — Alpine + ffmpeg, nothing else. Keep the image minimal;
  don't add packages without a concrete reason. Base image is pinned by
  digest — update the tag and digest together.
- `compose.yaml` — restart policy, `.env` wiring, log rotation. Declares
  both `image:` (pull the published image) and `build:` (so
  `docker compose up --build` still works for development).
- `deploy/k8s/` — Deployment + Secret template for cluster deployment.
- `.github/workflows/` — `ci.yml` lints and builds without pushing;
  `release.yml` builds multi-arch and pushes to GHCR.
- `.env.example` — the source of truth for every environment variable
  the project supports. **Any new env var `entrypoint.sh` reads must be
  added here too**, with a comment explaining it, or it doesn't exist
  as far as a new user is concerned.
- `README.md` — user-facing setup and troubleshooting docs.

## Required environment variables (do not break these)

`CAMERA_RTSP_ADDRESS`, `CAMERA_USERNAME`, `CAMERA_PASSWORD`,
`YOUTUBE_INGEST_URL`, `YOUTUBE_STREAM_KEY` — this is the five-parameter
contract the project was built around. All five must stay required
(the `: "${VAR:?...}"` guards at the top of `entrypoint.sh`) and stay
env-var-driven. Don't turn any of these into a CLI flag, a mounted
config file, or a hardcoded default.

## Behaviors to preserve when editing `entrypoint.sh`

- **ffmpeg-level restart loop, not container-level.** The script
  restarts ffmpeg internally on any exit rather than exiting the
  container process itself. `docker-compose.yml`'s `restart:
  unless-stopped` is only a backstop for the container dying outright.
  Don't collapse these into one restart mechanism — the two exist for
  different failure modes (transient stream drop vs. the container
  itself crashing).
- **Graceful shutdown.** `SIGTERM`/`SIGINT` are trapped and forwarded
  to the ffmpeg child so `docker stop` / `docker restart` work cleanly.
  If you change the supervisor loop structure, keep this working —
  test with `docker compose stop` and confirm it doesn't hang until the
  kill timeout.
- **Camera audio is never streamed. This is deliberate.** The script
  maps only `0:v:0` from the camera and pairs it with a locally
  generated `anullsrc` silent track. Do not add a `-map 0:a` path, an
  `AUDIO_MODE=aac`, or an audio probe back in — the owner explicitly
  does not want the microphone captured or transmitted, and CI fails
  the build if `-map 0:a` reappears in the entrypoint. The silent track
  itself must stay: YouTube Live expects an audio stream to exist and a
  track-less stream often won't go live, which is why `silent` is both
  the default and the fallback for an unrecognized `AUDIO_MODE`.
  (`AUDIO_MODE=none` is a deliberate escape hatch, not the default.)
  This replaced an earlier auto-detect-and-transcode design; removing
  it also removed the `ffprobe` probe, `PROBE_TIMEOUT_SECONDS`, an
  `aresample=async=1` workaround for the camera's drifting audio
  clock, and the `coreutils` package (the probe was the only user of
  `timeout`).
- **Credential URL-encoding.** Username/password are run through
  `urlencode` before being spliced into the RTSP URL so special
  characters (`@`, `#`, etc.) in a camera password don't break the URL.
  Keep this if you touch RTSP URL construction.
- **Video defaults to `copy` (no re-encode).** `VIDEO_MODE=encode` is
  an opt-in escape hatch for cameras that output codecs YouTube
  rejects (e.g. H.265). Don't change the default — most users don't
  need the CPU cost of transcoding.
- **`-timeout`, never `-rw_timeout`, on the RTSP input.** `-timeout` is
  the RTSP demuxer's socket I/O timeout (microseconds). `-rw_timeout`
  looks equivalent and is *silently accepted* — no error, no warning —
  but has no effect on the RTSP demuxer. With it, a half-open
  connection to the camera hangs ffmpeg indefinitely; ffmpeg never
  exits, so the restart loop never fires and the stream stays dark.
  This was a real bug in the original version. Verified with ffmpeg
  7.1.1: `ffprobe -h demuxer=rtsp` lists `-timeout` and
  `-listen_timeout` only.
- **No `-re` on the input.** It throttles reading to native frame rate,
  which is for replaying files as if live. On a real-time RTSP source
  it adds latency and grows buffers.
- **Log redaction.** Everything ffmpeg writes goes through `redact()`
  before reaching stdout, because ffmpeg prints the full URL —
  including the camera password and stream key — in its error
  messages, and errors are exactly what the restart loop produces. It
  uses process substitution (`> >(redact) 2>&1`) rather than a pipe
  specifically so `$!` still refers to ffmpeg and signal forwarding
  keeps working. It's written in bash rather than `sed` because BusyBox
  `sed` has no `-u` and would buffer.
- **Backgrounded retry sleep.** The `sleep` in the supervisor loop runs
  as `sleep N & wait $!`. bash defers trap handlers until the current
  foreground command finishes, so a plain `sleep` would swallow
  SIGTERM for up to `RETRY_DELAY_SECONDS` — long enough for
  `docker stop` to give up and SIGKILL.
- **Runs as non-root** (UID 10001). Nothing here needs root; both RTSP
  and RTMP are outbound and no port is bound. The k8s manifests pin the
  same UID.
- **The Dockerfile `HEALTHCHECK` is not a duplicate watchdog.** It
  reports status; it never restarts anything. Keep it. Note Kubernetes
  ignores it entirely, and the k8s Deployment deliberately has no
  `livenessProbe` — a probe that restarts the pod *would* duplicate the
  supervisor loop.

## Testing changes

There's no camera or Docker host in most dev environments, so validate
changes without either:

1. **Syntax check:** `bash -n rootfs/usr/local/bin/entrypoint.sh`, plus
   `shellcheck -s bash` on it (CI runs both).
2. **Dry-run the command construction:** temporarily replace the real
   `ffmpeg ... &` invocation with an `echo` of the same arguments and
   run through each `AUDIO_MODE` / `VIDEO_MODE` combination to confirm
   the built command looks right. Do this instead of guessing — flag
   names and bitstream filters are easy to get subtly wrong.
3. **Flag validation:** if you add a new ffmpeg flag, confirm it
   exists *for the demuxer or muxer you're applying it to* — e.g.
   `ffprobe -h demuxer=rtsp` — not just that ffmpeg accepts it. An
   option that belongs to a different component is accepted silently
   and does nothing, which is far harder to diagnose than an
   unrecognized flag (that at least fails fast).
4. **Container-level checks** (`docker build` is enough, no camera
   needed): confirm `docker run --rm <img> id -u` is `10001`, that
   running with no env vars exits non-zero, and that a bogus password
   shows up as `<redacted>` in the logs. CI does all three.
5. **Shutdown timing:** `time docker compose stop` should return in
   about a second, not ~10s. A regression here means the signal
   handling or the backgrounded sleep broke.
6. Only do a real `docker compose up -d --build` + log check against
   an actual camera as a final check before merging something that
   touches the ffmpeg invocation itself.

### Measuring an ffmpeg change instead of arguing about it

When a change affects the ffmpeg invocation and a camera *is* reachable,
compare fixed-length captures and count warnings rather than eyeballing
logs. This is what caught every real finding in this project:

```bash
ffmpeg -hide_banner -loglevel warning -y \
  -rtsp_transport tcp -timeout 15000000 -i "$URL" \
  <the args under test> -t 30 -f flv out.flv 2>out.log
grep -c 'backward in time' out.log
grep -c 'Non-monotonic'    out.log
```

Useful companions: `ffprobe -show_entries stream=...` to confirm the
output actually has the streams you intended, and
`ffmpeg -i out.flv -af volumedetect -f null -` to prove an audio track
is silent (`mean_volume: -91 dB`) rather than assuming it.

Two things this method has already settled here, both of which cost
real time and would otherwise get re-litigated from memory:

- **`-use_wallclock_as_timestamps 1` is not the fix for backward audio
  timestamps.** It is the widely-suggested remedy and it measured *six
  times worse* on a real camera (94 backward / 218 non-monotonic in 30s,
  against a 36 / 35 baseline). `-af aresample=async=1:first_pts=0` took
  it to zero. Neither is in the tree today — camera audio was removed
  entirely — but don't reach for wallclock timestamps if this ever comes
  back.
- **Warnings that fire once at startup are not the same as warnings that
  repeat.** `Timestamps are unset in a packet for stream 0` appears once
  per ffmpeg start with `-c:v copy` from RTSP (the first packet lands
  before clock sync) and is harmless. Count occurrences before treating
  a log line as a problem.

### Debugging RTSP auth

A `401` tells you very little on its own. Get the exchange with:

```bash
ffprobe -v debug -rtsp_transport tcp -i "$URL" 2>&1 | grep -E "CSeq|401|WWW-Auth"
```

If the failing `DESCRIBE` is **CSeq 3**, ffmpeg already retried with
credentials and the camera rejected them — the values are wrong, and no
amount of URL-encoding or transport fiddling will help. CSeq 2 with no
retry means the challenge itself is the problem. `OPTIONS` returning 200
proves host, port and reachability are fine, so a 401 also rules out the
port being wrong. Auth realms that change per connection are normal here
and irrelevant under Basic auth.

## Releasing

Push to `main` publishes `:edge`. A `v*.*.*` tag publishes the semver
tags and moves `:latest`:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

**The `v` prefix is required and fails silently without it.**
`release.yml` triggers on `tags: ["v*.*.*"]`, so a tag pushed as
`1.0.0` matches nothing: no workflow runs, no image is published, and
GitHub reports no error anywhere. The only symptom is a 404 when
something later tries to pull that version. If a release seems to have
vanished, check `git ls-remote --tags origin` for a missing `v` before
looking anywhere else.

## Things to avoid

- Don't commit `.env` — it holds the camera password and YouTube
  stream key in plaintext. `.gitignore` already excludes it; keep that
  entry if you touch `.gitignore`.
- Don't add a health-check or watchdog that duplicates the existing
  restart loop — one supervisor mechanism is enough.
- Don't add dependencies (Python, Node, etc.) for something bash +
  ffmpeg already handles. The whole point of this project is a small,
  auditable image.
- Don't reintroduce `coreutils` without a concrete need. It was dropped
  with the audio probe (its only user was `timeout`); BusyBox covers
  what the script does now.
- Don't tell users to `docker pull` or `docker run` a bare image name.
  It resolves to Docker Hub and 404s. Always the full
  `ghcr.io/ssumichrast/eufycam-youtube-restream:<tag>` — a container
  created from a bare-named local build will silently fail every
  "Update image" and sit on a stale image indefinitely.

## Reference: a known-good camera

Useful for sanity-checking whether a problem is the camera or this
project. One verified-working setup:

| | |
|---|---|
| Video | H.264, 1920×1080, 15 fps |
| Keyframe interval | ~1.7s (YouTube requires ≤4s) |
| Audio offered | AAC, 16 kHz mono — present, and deliberately not streamed |
| Auth | Basic, per-connection realm |
| Path | `/live0`, port 554 implied |

`VIDEO_MODE=copy` is correct for this: H.264 in, no transcode, near-zero
CPU. A camera needing `encode` is the exception, not the default.
