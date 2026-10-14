#!/usr/bin/env bash
# Measures A/V offset in a recording of av-sync.html: compares when each white
# flash starts (end of a black interval) with when each beep starts (end of a
# silence interval). Positive offset = audio lags video.
#   analyze-sync.sh recording.mp4
set -euo pipefail
in=${1:?usage: analyze-sync.sh recording.mp4}

flashes=$(ffmpeg -hide_banner -nostats -i "$in" -an \
  -vf "blackdetect=d=0.05:pix_th=0.10:pic_th=0.90" -f null - 2>&1 |
  grep -o 'black_end:[0-9.]*' | cut -d: -f2)
beeps=$(ffmpeg -hide_banner -nostats -i "$in" -vn \
  -af "silencedetect=n=-30dB:d=0.05" -f null - 2>&1 |
  grep -o 'silence_end: [0-9.]*' | cut -d' ' -f2)

ffprobe -v error -show_entries stream=codec_type,codec_name,width,height,r_frame_rate,sample_rate,channels:format=duration \
  -of compact "$in"
duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$in")

# Detector events in the last 0.2 s are artifacts of the file ending mid-interval.
awk -v flashes="$flashes" -v beeps="$beeps" -v duration="$duration" '
BEGIN {
  nf = split(flashes, f, "\n"); nb = split(beeps, b, "\n")
  printf "flashes: %d  beeps: %d\n", nf, nb
  n = 0
  for (i = 1; i <= nf; i++) {
    if (f[i] > duration - 0.2) continue
    best = ""; for (j = 1; j <= nb; j++) {
      d = b[j] - f[i]
      if (best == "" || (d < 0 ? -d : d) < (best < 0 ? -best : best)) best = d
    }
    if (best != "" && (best < 0 ? -best : best) < 0.5) {
      printf "  flash %7.3fs  offset %+6.0f ms\n", f[i], best * 1000
      sum += best; n++; offs[n] = best
      if (min == "" || best < min) min = best
      if (max == "" || best > max) max = best
    }
  }
  if (n == 0) { print "no matched flash/beep pairs"; exit 1 }
  # insertion sort for the median
  for (i = 2; i <= n; i++) { v = offs[i]; for (j = i - 1; j >= 1 && offs[j] > v; j--) offs[j + 1] = offs[j]; offs[j + 1] = v }
  median = (n % 2) ? offs[(n + 1) / 2] : (offs[n / 2] + offs[n / 2 + 1]) / 2
  printf "matched %d pairs: median %+.0f ms, mean %+.0f ms, min %+.0f ms, max %+.0f ms\n", n, median * 1000, sum / n * 1000, min * 1000, max * 1000
}'
