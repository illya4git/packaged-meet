#!/usr/bin/env bash
# Starts the virtual display and audio server, then execs the given command.
set -euo pipefail

display_num="${DISPLAY#:}"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-$(id -u)}"
mkdir -p -m 0700 "$XDG_RUNTIME_DIR"

wait_for() { # description, timeout seconds, command...
  local what=$1 timeout=$2; shift 2
  for _ in $(seq $((timeout * 10))); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
  done
  echo "entrypoint: timed out waiting for $what" >&2
  exit 1
}

Xvfb "$DISPLAY" -screen 0 "$SCREEN_GEOMETRY" -nolisten tcp -noreset &
wait_for "Xvfb on $DISPLAY" 10 test -S "/tmp/.X11-unix/X$display_num"

pulseaudio --daemonize=yes --use-pid-file=yes --system=no \
  -n --file=/etc/packaged-meet/pulse/default.pa \
  --exit-idle-time=-1 --disallow-exit=yes --log-target=stderr
wait_for "PulseAudio" 10 pactl info

echo "entrypoint: display $DISPLAY ($SCREEN_GEOMETRY), audio sink $(pactl get-default-sink)" >&2
exec "$@"
