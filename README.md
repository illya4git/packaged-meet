# Packaged Meet

Packaged Meet is a self-hosted service that joins online meetings (Google Meet, Microsoft Teams, Zoom) on a schedule and records them, using a real Chromium browser driven by Playwright. One runtime, one capture pipeline and one debugging model for every platform.

> Legal and consent requirements are handled outside this project. The bot always joins as a visible, named participant.

---

## 1. Goals and non-goals

**Goals**

- Join Meet, Teams and Zoom meetings automatically at scheduled times and record audio + video.
- Browser-only approach: no platform SDKs, no built-in platform recording.
- Run on a **single host**, accessible **only from the local network**.
- Survive crashes: partial recordings are kept, failed attempts are retried within the meeting window.
- Be written mostly in **TypeScript**, as a learning project with strict typing throughout.

**Non-goals (for now)**

- Multi-host orchestration (Kubernetes, Nomad, Swarm). A `RuntimeDriver` interface keeps this possible later.
- Public internet exposure or multi-tenant use.
- Per-participant audio streams. Speaker information comes from scraped UI metadata instead.
- Platform SDK paths (e.g. Zoom Meeting SDK). Zoom via browser is best-effort and tracked separately.

---

## 2. Architecture overview

### Core idea

Everything **below** the browser is platform-agnostic: ffmpeg records the virtual X display and the PulseAudio null-sink monitor, regardless of which meeting client is on screen. Platform-specific code (an **adapter**) only has to get into the meeting and keep the screen showing the right thing.

### Services (Docker Compose)

| Service            | Tech                                                      | Role                                                                                                   |
| ------------------ | --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `controller`       | Node + TypeScript (Fastify)                               | API, scheduler, Docker driver, WebSocket gateway, reconciler, post-processing worker, serves dashboard |
| `postgres`         | PostgreSQL                                                | Job store and job queue (via pg-boss)                                                                  |
| `docker-proxy`     | docker-socket-proxy                                       | Exposes only container + event endpoints of the Docker API to the controller                           |
| `caddy` (optional) | Caddy                                                     | HTTPS reverse proxy bound to the LAN IP                                                                |
| `bot-*` (dynamic)  | Playwright base image + Xvfb + PulseAudio + ffmpeg + Node | One container per meeting attempt, launched by the controller                                          |

There is **no Redis and no object storage**: bots talk to the controller over WebSocket, and recordings are written directly to host disk via bind mounts.

### Networks

- `internal` (`internal: true`, no egress): `controller`, `postgres`, `docker-proxy`.
- `bots` (internet egress): bot containers + the controller's WebSocket endpoint. Bots can **not** reach Postgres or the Docker proxy.
- Only `caddy` (or `controller`) publishes a port, bound to the host's **LAN IP**, never `0.0.0.0`.

### Host disk layout

```
/srv/packaged-meet/
  recordings/<attemptId>/       # bind-mounted read-write into exactly one bot
  profiles/<accountId>.tar.enc  # encrypted Chromium profiles (AES-256-GCM)
  pgdata/                       # Postgres data
  logs/<attemptId>.log          # bot container logs captured before removal
```

### Lifecycle of one recording

1. Scheduler sees a meeting within the lead window and creates a job; capacity check passes.
2. Controller leases an account, creates the attempt directory, decrypts a **copy** of the profile, launches a bot container with labels and a per-attempt token.
3. Bot connects to the gateway and sends `hello`; controller replies with `assign` (URL, platform, deadlines).
4. Bot's state loop joins → lobby → in meeting → starts capture; events and segment reports stream back.
5. Meeting ends or `stop` is received; ffmpeg closes cleanly; agent exits with code 0.
6. Docker `die` event reaches controller: profile saved back (clean exit only), account released, post-processing enqueued.
7. Post-processing concatenates segments, normalizes audio, builds timeline; recording is marked ready.

On crash: `die` with non-zero exit, OOM, or missing heartbeats mark the attempt failed; if the meeting window is still open a new attempt is scheduled (recording ends up in parts).

---

## 3. Tech stack

- **Runtime:** Node 24 LTS
- **Language:** TypeScript, `strict: true`, `noUncheckedIndexedAccess: true`
- **Monorepo:** npm workspaces + TypeScript project references (`tsc --build`)
- **Dev runner:** `tsx`
- **API:** Fastify with the zod type provider
- **Validation:** zod at every process boundary (HTTP, WebSocket, env, DB JSON columns)
- **Database:** PostgreSQL + Drizzle ORM (schema in TS, typed queries, migrations)
- **Queue:** pg-boss (Postgres-backed)
- **Docker client:** dockerode (talking to `docker-proxy`)
- **Browser automation:** Playwright (Chromium)
- **Capture:** ffmpeg (`x11grab` + `pulse`, segment muxer, fragmented MP4)
- **Dashboard:** React + Vite, built to static files served by the controller
- **Tests:** Vitest
- **Lint/format:** ESLint + Prettier

Pin exact dependency versions. Pin the Chromium/Playwright base image version and upgrade it deliberately.

---

## 4. Repository layout

```
packaged-meet/
  package.json            # "workspaces": ["packages/*", "apps/*"]
  tsconfig.base.json
  README.md
  packages/
    shared/               # @packaged-meet/shared — protocol schemas, BotState, config types, utils
    db/                   # @packaged-meet/db — Drizzle schema, migrations, typed queries
    adapters/             # @packaged-meet/adapters — meet/, teams/, zoom/ (probes, handlers, meta extraction)
      fixtures/           # saved HTML snapshots of platform screens for probe tests
  apps/
    controller/           # @packaged-meet/controller — api, scheduler, capacity, docker, gateway,
                          #   reconciler, accounts, postprocess modules
    bot-agent/            # @packaged-meet/bot-agent — state loop, capture, WS client, CLI entry
    dashboard/            # @packaged-meet/dashboard — React + Vite
  docker/
    bot/Dockerfile
    bot/entrypoint.sh
    controller/Dockerfile
    compose.yaml
    .env.example
```

### npm workspace conventions

- Packages are scoped `@packaged-meet/<name>`; cross-references use `"@packaged-meet/shared": "*"`.
- Add a dependency to one package: `npm install <pkg> -w packages/shared`.
- Run a script in one package: `npm run build -w apps/controller`; in all: `npm run test --workspaces`.
- **Every package declares every import it uses** in its own `package.json`. npm hoisting can hide missing dependencies locally; they break in Docker images.
- Docker builds: copy root `package.json`, `package-lock.json` and all workspace `package.json` files first, `npm ci`, then copy sources and build. Use multi-stage builds; final images contain only built output and production dependencies.

---

## 5. Key designs

### 5.1 Bot state loop (adapter contract)

Adapters never run linear scripts. They provide **probes** (classify the current page) and **handlers** (act in a state). The agent loop:

1. Run probes in priority order; first match is the current state.
2. If state changed: emit `state` event + screenshot.
3. Run the handler for that state.
4. Sleep ~1 s; repeat.

Outside the loop: watchdog for prolonged `unknown`, join deadline, lobby timeout and max duration via `AbortController`. Capture starts on first entry into `in_meeting`.

```ts
export type BotState =
  | "launching"
  | "prejoin"
  | "lobby"
  | "in_meeting"
  | "ended"
  | "removed"
  | "blocked"
  | "auth_required"
  | "unknown";

export interface Probe {
  state: BotState;
  test(page: Page): Promise<boolean>;
}

export interface PlatformAdapter {
  platform: "meet" | "teams" | "zoom";
  probes: Probe[];
  handlers: Partial<Record<BotState, (ctx: Ctx) => Promise<void>>>;
  extractMeta?(page: Page, emit: (m: MetaEvent) => void): Promise<void>;
}
```

Selectors and text matchers live in a versioned config object per platform, preferring ARIA roles, accessible names and `data-*` attributes over generated CSS classes.

### 5.2 Bot ↔ controller protocol

Defined once in `@packaged-meet/shared` as zod discriminated unions; TS types are derived with `z.infer`. Every `switch (msg.type)` ends with `assertNever`.

- **Bot → controller:** `hello`, `heartbeat`, `state`, `segment`, `meta` (speaker/join/leave/chat), `error`, `screenshot`.
- **Controller → bot:** `assign`, `stop`, `screenshot_request`.

Authentication: per-attempt random token passed to the container as an env var, valid for that attempt only.

### 5.3 Bot container

- Base: official Playwright image (`v1.64.0-noble`, pinned); add Xvfb, PulseAudio, ffmpeg. Run as non-root (`pwuser`, uid 1001), so each attempt directory must be writable by uid 1001.
- `entrypoint.sh`: start Xvfb on `:99`, start PulseAudio with a null sink as default output, `exec node dist/main.js`.
- Launch flags: `--init`, `--shm-size=2g`, CPU and memory limits, no restart policy, no auto-remove, network `bots`, `--cap-drop=ALL --cap-add=SYS_CHROOT`, `--security-opt no-new-privileges`, `--security-opt seccomp=docker/bot/seccomp.json`. Keep the Chromium sandbox enabled (no `--no-sandbox`).
- Chromium sandbox requirements: the seccomp profile is Docker's default plus `clone`/`setns`/`unshare` (unprivileged user namespaces); `SYS_CHROOT` (a Docker default capability) is the only capability kept. Without either, Chromium aborts with "No usable sandbox" or a zygote failure.
- A/V sync: the null-sink monitor delivers audio as soon as it is mixed, while Chromium delays video for its assumed speaker latency, so recorded audio runs early. `PULSE_LATENCY_MSEC=20` makes the offset constant; ffmpeg shifts audio by `AUDIO_DELAY_SECONDS` (0.067, measured on the spike's A/V sync page). Re-measure with `docker/bot/spike/run-spike.sh` after changing the base image, resolution or frame rate.
- Fake media devices: `--use-fake-ui-for-media-stream`, `--use-fake-device-for-media-stream`, with silent audio and a static image as the bot's mic/camera.
- Labels: `packaged-meet.attempt_id`, `packaged-meet.meeting_id`, `packaged-meet.platform`.

### 5.4 Capture

The agent spawns ffmpeg as a typed child process: `x11grab` from `:99` + `pulse` from the null-sink monitor → segment muxer, ~10 s fragmented MP4 chunks in `/recordings`. Each closed segment is reported via `segment`. On shutdown, send `q` on ffmpeg's stdin so the last segment closes cleanly.

### 5.5 Controller modules

| Module        | Responsibility                                                                                                    |
| ------------- | ----------------------------------------------------------------------------------------------------------------- |
| `api`         | Fastify routes, zod schemas, session auth (single admin password)                                                 |
| `scheduler`   | Every few seconds: meetings in the lead window without an active job → create job                                 |
| `capacity`    | `MAX_CONCURRENT_BOTS`; jobs wait when full                                                                        |
| `docker`      | `RuntimeDriver` interface (`launch`, `stop`, `list`, `events`) implemented with dockerode                         |
| `gateway`     | WebSocket server; token validation; persists events; tracks live bots                                             |
| `reconciler`  | On startup + every minute: compare labeled containers with DB; adopt, kill or fail mismatches; heartbeat timeouts |
| `accounts`    | Leasing via `SELECT … FOR UPDATE SKIP LOCKED`; health scores; profile encrypt/decrypt with `node:crypto`          |
| `postprocess` | pg-boss worker: concat segments, normalize audio, build timeline JSON, mark ready                                 |

### 5.6 Data model (Drizzle)

- `meetings` — url, platform, starts_at, ends_at, title, source (manual / ics), external_id
- `jobs` — meeting_id, status, created_at
- `attempts` — job_id, account_id, container_id, token_hash, state, exit_code, started_at, ended_at, failure_reason
- `events` — attempt_id, type, payload (jsonb), at
- `recordings` — attempt_id, status, file_path, duration, timeline_path
- `accounts` — platform, label, profile_path, health_score, leased_by_attempt_id, last_used_at

### 5.7 Configuration (env, validated with zod at startup)

```
DATABASE_URL=
DOCKER_HOST=tcp://docker-proxy:2375
LAN_BIND_ADDRESS=192.168.1.10
HTTP_PORT=8080
ADMIN_PASSWORD_HASH=
PROFILE_ENCRYPTION_KEY=          # 32 bytes, base64; keep outside the repo
DATA_ROOT=/srv/packaged-meet
BOT_IMAGE=packaged-meet-bot:<version>
MAX_CONCURRENT_BOTS=4
JOIN_LEAD_SECONDS=120
JOIN_DEADLINE_SECONDS=600
LOBBY_TIMEOUT_SECONDS=900
MAX_MEETING_SECONDS=14400
ALONE_TIMEOUT_SECONDS=300
```

---

## 6. Development plan

Each step ends with a verifiable **Done when** criterion. Do not start a step until the previous one's criterion is met (except where noted). Steps 2 and 3 carry most of the technical risk.

### Step 1 — Repository foundation

- [x] Root `package.json` with workspaces; `tsconfig.base.json` (strict, `noUncheckedIndexedAccess`); per-package `tsconfig.json` with project references.
- [x] ESLint, Prettier, Vitest configured at root.
- [x] Empty packages `shared`, `db`, `adapters`, `controller`, `bot-agent` that import each other.

**Done when:** `npm run build` compiles everything via `tsc --build` and `npm test` runs a trivial test in each package.

### Step 2 — Bot image spike (no TypeScript)

- [x] `docker/bot/Dockerfile` on the Playwright base image + Xvfb, PulseAudio, ffmpeg.
- [x] `entrypoint.sh` starting Xvfb and PulseAudio null sink.
- [x] Manually open a page with video + sound in Chromium inside the container and record it with an ffmpeg command run in a shell.

**Done when:** an MP4 with synced picture and audio is produced.

### Step 3 — Standalone bot agent for Google Meet

- [ ] CLI entry: `--url`, `--platform`, `--out`, `--profile`; no controller dependency.
- [ ] State loop, Meet adapter (probes + handlers), deadlines via `AbortController`.
- [ ] Typed ffmpeg wrapper with segmenting and clean shutdown.
- [ ] Screenshots on every state change into the output directory.
- [ ] Login: prepare a Chromium profile interactively once and mount it.

**Done when:** the container joins a test meeting, gets admitted, records in segments, and exits cleanly when the meeting ends.

### Step 4 — Shared protocol and database

- [ ] zod message schemas and `BotState` in `@packaged-meet/shared`.
- [ ] Drizzle schema + migrations in `@packaged-meet/db`; `compose.yaml` with Postgres only.
- [ ] Agent emits typed events (logged to stdout for now).

**Done when:** migrations apply cleanly and agent events validate against the schemas in tests.

### Step 5 — Controller core

- [ ] Fastify skeleton; env validation; `docker-proxy` service in Compose.
- [ ] `DockerDriver` (dockerode) implementing `RuntimeDriver`.
- [ ] WebSocket gateway with per-attempt tokens; events persisted.
- [ ] Endpoint `POST /api/attempts` — start an attempt now for a URL.

**Done when:** one HTTP call launches a bot, its state transitions appear in the DB, and the recording lands in the host directory.

### Step 6 — Lifecycle hardening

- [ ] Docker `die` / `oom` event handling; heartbeat timeouts.
- [ ] `stop` command; `MAX_CONCURRENT_BOTS` enforcement.
- [ ] Reconciler (startup + periodic).
- [ ] Capture container logs before removal; clean up exited containers.

**Done when:** killing the controller mid-recording and restarting it re-adopts the running bot, and killing a bot container marks the attempt failed and triggers a retry.

### Step 7 — Scheduling and job queue

- [ ] Meetings CRUD API.
- [ ] Scheduler loop with lead time; pg-boss for attempts; retry policy within the meeting window.

**Done when:** a meeting scheduled five minutes ahead records with no manual action.

### Step 8 — Accounts and profiles

- [ ] Accounts table; leasing via `SKIP LOCKED`.
- [ ] Encrypted profile tarballs; per-attempt decrypted copy; save back only on clean exit.
- [ ] Health scores updated from join outcomes.

**Done when:** two overlapping meetings get different accounts and profiles survive repeated runs without re-login.

### Step 9 — Post-processing _(can run in parallel with Step 10 after Step 7)_

- [ ] pg-boss worker: concat segments, normalize audio, build timeline JSON from `meta` events.

**Done when:** each finished attempt yields one playable file plus a timeline.

### Step 10 — Dashboard _(can run in parallel with Step 9 after Step 7)_

- [ ] React + Vite app served as static files by the controller.
- [ ] Login, meeting list, scheduling form.
- [ ] Live attempt status over WebSocket; on-demand screenshots.
- [ ] Recording player; video served with HTTP range requests.

**Done when:** everything can be done from the browser without calling the API directly.

### Step 11 — Teams and Zoom adapters

- [ ] Save HTML snapshots of each platform's screens to `packages/adapters/fixtures/`; write probe tests first.
- [ ] Teams adapter, then Zoom adapter (web client, signed-in accounts).
- [ ] Active-speaker and participant metadata extraction for all three platforms.

**Done when:** all three platforms record end to end and probe tests pass against fixtures.

### Step 12 — Calendar sync

- [ ] Poll ICS feeds; extract meeting links per platform.
- [ ] Idempotent handling of rescheduled and cancelled events.

**Done when:** adding an event to a calendar gets it recorded with no manual steps.

### Step 13 — Operations

- [ ] Bind to LAN IP; optional Caddy with internal CA; dashboard auth required.
- [ ] Nightly `pg_dump`; recording retention policy; disk-usage alert.
- [ ] Daily canary meeting per platform.
- [ ] Documented procedure to update the bot image without interrupting running bots.

**Done when:** the system runs unattended for a week and reports when something breaks.

---

## 7. Instructions for coding agents

Read this section before making changes.

**Working rules**

- Work on **one step at a time** from section 6. Before finishing, verify that step's **Done when** criterion and tick its checkboxes in this README.
- Run `npm run build` and `npm test` before considering any change complete. Do not leave type errors behind.
- Keep `strict` TypeScript. No `any`, no `@ts-ignore`; use `unknown` + zod parsing at boundaries.
- Any data crossing a process boundary (HTTP, WebSocket, env, JSON columns, files written by another process) is parsed with a zod schema from `@packaged-meet/shared`.
- Protocol or state changes go into `@packaged-meet/shared` first, then fix every compiler error in consumers.
- Declare every imported dependency in the importing package's own `package.json`.
- Prefer small, typed modules with explicit interfaces (`RuntimeDriver`, `PlatformAdapter`) over cross-module imports of internals.

**Adapters**

- Never write linear click scripts. Add probes and handlers.
- Every new probe gets a test against a saved fixture in `packages/adapters/fixtures/`.
- Selectors live in the platform's selector config, not inline in handlers.

**Security (do not relax)**

- The controller never mounts `/var/run/docker.sock` directly; it uses `docker-proxy`.
- Bot containers: non-root, all capabilities dropped except `SYS_CHROOT`, `no-new-privileges`, the repo's seccomp profile, no privileged mode, Chromium sandbox enabled, network `bots` only, bind mount limited to their own attempt directory.
- Never publish ports on `0.0.0.0`. Never commit secrets, profiles, or `.env` files.
- Profiles are always encrypted at rest; only per-attempt decrypted copies exist, and they are deleted after the attempt.

**Debugging aids**

- Every state change produces a screenshot in the attempt directory.
- Bot logs are captured to `/srv/packaged-meet/logs/<attemptId>.log` before container removal.
- When a platform UI changes, update fixtures and selector config first, then handlers.

---

## 8. Common commands

```bash
npm ci                                   # install all workspaces
npm run build                            # tsc --build across all packages
npm test                                 # vitest across all workspaces
npm run lint                             # eslint (type-aware) across the repo
npm run format                           # prettier --write (format:check in CI)
npm run dev -w apps/controller           # controller with tsx watch
npm run db:migrate -w packages/db        # apply Drizzle migrations
docker build -f docker/bot/Dockerfile -t packaged-meet-bot:dev .
docker/bot/spike/run-spike.sh            # record the A/V sync page in the bot image, report offset
docker compose -f docker/compose.yaml up -d
```

Scripts referenced here are created during Steps 1, 4 and 5; keep this list in sync when adding new ones.

---

## 9. Known limitations and open decisions

- Zoom via browser is best-effort: hosts can disable browser join, sign-in may be required, and automation detection is stricter. Track its join success rate separately.
- Meet and Teams may challenge logins; account health scoring and profile reuse mitigate this.
- Capacity is roughly 1–2 vCPU and 2–4 GB RAM per concurrent bot; size `MAX_CONCURRENT_BOTS` from host resources.
- A host failure stops all in-progress recordings; segments already written are kept.
- A/V sync: with the fixed audio delay, most spike runs measure 0 to −5 ms, but roughly 1 in 8 runs is steadily ~−60 ms (audio early, about two frames at 30 fps). Cause not yet identified; revisit when the real capture wrapper lands (Step 3) and consider re-measuring the offset per bot start.
- Open: transcription (optional, after Step 9), notification channel for alerts (Step 13).
