# eufycam-youtube-restream

[![CI](https://github.com/ssumichrast/eufycam-youtube-restream/actions/workflows/ci.yml/badge.svg)](https://github.com/ssumichrast/eufycam-youtube-restream/actions/workflows/ci.yml)
[![Release](https://github.com/ssumichrast/eufycam-youtube-restream/actions/workflows/release.yml/badge.svg)](https://github.com/ssumichrast/eufycam-youtube-restream/actions/workflows/release.yml)

Pulls an RTSP stream from a Eufycam and pushes it to YouTube Live (RTMP),
running as a self-restarting Docker container. All configuration is via
environment variables — no arguments, no config file, no editing the image.

```
ghcr.io/ssumichrast/eufycam-youtube-restream
```

Built for `linux/amd64` and `linux/arm64`.

## Quick start

```bash
docker run -d --name eufycam-restream --restart unless-stopped \
  -e CAMERA_RTSP_ADDRESS=192.168.1.50:554/live0 \
  -e CAMERA_USERNAME=admin \
  -e CAMERA_PASSWORD='your-camera-password' \
  -e YOUTUBE_INGEST_URL=rtmp://a.rtmp.youtube.com/live2 \
  -e YOUTUBE_STREAM_KEY=xxxx-xxxx-xxxx-xxxx-xxxx \
  ghcr.io/ssumichrast/eufycam-youtube-restream:latest
```

Or with Compose — copy `.env.example` to `.env`, fill it in, and:

```bash
docker compose up -d
docker compose logs -f
```

You should see `starting ffmpeg (audio: ...)`, and your YouTube Live dashboard
should go live within a few seconds.

`docker compose up -d --build` builds from this checkout instead of pulling,
for local development.

## Prerequisites

Your Eufycam model needs to support **Local RTSP Live Stream** (Eufy Security
app → camera → Settings → Advanced Settings, sometimes under Labs). Not all
models expose this — it's mainly certain EufyCam/Indoor Cam lines. Turning it
on gives you the address, username, and password this container needs.

## Configuration

### Required

All five are required; the container exits immediately with a clear message if
any is missing.

| Variable | Example | Where to find it |
|---|---|---|
| `CAMERA_RTSP_ADDRESS` | `192.168.1.50:554/live0` | Eufy Security app → Local RTSP Live Stream. The `rtsp://` prefix is optional — it's stripped either way. |
| `CAMERA_USERNAME` | `admin` | Same screen |
| `CAMERA_PASSWORD` | `changeme` | Same screen |
| `YOUTUBE_INGEST_URL` | `rtmp://a.rtmp.youtube.com/live2` | YouTube Studio → Go Live → Stream settings |
| `YOUTUBE_STREAM_KEY` | `xxxx-xxxx-xxxx-xxxx-xxxx` | Same screen |

### Optional

| Variable | Default | What it does |
|---|---|---|
| `VIDEO_MODE` | `copy` | `copy` passes video through untouched (almost no CPU). `encode` transcodes to H.264 — needed if your camera emits H.265/HEVC, which YouTube Live rejects. |
| `VIDEO_BITRATE` | `4000k` | Target bitrate. Only used when `VIDEO_MODE=encode`. |
| `AUDIO_MODE` | `silent` | Chooses the stand-in audio track — **never** the camera's microphone (see [Audio](#audio)). `silent` inserts a generated silent track; `none` sends no audio track at all, which YouTube will often refuse to go live with. |
| `RTSP_TRANSPORT` | `tcp` | `tcp` or `udp`. TCP is more reliable on most home networks. |
| `RETRY_DELAY_SECONDS` | `10` | How long to wait before restarting ffmpeg after it exits. |
| `IO_TIMEOUT_US` | `15000000` | RTSP socket I/O timeout in **microseconds** (15s). If the camera stops sending, ffmpeg gives up after this and the supervisor restarts it. |

## How it works

- A small `bash` supervisor loop (`entrypoint.sh`) runs `ffmpeg` and restarts
  it whenever it exits — camera reboot, Wi-Fi blip, YouTube ingest hiccup.
  This happens *inside* the container, so a few seconds of stream loss doesn't
  churn the container.
- `restart: unless-stopped` is a second safety net for the container process
  itself dying (e.g. OOM). The two mechanisms cover different failure modes.
- Video is copied by default (no re-encode, minimal CPU). Audio is a generated
  silent track — the camera's microphone is never streamed (see
  [Audio](#audio)).
- `SIGTERM`/`SIGINT` are forwarded to ffmpeg, so `docker stop` and
  `kubectl delete pod` shut down promptly instead of waiting out the grace
  period.

## Audio

**The camera's microphone is never captured, mapped, or transmitted.** ffmpeg
reads only the video stream from the camera; the audio that reaches YouTube is
a silent track generated locally by `anullsrc`.

That silent track exists because YouTube Live expects an audio stream to be
present — a track-less stream frequently won't go live at all. `AUDIO_MODE=none`
removes it entirely if you want to test that on your own channel.

This is enforced in the code, not just by configuration: there is no code path
that maps camera audio, and CI fails the build if one is reintroduced.

## Image tags

| Tag | Points at |
|---|---|
| `latest` | The most recent release |
| `1.2.3`, `1.2`, `1` | A specific release and its moving major/minor aliases |
| `edge` | The current `main` branch — untested against a real camera |
| `sha-<short>` | An exact commit |

Pin to a `1.2.3` or `1.2` tag for anything you care about; `edge` moves on
every merge.

Always pull by the **full** name — `docker pull` and Docker Desktop both
default to Docker Hub, where this image does not exist:

```bash
docker pull ghcr.io/ssumichrast/eufycam-youtube-restream:latest   # correct
docker pull eufycam-youtube-restream:latest                       # 404
```

## Kubernetes

Manifests live in [`deploy/k8s/`](deploy/k8s/) — a Secret for the five required
variables and a single-replica Deployment. See
[`deploy/k8s/README.md`](deploy/k8s/README.md) for the details, including the
pull secret you'll need while the GHCR package is still private.

Two things worth knowing before you deploy: `replicas` must stay at **1** (two
ffmpeg sessions on one stream key makes YouTube flap), and there is
deliberately **no `livenessProbe`** (the container already supervises ffmpeg
itself).

## Security

- **The camera's microphone is never streamed.** Only its video stream is
  read; the audio on the broadcast is locally generated silence. See
  [Audio](#audio).
- **Credentials only ever arrive as environment variables.** Nothing is baked
  into the image, and `.dockerignore` keeps `.env` out of the build context.
- **Logs are scrubbed.** ffmpeg echoes the full URL in its error messages,
  which would otherwise print your camera password and stream key into
  `docker logs` on every failed reconnect. Everything ffmpeg writes passes
  through a redaction filter first.
- **Residual exposure:** ffmpeg still receives the RTSP and RTMP URLs as
  command-line arguments, so both secrets are visible to anything that can
  read the process list *inside this container*. ffmpeg offers no way to pass
  RTSP credentials out-of-band. Since the container runs nothing else, the
  practical risk is low — but don't add a shell-access sidecar to its PID
  namespace and assume the secrets are hidden.
- **The container runs as a non-root user** (UID 10001), with no capabilities,
  no privilege escalation, and a read-only root filesystem.
- **The base image is pinned by digest** and the published image ships an SBOM
  and build provenance attestation.
- **Never commit `.env`** — it holds both secrets in plaintext. `.gitignore`
  already excludes it.

## Troubleshooting

- **Stream never goes live / ffmpeg loops immediately** — check the logs for
  the actual ffmpeg error. Wrong credentials or an unreachable RTSP address
  are the most common causes; test the URL locally first with `ffplay` or VLC.
- **Stream goes dark and never comes back** — the logs should show ffmpeg
  exiting and restarting every `IO_TIMEOUT_US`. If they show nothing at all,
  ffmpeg is wedged on a half-open connection; lower `IO_TIMEOUT_US` so it
  gives up sooner.
- **Video is choppy or CPU is pegged** — you're likely on `VIDEO_MODE=encode`
  on underpowered hardware. Use `copy` if your camera outputs H.264 (the
  common case).
- **YouTube rejects the video** — your camera is probably H.265/HEVC. Set
  `VIDEO_MODE=encode`.
- **No audio on YouTube** — expected. The stream carries a silent track by
  design; see [Audio](#audio). If YouTube reports *no audio stream at all*,
  check that `AUDIO_MODE` isn't set to `none`.

## Repository layout

```
Dockerfile                       Alpine + ffmpeg, non-root, digest-pinned
compose.yaml                     Pulls the published image; --build for local dev
.env.example                     Copy to .env and fill in
rootfs/usr/local/bin/entrypoint.sh   All the logic; path mirrors the image
deploy/k8s/                      Kubernetes Deployment + Secret template
.github/workflows/               CI (lint + build) and Release (push to GHCR)
```

## License

MIT — see [LICENSE](LICENSE).
