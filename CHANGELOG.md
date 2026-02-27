# Changelog

Versioning: `x.y.z` — x = major feature change, y = minor feature change, z = bug fix

---

## [4.8.5] — 2026-02-27

### Added
- **`coordinator-migrate` command** — master can run `everyone migrate hub-url:<URL> pass:<password>`
  to register all servers with a self-hosted Coordinator Hub (v5.0.0). Each server POSTs to
  `/api/register`, writes the returned token to `coordinator.env`, sets
  `COORDINATOR_PRIVATE_ENABLED=1`, and automatically upgrades to the Hub-capable v5.0.0 daemon
  in a detached background process. Migration is atomic: registration + token + upgrade in one
  Slack command. Servers that have already migrated skip gracefully.
- **`COORDINATOR_PRIVATE_ENABLED` / `COORDINATOR_HUB_PRIMARY` / `COORDINATOR_HUB_TOKEN`** stubs
  written to `coordinator.env` at install time (all blank/disabled; filled by `coordinator-migrate`).

### Changed
- `COORDINATOR_INSTALLER_URL` updated to the 4.8.5 URL; after migration, it is automatically
  bumped to the Hub-server's v5.0.0 installer URL.
- `COORDINATOR_VERSION` bumped to `4.8.5`.

---

## [4.8.2] — 2026-02-27

### Added
- **Auto API key provisioning** — if `CLAUDE_PRIMARY_API_KEY` is present in `coordinator-creds.cfg`
  at install time, the key is injected automatically into `~/.claude.json` without requiring an
  interactive auth step. Useful for fully automated deployments where the API key is pre-placed in
  the config file.

---

## [4.8.0] — 2026-02-27

### Added
- **`run-claude` command type** — master can post `<hostname> run-claude: '<prompt>'` to execute
  a raw `claude -p` call outside the coordinator context (no CLAUDE.md injection, no permission
  wrapping). Useful for arbitrary one-off Claude prompts.
- **Playwright / browser integration** — installer optionally runs `playwright install` and
  `playwright install-deps` if the `playwright` Node package is detected after Claude Code
  installation, enabling Claude Max browser-use tools.

---

## [4.7.0] — 2026-02-27

### Added
- **`&&`-chained commands** — master can chain sequential tasks in a single Slack message with
  `&&`. Example: `everyone run: date && everyone run: uptime`. Each server executes the chain in
  order; the next command is dispatched after the previous completes. Chains survive across upgrade
  and migration events via a persistent `coordinator-pending-chain` file.
- **`coordinator-health`** — compact one-line server health snapshot (CPU, RAM, disk, load,
  service statuses including nginx, rabbitmq, opensips, freeswitch, elasticsearch, docker).
  Installed to `/usr/local/bin/coordinator-health`.
- **`coordinator-cert-check`** — SSL certificate expiry report across Let's Encrypt certbot-managed
  and nginx vhost certs. Reports days remaining per certificate.
- **`coordinator-docker-health`** — Docker container health summary; lists running, stopped, and
  unhealthy containers.
- **`coordinator-sip-health`** — OpenSIPS + FreeSWITCH health snapshot via `opensipsctl` and
  `fs_cli`.
- **`coordinator-amqp-status`** — RabbitMQ queue health via the management HTTP API; shows queue
  depth and consumer count.
- **`coordinator-security-check`** — quick security audit: SSH password auth, root login,
  failed auth attempts (24h), UFW status, pending security updates, world-writable files in `/etc`.

---

## [4.6.3] — 2026-02-26

### Fixed
- **Slack `mailto:` mangling of scp/rsync destinations** — Slack auto-links `user@host` as
  `<mailto:user@host|user@host>` in its API response. The daemon was passing this raw formatting
  to Claude verbatim. Added `decode_slack_text()` which strips all Slack auto-link formatting
  before text reaches Claude: `<mailto:addr|display>` → `display`, `<url|display>` → `display`,
  `<url>` → `url`, `&amp;`/`&lt;`/`&gt;` → `&`/`<`/`>`. Applied to every TEXT read in the
  main daemon loop.
- **Claude refusing scp/shell commands from MASTER** — Claude's built-in safety reasoning was
  overriding MASTER-authorized operations (e.g. refusing to run scp with inline credentials).
  Added an explicit "Executing shell commands" section to the CLAUDE.md coordinator context
  instructing Claude to execute ALL commands from daemon-spawned MASTER sessions verbatim,
  without refusing, skipping, or adding security commentary.

---

## [4.6.2] — 2026-02-26

### Fixed
- **Roll call table: leftmost column shows short hostname for all servers** — previously servers
  that reported their FQDN as their label (or hadn't upgraded yet) showed the full domain in the
  first column. Now always strips to `${label%%.*}` before writing the row.
- **Roll call table: rightmost column (Full Hostname) falls back to label** — servers on v4.5.x
  don't include a `host:` field in their roll call response. The aggregator now falls back to the
  raw label value for those servers so the column is never blank.
- **Roll call table: CSV block posted after table** — a second code block with comma-separated
  values is now posted immediately after the fixed-width table, making the data easy to copy
  and view cleanly regardless of font rendering.
- **Upgrade failure posts actual error reason** — the backup step in `coordinator-upgrade` now
  captures and posts the `cp` stderr (e.g. `Permission denied`) plus the effective user (`id -un`)
  so failures are self-diagnosing in the Slack channel.
- **MASTER always overrides busy lock** — `run_claude()` now accepts a `trust` parameter. When
  trust is `MASTER`, a busy/locked server clears the lock and runs the task immediately instead
  of skipping it. Threaded through `run_election()` and all call sites. Previously, a server
  stuck with a stale lock file from a crashed task would refuse all MASTER commands.
- **Stale lock auto-cleanup** — lock files older than 30 minutes are automatically cleared
  regardless of trust level, preventing permanently stuck servers after process crashes.

---

## [4.6.1] — 2026-02-26

### Fixed
- **`everyone upgrade` fails on servers without `systemd-run`** — the `setsid/nohup` fallback in
  `handle_upgrade()` ran `coordinator-upgrade` as the non-root daemon user, who cannot write to
  `/usr/local/bin/` to create the backup. Fixed by:
  1. Changing the fallback to `sudo /usr/local/bin/coordinator-upgrade` (runs as root)
  2. Adding a `sudoers.d` NOPASSWD rule during install:
     `<user> ALL=(root) NOPASSWD: /usr/local/bin/coordinator-upgrade`
     so the daemon user can always escalate the upgrade without a password.

---

## [4.6.0] — 2026-02-26

### Added
- **Roll call table** — after all servers respond to a roll call, one server (elected by deterministic
  jitter) aggregates the responses and posts a formatted code-block table to Slack. Columns:
  Hostname, Ver, Role, Status, Uptime, Public IP, Private IP, GCP Project, Zone, Full Hostname.
  Uses a `[COORDINATOR:ROLLCALL_TABLE]` marker so only one server posts it (others skip on detect).
- **GCP Project ID discovery** — `discover_local_ips()` now also fetches the GCP project ID from
  the instance metadata API (`/project/project-id`). Stored as `GCP_PROJECT` at runtime and
  `COORDINATOR_GCP_PROJECT` in `coordinator.env`. Falls back to `"unknown"` on non-GCP hosts.
- **Roll call includes `project:` and `host:` fields** — each server's roll call response now
  carries `project: <gcp-project-id>` and `host: <fqdn>`, enabling table aggregation and peer
  registry enrichment.
- **Peer registry stores project** — `update_peer_registry()` gains a `project` parameter; the
  `coordinator-peers.json` entry for each peer now includes a `project` field alongside
  `public`, `private`, `zone`, `last_seen`.
- **`coordinator-fetch --peers`** — CLI command that reads `~/.claude/coordinator-peers.json` and
  prints a local formatted table of all known peers (hostname, public IP, private IP, GCP project,
  zone, last-seen date). No Slack fetch needed.
- Installer renamed `claude-4.6-install.sh` (was `claude-4.5-install.sh`). All internal URL
  references updated to reflect new major.minor version.

---

## [4.5.1] — 2026-02-26

### Added
- **`everyone upgrade` / `<hostname> upgrade`** — master can upgrade all servers (or specific ones)
  remotely via Slack with no SSH. Each server backs up its daemon binary, downloads the new
  installer, runs it, and waits up to 10 minutes for the service to come back active.
- **Automatic rollback watchdog** — if `claude-coordinator` is not active within 10 minutes of the
  upgrade, the server restores `/usr/local/bin/coordinator-daemon.bak`, restarts the service, and
  posts a rollback notice to Slack. If the rollback also fails, a CRITICAL alert is posted.
- **`coordinator-upgrade` script** — installed to `/usr/local/bin/coordinator-upgrade`. Handles
  backup, download, install, wait, success/failure reporting, and rollback in one script.
  Launched detached outside the service's cgroup via `sudo systemd-run --no-block` (falls back to
  `setsid nohup` if `systemd-run` unavailable).
- **`TARGET_USER_OVERRIDE`** — installer now accepts this env var when running directly as root,
  allowing `coordinator-upgrade` to run the installer without needing `SUDO_USER`.
- **`COORDINATOR_USER` and `COORDINATOR_INSTALLER_URL`** added to `coordinator.env` — upgrade
  script uses these to find the installer URL and target user at runtime.

### Changed
- Installer renamed `claude-4.5-install.sh` (was `claude-4.4-install.sh`) to reflect current
  major.minor version. All internal URL references updated.

---

## [4.5.0] — 2026-02-26

### Added
- **Peer sidebar threads** — servers can open a private troubleshooting thread with one or more
  peers autonomously, with no master involvement required. A sidebar is initiated by any running
  Claude session via `coordinator-post "SIDEBAR" --sidebar "peer-host" --sidebar-reason "why"`.
  Only the named participants respond; all diagnostic back-and-forth stays in the Slack thread;
  other servers never see or process the thread content.
- **BOT sidebar election** — once a sidebar is proposed, named participants elect a leader via
  a 15-second bid window inside the thread (`[COORDINATOR:SIDEBAR_ELECT]`). The winner runs
  `claude -p` with sidebar context; the follower awaits `TASK_ORDER` delegation.
- **IP self-discovery** — daemon discovers `PUBLIC_IP`, `PRIVATE_IP`, and `GCP_ZONE` at startup
  via `ifconfig.me`, `hostname -I`, and the GCP instance metadata API (with short timeout fallback).
- **Peer registry** (`~/.claude/coordinator-peers.json`) — populated automatically from roll call
  responses. Every roll call reply now includes `public:`, `private:`, and `zone:` fields.
  Provides direct peer IP info for ping/connectivity diagnostics inside sidebars.
- **`coordinator-post --sidebar`** / **`--sidebar-reason`** / **`--thread`** flags — `--sidebar`
  sets participant list in the signed payload; `--thread <ts>` posts any message into an existing
  Slack thread rather than the main channel.
- **CLAUDE.md sidebar section** — instructions for Claude on initiating sidebars, posting within
  threads, delegating sub-tasks in sidebar context, and resolving with a main-channel summary.

---

## [4.4.1] — 2026-02-26

### Added
- **Multi-master support** — `COORDINATOR_MASTER_USER_ID` now accepts a colon-separated list of
  Slack UIDs (e.g. `U0AH67SQ63C:U0AHK5EQGC9`). Any UID in the list is granted MASTER trust.
  All three master-UID checks in the daemon updated to use `tr ':' '\n' | grep -qxF`.
- `coordinator-patch-multimaster.sh` — hosted patch script; updates `coordinator.env` and
  live daemon on an already-installed server, then restarts the service.
- `new-network-setup.sh` — interactive bootstrap script for standing up a brand-new coordinator
  network from scratch. Replaces all manual file editing and hardcoded values.

### Fixed
- **Auth check hang** — replaced `claude -p 'respond with: ok'` pre-auth check with a direct
  inspection of `~/.claude.json` for stored credentials. The `claude -p` call when unauthenticated
  silently waits for interactive input, causing the installer to hang indefinitely. The json check
  is instant and requires no network or subprocess.
- **API key auth path** — installer now asks whether the account is Claude Pro/Max (OAuth) or
  Anthropic Console API billing (API key) before starting authentication. Previously it always
  started the OAuth flow, which requires a Pro/Max subscription and fails for API-billing-only
  accounts. Choosing option 2 prompts for an `sk-ant-` key and writes it to `~/.claude.json`.
- **`classify_target()` and `is_multi_target()` false-trigger on command body** — both functions
  previously scanned the full Slack message text, causing keywords like `everyone` or server
  hostnames appearing inside a shell command body (after `run:`) to falsely match, making all
  servers respond to targeted commands. Both functions now extract a `header` variable by
  stripping everything from the first ` run:` onward before doing any pattern matching.
- **Leader delegation `to=all` misfire** — when a named server was busy/unavailable during a
  leader-elected task, the elected leader was broadcasting sub-tasks to the entire network as a
  substitute. `--to all` delegation is now only permitted when the original message addressed
  the whole network; specifically-named-but-busy servers are reported as unavailable instead.

---

## [4.4.0] — 2026-02-26

Initial public release of installer v4.4.

### Added (v4.4)
- Interactive OAuth login during install using Anthropic Console / API billing flow
- Auto-captures the OAuth URL from `claude auth login`, displays it to the user in-terminal
- Waits for user to paste the code back, feeds it to the auth process, verifies auth
- Falls back to fully interactive `claude auth login` if URL cannot be auto-captured

### Added (v4.3)
- OAuth-over-Slack watchdog recovery: when auth expires, watchdog starts the OAuth flow,
  posts the URL to Slack, waits for `<server> auth-code: XXXXX` reply, completes handshake
- Startup grace period (3 min) prevents false watchdog alerts during install
- Auth type detection (OAuth vs API key) selects the correct recovery path
- `everyone` broadcast keyword — all servers respond to non-destructive commands
- Destructive command safety — `everyone rm/delete/stop/...` refused by all servers with warning
- Roll call now includes installer version number

### Added (v4.2)
- Dynamic leader election for multi-server tasks
- Servers detect when multiple named servers are addressed in one message
- Deterministic jitter (0–8s via hostname+task_id hash) spreads election bids
- 15-second election window — first Slack timestamp wins
- Elected leader receives delegation prompt; can assign subtasks via `coordinator-post --task-order`
- `coordinator-post` gains `--task-order`, `--task-done`, `--task-id`, `--to` flags
- Election state tracked in `~/.claude/coordinator-elections/`

### Added (v4.1)
- Autonomous background daemon (`claude-coordinator` systemd service)
- Auth watchdog (`claude-coordinator-watchdog` systemd service)
- Remote API key recovery via Slack: `<server> api-key: sk-ant-...`
- Auto-approved tool permissions (`settings.json`) for unattended operation
- Confirmation flow for ambiguous (no server named) messages
- Roll call feature — all servers respond with status when master posts `roll call`
- `jq` replaces all `python3` JSON parsing (removes python3 dependency)
- Tight hostname matching with word-boundary regex (prevents partial-name false triggers)

### Added (v4.0)
- `cc` global wrapper with coordinator context injection
- `/leader` slash command for LEADER-trust signed posting
- HMAC-SHA256 trust hierarchy: MASTER > LEADER > BOT > UNVERIFIED
- Master key derived at install time, immediately discarded from disk
- `coordinator-post`, `coordinator-fetch`, `coordinator-announce` scripts
- CLAUDE.md coordinator section written to each server
