#!/usr/bin/env bash
# Step 2 spike: open the A/V sync page in Chromium on the virtual display and
# record display + PulseAudio monitor with ffmpeg. Runs inside the bot image.
#   record.sh [seconds] [output.mp4] [url]
set -euo pipefail

seconds=${1:-20}
out=${2:-/recordings/spike.mp4}
url=${3:-file:///spike/av-sync.html}
geometry=${SCREEN_GEOMETRY%x*} # 1280x720x24 -> 1280x720

chrome=$(find /ms-playwright -path '*chrome-linux*/chrome' -type f | head -n1)
"$chrome" \
  --user-data-dir="$(mktemp -d)" \
  --no-first-run --no-default-browser-check \
  --autoplay-policy=no-user-gesture-required \
  --kiosk --window-position=0,0 --window-size="${geometry/x/,}" \
  "$url" >/tmp/chrome.log 2>&1 &
chrome_pid=$!
trap 'kill $chrome_pid 2>/dev/null || true' EXIT
sleep 3 # let the page load and settle

ffmpeg -hide_banner -loglevel warning -y \
  -thread_queue_size 1024 -f x11grab -draw_mouse 0 -framerate 30 \
  -video_size "$geometry" -i "$DISPLAY" \
  -thread_queue_size 1024 -itsoffset "${AUDIO_DELAY_SECONDS:-0}" \
  -f pulse -sample_rate 48000 -channels 2 \
  -i "${PULSE_SINK}.monitor" \
  -t "$seconds" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p \
  -c:a aac -b:a 128k \
  -movflags +faststart \
  "$out"

echo "recorded $out" >&2
