# Pinned by digest so builds are reproducible and Dependabot can propose
# bumps. Update the tag and the digest together.
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

LABEL org.opencontainers.image.title="eufycam-youtube-restream" \
      org.opencontainers.image.description="Restreams a Eufycam RTSP feed to YouTube Live via RTMP, restarting on failure." \
      org.opencontainers.image.source="https://github.com/ssumichrast/eufycam-youtube-restream" \
      org.opencontainers.image.licenses="MIT"

# ffmpeg: the actual work. bash: the entrypoint uses arrays and traps.
# coreutils: `timeout` for the audio probe. tzdata: readable log timestamps.
#
# DL3018 (pin apk versions) is ignored deliberately: Alpine repositories drop
# older package versions as they're superseded, so pinned versions turn into
# build failures within weeks. The base image digest above is what makes these
# builds reproducible.
# hadolint ignore=DL3018
RUN apk add --no-cache \
      ffmpeg \
      bash \
      coreutils \
      tzdata

# Nothing here needs root -- RTSP and RTMP are both outbound and no port is
# bound. Fixed UID/GID so the Kubernetes securityContext can pin runAsUser.
RUN addgroup -g 10001 -S restream \
 && adduser -u 10001 -S -D -H -G restream restream

COPY --chmod=0755 rootfs/usr/local/bin/entrypoint.sh /usr/local/bin/entrypoint.sh

USER 10001:10001

# Liveness only -- this reports, it does not restart. The restart loop lives
# in entrypoint.sh (see CLAUDE.md); adding a restarting watchdog here would
# duplicate it. Kubernetes ignores this directive entirely.
#
# DL3025: shell form is intentional here -- the check needs `||` to turn
# pgrep's exit status into the unhealthy signal.
# hadolint ignore=DL3025
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD pgrep -x ffmpeg > /dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
