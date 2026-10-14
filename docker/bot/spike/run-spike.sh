#!/usr/bin/env bash
# Step 2 spike, run from the host: records the A/V sync page inside the bot
# image and reports the measured A/V offset. Output lands in docker/bot/spike/out.
#   docker/bot/spike/run-spike.sh [seconds]
#
# The docker run flags mirror what the controller will use for real bots:
# no capabilities except SYS_CHROOT (needed by the Chromium sandbox),
# no-new-privileges, a seccomp profile that allows user namespaces, --init,
# 2 GB /dev/shm, CPU and memory limits.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
bot_dir=$(dirname "$here")
seconds=${1:-30}

mkdir -p "$here/out"
chmod 0777 "$here/out" # the container runs as pwuser (uid 1001)

docker run --rm --init \
  --shm-size=2g --cpus=2 --memory=3g \
  --cap-drop=ALL --cap-add=SYS_CHROOT \
  --security-opt no-new-privileges \
  --security-opt "seccomp=$bot_dir/seccomp.json" \
  -v "$here:/spike:ro" \
  -v "$here/out:/recordings" \
  "${BOT_IMAGE:-packaged-meet-bot:dev}" \
  bash -c "/spike/record.sh $seconds /recordings/spike.mp4 && /spike/analyze-sync.sh /recordings/spike.mp4"
