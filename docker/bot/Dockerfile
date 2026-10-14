# Bot image: Chromium (via the Playwright base image) on a virtual X display,
# with PulseAudio and ffmpeg for capture. One container per meeting attempt.
#
# Build from the repo root:
#   docker build -f docker/bot/Dockerfile -t packaged-meet-bot:dev .

# Pinned deliberately; upgrade together with the `playwright` npm dependency.
FROM mcr.microsoft.com/playwright:v1.64.0-noble

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      xvfb \
      pulseaudio \
      pulseaudio-utils \
      ffmpeg \
 && rm -rf /var/lib/apt/lists/*

COPY docker/bot/pulse/ /etc/packaged-meet/pulse/
COPY --chmod=0755 docker/bot/entrypoint.sh /usr/local/bin/entrypoint.sh

# Recordings are bind-mounted here, one directory per attempt.
# /tmp/.X11-unix must exist up front: Xvfb only creates it when running as root.
RUN mkdir -p /recordings && chown pwuser:pwuser /recordings \
 && mkdir -p -m 1777 /tmp/.X11-unix

# PULSE_LATENCY_MSEC pins the latency Chromium requests from PulseAudio. The
# null sink's monitor delivers audio as soon as it is mixed, while Chromium
# delays video to match the (non-existent) speaker latency, so recorded audio
# runs early by roughly that latency. Pinning it makes the offset small and
# constant; ffmpeg compensates the rest with AUDIO_DELAY_SECONDS (measured with
# docker/bot/spike/run-spike.sh).
ENV DISPLAY=:99 \
    SCREEN_GEOMETRY=1280x720x24 \
    PULSE_SINK=bot_sink \
    PULSE_LATENCY_MSEC=20 \
    AUDIO_DELAY_SECONDS=0.067

# Non-root. The Chromium sandbox stays enabled; it needs the seccomp profile in
# docker/bot/seccomp.json and CAP_SYS_CHROOT (see docker/bot/spike/run-spike.sh).
USER pwuser
WORKDIR /home/pwuser

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# Replaced by `node dist/main.js` once the bot agent exists (Step 3).
CMD ["bash"]
