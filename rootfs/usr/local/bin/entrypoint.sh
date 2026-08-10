#!/usr/bin/env bash
#
# entrypoint.sh
# Pulls an RTSP stream (Eufycam) and pushes it to YouTube Live via RTMP,
# restarting ffmpeg automatically if the connection drops.
#
set -uo pipefail  # NOTE: no -e, we handle ffmpeg's non-zero exits ourselves

# ---------------------------------------------------------------------------
# Required configuration (the 5 parameters)
# ---------------------------------------------------------------------------
: "${CAMERA_RTSP_ADDRESS:?Set CAMERA_RTSP_ADDRESS, e.g. 192.168.1.50:554/live0}"
: "${CAMERA_USERNAME:?Set CAMERA_USERNAME}"
: "${CAMERA_PASSWORD:?Set CAMERA_PASSWORD}"
: "${YOUTUBE_INGEST_URL:?Set YOUTUBE_INGEST_URL, e.g. rtmp://a.rtmp.youtube.com/live2}"
: "${YOUTUBE_STREAM_KEY:?Set YOUTUBE_STREAM_KEY}"

# ---------------------------------------------------------------------------
# Optional tuning (all have sane defaults)
# ---------------------------------------------------------------------------
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-10}"
RTSP_TRANSPORT="${RTSP_TRANSPORT:-tcp}"
VIDEO_MODE="${VIDEO_MODE:-copy}"        # copy | encode
AUDIO_MODE="${AUDIO_MODE:-auto}"        # auto | aac | silent | none
VIDEO_BITRATE="${VIDEO_BITRATE:-4000k}"
IO_TIMEOUT_US="${IO_TIMEOUT_US:-15000000}"   # 15s read/write timeout, microseconds
PROBE_TIMEOUT_SECONDS="${PROBE_TIMEOUT_SECONDS:-10}"

# ---------------------------------------------------------------------------
# Build the RTSP URL (URL-encode user/pass so special characters don't
# break the URL, e.g. an '@' or '#' in the camera password).
# ---------------------------------------------------------------------------
urlencode() {
  local raw="$1" out="" c i
  for (( i = 0; i < ${#raw}; i++ )); do
    c="${raw:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

ENC_USER=$(urlencode "$CAMERA_USERNAME")
ENC_PASS=$(urlencode "$CAMERA_PASSWORD")

# Allow CAMERA_RTSP_ADDRESS with or without an rtsp:// prefix.
ADDR="${CAMERA_RTSP_ADDRESS#rtsp://}"
RTSP_URL="rtsp://${ENC_USER}:${ENC_PASS}@${ADDR}"

YOUTUBE_URL="${YOUTUBE_INGEST_URL%/}/${YOUTUBE_STREAM_KEY}"

echo "[entrypoint] RTSP source:   ${ADDR}"
echo "[entrypoint] YouTube dest:  ${YOUTUBE_INGEST_URL%/}/****"
echo "[entrypoint] video=${VIDEO_MODE} audio=${AUDIO_MODE} retry_delay=${RETRY_DELAY_SECONDS}s"

# ---------------------------------------------------------------------------
# Scrub secrets out of ffmpeg/ffprobe output.
#
# ffmpeg echoes the full URL in its error messages, so a failed connection
# would otherwise print the camera password (and the YouTube stream key)
# straight into `docker logs` and from there into any log shipper. Everything
# ffmpeg writes goes through this filter first.
#
# Implemented in bash rather than sed because BusyBox sed has no -u (line
# buffering) and this must not sit on log lines while the stream is running.
# The search terms are quoted so a '*' or '?' in a password is matched
# literally rather than as a glob pattern.
# ---------------------------------------------------------------------------
redact() {
  local line
  while IFS= read -r line; do
    line="${line//"$CAMERA_PASSWORD"/<redacted>}"
    line="${line//"$ENC_PASS"/<redacted>}"
    line="${line//"$YOUTUBE_STREAM_KEY"/<redacted>}"
    printf '%s\n' "$line"
  done
}

# ---------------------------------------------------------------------------
# Graceful shutdown: forward SIGTERM/SIGINT to ffmpeg so `docker stop`
# and `docker restart` behave properly instead of getting killed after
# the grace period.
# ---------------------------------------------------------------------------
FFMPEG_PID=""
STOPPING=0

term_handler() {
  STOPPING=1
  echo "[entrypoint] Signal received, stopping ffmpeg..."
  if [[ -n "$FFMPEG_PID" ]] && kill -0 "$FFMPEG_PID" 2>/dev/null; then
    kill -TERM "$FFMPEG_PID" 2>/dev/null
    wait "$FFMPEG_PID" 2>/dev/null
  fi
  exit 0
}
trap term_handler SIGTERM SIGINT

# ---------------------------------------------------------------------------
# Detect whether the camera is currently offering an audio stream.
# YouTube Live expects an audio track even if it's silent, and many RTSP
# cameras use PCM audio codecs that aren't valid in FLV/RTMP, so this
# lets AUDIO_MODE=auto pick the right behavior automatically.
# ---------------------------------------------------------------------------
check_audio_present() {
  timeout "$PROBE_TIMEOUT_SECONDS" ffprobe -v error \
    -rtsp_transport "$RTSP_TRANSPORT" \
    -timeout "$IO_TIMEOUT_US" \
    -select_streams a -show_entries stream=index -of csv=p=0 \
    "$RTSP_URL" 2>/dev/null
}

run_once() {
  local video_args=(-c:v copy)
  if [[ "$VIDEO_MODE" == "encode" ]]; then
    video_args=(-c:v libx264 -preset veryfast -b:v "$VIDEO_BITRATE" \
                 -maxrate "$VIDEO_BITRATE" -bufsize "$((${VIDEO_BITRATE%k} * 2))k" \
                 -pix_fmt yuv420p -g 60 -r 30)
  fi

  # -timeout (NOT -rw_timeout) is the RTSP demuxer's socket I/O timeout, in
  # microseconds. -rw_timeout is silently accepted here but has no effect on
  # the RTSP demuxer, which means a half-open connection to the camera hangs
  # ffmpeg forever -- it never exits, so the restart loop below never fires
  # and the stream stays dark. Do not "simplify" this back.
  #
  # No -re: that throttles reading to the native frame rate, which is for
  # replaying files as if they were live. On an already-realtime RTSP source
  # it only adds latency and lets input buffers grow.
  local input_args=(-rtsp_transport "$RTSP_TRANSPORT" -timeout "$IO_TIMEOUT_US" -i "$RTSP_URL")
  local map_args=(-map 0:v:0)
  local audio_args=()
  local resolved_audio_mode="$AUDIO_MODE"

  if [[ "$AUDIO_MODE" == "auto" ]]; then
    if [[ -n "$(check_audio_present)" ]]; then
      resolved_audio_mode="aac"
    else
      resolved_audio_mode="silent"
    fi
  fi

  case "$resolved_audio_mode" in
    none)
      audio_args=(-an)
      ;;
    silent)
      echo "[entrypoint] No audio track on camera (or AUDIO_MODE=silent) -- inserting silence."
      input_args+=(-f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=44100")
      map_args+=(-map 1:a:0)
      audio_args=(-c:a aac -b:a 128k -shortest)
      ;;
    aac|*)
      # Camera audio is re-encoded to AAC (most cams emit PCM, which isn't
      # valid in FLV/RTMP). No aac_adtstoasc here: that bitstream filter
      # converts ADTS framing to ASC and is only meaningful when *copying*
      # AAC from an ADTS source, not when re-encoding.
      map_args+=(-map 0:a:0)
      audio_args=(-c:a aac -b:a 128k -ar 44100)
      ;;
  esac

  echo "[entrypoint] $(date -u +%FT%TZ) starting ffmpeg (audio: ${resolved_audio_mode})..."
  # Output goes through redact() via process substitution rather than a
  # pipeline, so $! is ffmpeg's own PID and the SIGTERM forwarding above
  # keeps working.
  ffmpeg -hide_banner -loglevel warning \
    "${input_args[@]}" \
    "${map_args[@]}" \
    "${video_args[@]}" \
    "${audio_args[@]}" \
    -f flv "$YOUTUBE_URL" > >(redact) 2>&1 &
  FFMPEG_PID=$!
  wait "$FFMPEG_PID"
  return $?
}

# ---------------------------------------------------------------------------
# Supervisor loop: keep restarting ffmpeg on any exit (camera reboot,
# network blip, YouTube ingest hiccup, etc.) until the container is stopped.
# ---------------------------------------------------------------------------
while [[ "$STOPPING" -eq 0 ]]; do
  run_once
  exit_code=$?
  [[ "$STOPPING" -eq 1 ]] && break
  echo "[entrypoint] $(date -u +%FT%TZ) ffmpeg exited (code ${exit_code}). Restarting in ${RETRY_DELAY_SECONDS}s..."
  # Backgrounded sleep + wait, not a plain `sleep`: bash defers trap handlers
  # until the current foreground command finishes, so a plain sleep would
  # swallow SIGTERM for up to RETRY_DELAY_SECONDS -- long enough for `docker
  # stop` to give up and SIGKILL us.
  sleep "$RETRY_DELAY_SECONDS" &
  wait $!
done
