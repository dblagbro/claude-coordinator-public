# Claude Coordinator Network

A multi-server orchestration system for [Claude Code](https://claude.ai/code) CLI. Servers communicate via Slack, auto-elect leaders for multi-server tasks, and recover from auth failures — all without SSH.

## What it does

- **Autonomous daemon** — each server polls a private Slack channel and executes tasks posted by the master user
- **Dynamic leader election** — when a task addresses multiple servers, they automatically elect a leader via a 15-second bid window; the winner runs the task and can delegate subtasks to followers
- **Peer sidebar threads** — servers can open a private troubleshooting thread between themselves without master involvement; other servers never see or process the sidebar content
- **IP self-discovery + peer registry** — each server discovers its public IP, private IP, and GCP zone at startup; roll calls populate a shared peer registry used for direct connectivity tests inside sidebars
- **OAuth or API key auth** — installer asks which auth method you use (Claude Pro/Max OAuth or Anthropic Console API billing key) and handles either path interactively
- **OAuth-over-Slack watchdog recovery** — if auth expires post-install, the watchdog posts the OAuth URL to Slack; paste the code back and it self-heals with no SSH needed
- **Multi-master support** — `COORDINATOR_MASTER_USER_ID` accepts a colon-separated list of Slack UIDs; any UID in the list gets full MASTER trust
- **`everyone` broadcast** with destructive-command safety — `everyone run: date` works; `everyone run: rm -rf /` is refused by all servers
- **Roll call** with version and IPs — post `roll call` to see all online servers, their version, role, status, public IP, private IP, and GCP zone
- **Confirmation** — ambiguous messages (no server named) prompt for confirmation before acting
- **Trust hierarchy** — MASTER (Slack UID) > LEADER (HMAC-signed) > BOT (verified peer) > UNVERIFIED

---

## Setting up a new network

Use `new-network-setup.sh` to bootstrap a complete coordinator network from scratch — no manual file editing or hardcoded values required.

```bash
./new-network-setup.sh
```

The script walks through 6 phases interactively (~10 minutes):

1. **Preflight** — checks `curl`, `jq`, `openssl`; collects your email, network label, and hosting choice
2. **Slack app** — displays a copy-paste YAML app manifest; creates the private `#coordinator-<label>` channel via Slack API; invites you automatically
3. **Keys** — generates a 64-char hex master key and derives HMAC keys; writes `cfg.cfg` and `coordinator-creds.cfg`
4. **Compiler** — parameterizes `install.sh` into `coordinator-install-<label>.sh`; replaces all hardcoded URLs/email; syntax-checks the output; verifies no hardcoded strings remain
5. **Hosting** — uploads files via SCP (web server), `gh` CLI (GitHub private repo), or `gsutil` (GCP bucket)
6. **Summary** — prints ready-to-use install commands; optionally runs the installer on the current machine

Hosting options:

| Option | Tool required | URL type |
|--------|--------------|----------|
| Web server | `scp` | `https://your-domain.com/...` (public) |
| GitHub private repo | `gh` CLI (authenticated) | `raw.githubusercontent.com` (token required for private) |
| GCP bucket | `gsutil` | `storage.googleapis.com/...` (public) |

After running `new-network-setup.sh`, install on any server with the URL from the summary output:

```bash
sudo wget -O /tmp/install.sh '<INSTALLER_URL>'
sudo chmod +x /tmp/install.sh
sudo /tmp/install.sh

# Leader-capable server:
COORDINATOR_LEADER=1 sudo /tmp/install.sh
```

---

## Quick install (existing network)

If a coordinator network is already set up, install on a new server using the compiled installer URL from your network's setup summary.

```bash
sudo wget -O /tmp/install.sh '<YOUR_INSTALLER_URL>'
sudo chmod +x /tmp/install.sh
sudo /tmp/install.sh
```

---

## Sending commands from Slack

Once installed, the master user posts commands in the private coordinator channel:

| Message | Effect |
|---------|--------|
| `roll call` | All online servers reply with status; one server auto-posts a formatted table (hostname, ver, role, status, uptime, public/private IP, GCP project, zone, full hostname) |
| `everyone upgrade` | All servers self-upgrade with 10-min rollback watchdog |
| `<hostname> upgrade` | Single server self-upgrade with 10-min rollback watchdog |
| `<hostname> run: <command>` | That server runs the command and posts output |
| `<host-a> and <host-b> run: <command>` | Leader election; winner runs task, can delegate |
| `everyone run: <command>` | All servers run (safe commands only) |
| `<hostname> auth-code: XXXXX` | Completes OAuth watchdog recovery |
| `<hostname> api-key: sk-ant-...` | Remotely injects an API key for auth recovery |

Destructive commands (`rm`, `delete`, `stop`, `kill`, `drop`, `wipe`, `format`, `reboot`) are blocked from `everyone` broadcast.

---

## Peer sidebar threads

Servers can troubleshoot issues between themselves autonomously — no master needed, no other servers involved.

**How it works:**

1. Server A (while running a Claude task) initiates a sidebar:
   ```bash
   coordinator-post "SIDEBAR" --sidebar "fall-compute-26" --sidebar-reason "rabbitmq replication lag"
   ```
2. This posts a HMAC-signed proposal to the main channel. Only `fall-anchor-25` and `fall-compute-26` respond.
3. Both servers post election bids into the **thread** of that message (0–8s jitter).
4. First bid wins — winner leads the sidebar in-thread; loser awaits task delegation.
5. All diagnostic back-and-forth stays in the thread. Other servers' daemons never process it.
6. Leader posts a one-line summary back to the main channel when resolved.

**What the channel looks like:**

```
[main channel]
fall-anchor-25: "SIDEBAR" (signed)
  └─ [thread — only these two servers]
     fall-anchor-25: elected leader — investigating rabbitmq replication lag
     fall-anchor-25: queue depth 142k, last sync 8m ago, private IP 10.128.0.5
     fall-compute-26: sub-task complete — depth 3k, seeing 12% packet loss to you
     fall-anchor-25: sidebar work complete — restarted NIC on fall-compute-26, lag cleared
fall-anchor-25: Sidebar resolved: packet loss on fall-compute-26 NIC fixed, replication restored
```

**Peer network info** is available during sidebars via the peer registry (populated by roll calls):
```bash
cat ~/.claude/coordinator-peers.json
# {"fall-anchor-25": {"public":"34.82.1.1","private":"10.128.0.5","zone":"us-central1-a","project":"my-gcp-project",...}, ...}
```

Or view it as a formatted table from the CLI (no Slack fetch needed):
```bash
coordinator-fetch --peers
# Hostname              Public IP        Private IP       GCP Project             Zone              Last Seen
# --------------------------------------------------------------------------------------------------------
# fall-anchor-25        34.82.1.1        10.128.0.5       my-gcp-project          us-central1-a     2026-02-26
# fall-compute-26       34.82.2.2        10.128.0.6       my-gcp-project          us-central1-b     2026-02-26
```

---

## Auth during install

The installer asks which auth method your account uses:

```
[1] Claude Pro / Max — OAuth (claude.ai subscription)
[2] Anthropic Console / API billing — API key (sk-ant-...)
```

- **Option 1 (OAuth)** — opens the Anthropic OAuth flow, captures the URL automatically, waits for you to paste the code back, then completes auth
- **Option 2 (API key)** — prompts for your `sk-ant-` key and writes it directly to `~/.claude.json`

If credentials are already present in `~/.claude.json`, the auth step is skipped automatically.

---

## Multi-master support

`COORDINATOR_MASTER_USER_ID` can hold a colon-separated list of Slack UIDs:

```
COORDINATOR_MASTER_USER_ID=U0AH67SQ63C:U0AHK5EQGC9
```

All UIDs in the list get full MASTER trust — they can issue commands, trigger roll calls, do auth recovery, etc.

### Patching an already-installed server

If you need to add multi-master support to a server that was installed before v4.4.1:

```bash
sudo wget -O /tmp/patch.sh https://<YOUR_SERVER_URL>/coordinator-patch-multimaster.sh
sudo bash /tmp/patch.sh
```

This updates `~/.claude/coordinator.env` and the live daemon binary, then restarts the service.

---

## Requirements

- Debian/Ubuntu Linux (apt-based)
- `curl`, `jq`, `openssl` (installed automatically by `install.sh`)
- A Slack workspace with a bot token (`xoxb-`) and private channel
- Anthropic API key (`sk-ant-`) or Claude Pro/Max account for OAuth
- For `new-network-setup.sh`: one of `scp` / `gh` / `gsutil` for file hosting

---

## Configuration files

The installer fetches credentials from your own hosted config files at install time:

- `cfg.cfg` — single line: 64-char hex master key (generated by `new-network-setup.sh`)
- `coordinator-creds.cfg` — 3 lines:
  ```
  COORDINATOR_TOKEN=xoxb-...
  COORDINATOR_CHANNEL_ID=C...
  COORDINATOR_MASTER_USER_ID=U...:U...
  ```

These are never stored in this repo. `new-network-setup.sh` generates and hosts them automatically.

---

## How servers communicate

```
Master user posts in Slack:
  "fall-anchor-25 run: df -h"

Daemon on fall-anchor-25:
  1. Verifies message is from a master Slack UID
  2. Matches hostname (word-boundary regex, command body excluded)
  3. Spawns: claude -p "..." --dangerously-skip-permissions
  4. Posts result back to Slack
```

For multi-server tasks:
```
Master: "fall-anchor-25 and fall-compute-25: check rabbitmq status"

Both servers:
  1. Detect they are both named in the message header
  2. Each posts an election bid with deterministic jitter (0–8s)
  3. First bid wins — winner proceeds as elected leader
  4. Loser waits for TASK_ORDER delegation from winner
```

---

## Version history

| Version | Key additions |
|---------|--------------|
| v4.0 | `cc` wrapper, `/leader` command, HMAC trust hierarchy, coordinator context |
| v4.1 | Autonomous background daemon, auto-permissions, auth watchdog |
| v4.2 | Dynamic leader election for multi-server tasks |
| v4.3 | OAuth-over-Slack watchdog recovery, startup grace period, `everyone` broadcast safety |
| v4.4.0 | Interactive auth install flow (OAuth URL auto-capture) |
| v4.4.1 | Multi-master UIDs, API key auth path, auth hang fix, command-body false-trigger fix |
| v4.5.0 | Peer sidebar threads (BOT-initiated), IP self-discovery, peer registry, `--sidebar`/`--thread` flags |
| v4.5.1 | Remote upgrade via Slack (`everyone upgrade`), 10-min rollback watchdog, `coordinator-upgrade` script |
| v4.6.0 | Roll call table (auto-aggregated, code-block), GCP project discovery, `coordinator-fetch --peers` |

---

## Slash commands

- `/leader` — activate leader mode in a `cc` session, allowing LEADER-trust signed posts to peer servers

---

## Security

- All coordinator messages are HMAC-SHA256 signed
- Master key is derived at install time from your config endpoint and immediately discarded — never stored on servers
- Leader token is a separate HMAC derived from the master key
- Elected leader tokens are task-scoped and time-windowed (1-hour buckets)
- The `--dangerously-skip-permissions` flag is used intentionally for autonomous operation — restrict network/firewall access appropriately
- Command body content (after `run:`) is excluded from hostname/target matching to prevent injection-style false triggers

---

## License

MIT
