#!/usr/bin/env bash
# new-network-setup.sh
# v1.0 — Interactive bootstrap for a new Claude Coordinator Network
#
# Creates a complete, ready-to-run coordinator network from scratch:
#   Phase 1: Preflight checks + collect email, label, hosting details
#   Phase 2: Guided Slack app creation + private channel setup via API
#   Phase 3: Cryptographic key generation (MASTER_KEY + derived HMAC keys)
#   Phase 4: Parameterize claude-4.4-install.sh → coordinator-install-<label>.sh
#   Phase 5: Host cfg.cfg, coordinator-creds.cfg, and installer
#   Phase 6: Summary + optional local install
#
# Usage:
#   ./new-network-setup.sh
#
# Required: curl, jq, openssl, scp (web) OR gh (GitHub) OR gsutil (GCP)

set -euo pipefail

# ════════════════════════════════════════════════════════════════════
# Utility
# ════════════════════════════════════════════════════════════════════

c_red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
c_green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
c_blue()   { printf '\033[0;34m%s\033[0m\n' "$*"; }
c_bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

step()  {
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $*"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
die()  { echo; c_red "ERROR: $*" >&2; exit 1; }
ok()   { c_green "  ✓ $*"; }
warn() { c_yellow "  WARNING: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/claude-4.4-install.sh"
WORK_DIR="${SCRIPT_DIR}"

# Escape a string for use as a sed replacement (escapes |, &, \)
sed_esc() {
  printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

# Slack API call wrapper — prints response JSON
slack_api() {
  local method="$1"; shift        # GET or POST
  local endpoint="$1"; shift      # e.g. conversations.create
  local token="$1"; shift         # xoxb-... or xoxp-...
  local data="${1:-}"             # optional JSON body

  if [[ "$method" == "POST" ]]; then
    curl -sf --max-time 20 \
      -X POST "https://slack.com/api/${endpoint}" \
      --header "Authorization: Bearer ${token}" \
      --header "Content-Type: application/json" \
      --data "${data}" 2>/dev/null
  else
    curl -sf --max-time 20 \
      -X GET "https://slack.com/api/${endpoint}" \
      --header "Authorization: Bearer ${token}" 2>/dev/null
  fi
}

# ════════════════════════════════════════════════════════════════════
# PHASE 1 — Preflight & Info Collection
# ════════════════════════════════════════════════════════════════════

phase1_preflight() {
  step "PHASE 1 — Preflight & Info Collection"

  # Template check
  [[ -f "$TEMPLATE" ]] || die "Template installer not found: $TEMPLATE"

  # Required base tools
  echo
  echo "  Checking required tools..."
  local missing=()
  for cmd in curl jq openssl; do
    if command -v "$cmd" &>/dev/null; then
      ok "$cmd"
    else
      missing+=("$cmd")
      c_red "  ✗ $cmd — NOT FOUND"
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Install missing tools and re-run: ${missing[*]}"
  fi

  # Email
  echo
  c_bold "  Your email address (replaces the hardcoded <YOUR_EMAIL> throughout the installer):"
  printf "    Email: "
  read -r USER_EMAIL
  [[ -n "$USER_EMAIL" ]] || die "Email cannot be empty"
  [[ "$USER_EMAIL" == *@* ]] || die "That doesn't look like an email address"
  ok "Email: $USER_EMAIL"

  # Network label
  echo
  c_bold "  Network name/label (letters, digits, hyphens only — e.g. myteam, acme-ops, lab01):"
  c_bold "  Used as: channel name (#coordinator-<label>), installer filename, GCP bucket name."
  printf "    Label: "
  read -r NET_LABEL
  NET_LABEL="${NET_LABEL// /-}"   # replace spaces with hyphens
  NET_LABEL="${NET_LABEL,,}"      # lowercase
  [[ -n "$NET_LABEL" ]] || die "Label cannot be empty"
  [[ "$NET_LABEL" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || \
    die "Label must start with a letter/digit and contain only letters, digits, hyphens, underscores"
  ok "Network label: $NET_LABEL"

  # Derived names
  CHANNEL_NAME="coordinator-${NET_LABEL}"
  INSTALLER_FILENAME="coordinator-install-${NET_LABEL}.sh"
  CFG_OUT="${WORK_DIR}/cfg.cfg"
  CREDS_OUT="${WORK_DIR}/coordinator-creds.cfg"
  INSTALLER_OUT="${WORK_DIR}/${INSTALLER_FILENAME}"

  # Hosting choice
  echo
  c_bold "  Where will you host the 3 network files (cfg.cfg, coordinator-creds.cfg, installer)?"
  echo
  echo "    [1] Web server  — SCP to your server + public HTTPS base URL (recommended)"
  echo "    [2] GitHub      — private repo via 'gh' CLI"
  echo "                      NOTE: private raw.githubusercontent.com URLs require a token."
  echo "                      Good for installs where you can pass a token; not fully public."
  echo "    [3] GCP bucket  — gsutil + public storage.googleapis.com URLs"
  echo
  printf "    Choice [1/2/3]: "
  read -r HOST_CHOICE

  case "$HOST_CHOICE" in
    1)
      HOST_TYPE="web"
      for cmd in ssh scp; do
        command -v "$cmd" &>/dev/null || die "$cmd not found (required for web server option)"
      done
      echo
      c_bold "  Web server details:"
      printf "    SCP destination (user@host:/path/to/webroot/ with trailing slash):\n    "
      read -r SCP_DEST
      [[ -n "$SCP_DEST" ]] || die "SCP destination cannot be empty"
      printf "    Base URL (e.g. https://example.com/coordinator — no trailing slash):\n    "
      read -r BASE_URL
      BASE_URL="${BASE_URL%/}"
      [[ -n "$BASE_URL" ]] || die "Base URL cannot be empty"
      [[ "$BASE_URL" == https://* || "$BASE_URL" == http://* ]] || \
        die "Base URL must start with http:// or https://"
      KEY_URL="${BASE_URL}/cfg.cfg"
      CREDS_URL="${BASE_URL}/coordinator-creds.cfg"
      INSTALLER_URL="${BASE_URL}/${INSTALLER_FILENAME}"
      ok "Web server: $BASE_URL"
      ;;

    2)
      HOST_TYPE="github"
      command -v gh &>/dev/null || die "'gh' CLI not found (install: https://cli.github.com)"
      gh auth status &>/dev/null || die "'gh' not authenticated — run: gh auth login"
      GH_USER=$(gh api user -q .login 2>/dev/null) || die "Could not retrieve GitHub username"
      GH_REPO="${NET_LABEL}-coordinator"
      BASE_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/main"
      KEY_URL="${BASE_URL}/cfg.cfg"
      CREDS_URL="${BASE_URL}/coordinator-creds.cfg"
      INSTALLER_URL="${BASE_URL}/${INSTALLER_FILENAME}"
      warn "Private GitHub raw URLs require auth tokens — users will need:"
      warn "  curl -H 'Authorization: token TOKEN' $INSTALLER_URL"
      warn "Consider option [1] (web server) for fully public installs."
      echo
      ok "GitHub: ${GH_USER}/${GH_REPO}"
      ;;

    3)
      HOST_TYPE="gcp"
      command -v gsutil &>/dev/null || die "gsutil not found (install Google Cloud SDK)"
      GCP_BUCKET="${NET_LABEL}-coordinator"
      BASE_URL="https://storage.googleapis.com/${GCP_BUCKET}"
      KEY_URL="${BASE_URL}/cfg.cfg"
      CREDS_URL="${BASE_URL}/coordinator-creds.cfg"
      INSTALLER_URL="${BASE_URL}/${INSTALLER_FILENAME}"
      ok "GCP bucket: gs://${GCP_BUCKET}"
      ;;

    *)
      die "Invalid choice '$HOST_CHOICE' — enter 1, 2, or 3"
      ;;
  esac

  # Extract hosting domain for trust references in the installer
  TRUST_DOMAIN=$(printf '%s' "$INSTALLER_URL" | sed 's|https\?://||; s|/.*||')

  echo
  echo "  Planned URLs:"
  echo "    Key:       $KEY_URL"
  echo "    Creds:     $CREDS_URL"
  echo "    Installer: $INSTALLER_URL"
  echo
  echo "  Local output files:"
  echo "    $CFG_OUT"
  echo "    $CREDS_OUT"
  echo "    $INSTALLER_OUT"
}

# ════════════════════════════════════════════════════════════════════
# PHASE 2 — Slack App Setup
# ════════════════════════════════════════════════════════════════════

phase2_slack() {
  step "PHASE 2 — Slack App Setup"

  # ── 2a. Guided app creation ──────────────────────────────────────
  echo
  c_bold "  Step 2a — Create your Slack app:"
  echo
  echo "  1. Open: https://api.slack.com/apps"
  echo "  2. Click 'Create New App' → 'From an app manifest'"
  echo "  3. Select your workspace → click Next"
  echo "  4. Choose YAML, paste the manifest below → click Next → Create"
  echo "  5. Click 'Install to Workspace' and authorize"
  echo "  6. Copy the 'Bot User OAuth Token' (xoxb-...)"
  echo
  c_blue "  ┌── PASTE THIS MANIFEST ──────────────────────────────────────────┐"
  cat <<MANIFEST
display_information:
  name: ClaudeCoordinator-${NET_LABEL}
  description: Claude Coordinator Network bot for '${NET_LABEL}'
features:
  bot_user:
    display_name: ClaudeCoordinator-${NET_LABEL}
    always_online: true
oauth_config:
  scopes:
    bot:
      - chat:write
      - channels:history
      - groups:history
      - groups:read
      - groups:write
      - users:read
    user:
      - identity.basic
settings:
  org_deploy_enabled: false
  socket_mode_enabled: false
  token_rotation_enabled: false
MANIFEST
  c_blue "  └────────────────────────────────────────────────────────────────────┘"
  echo
  printf "  Press Enter when you have created and installed the app... "
  read -r

  # ── 2b. Collect tokens ───────────────────────────────────────────
  echo
  c_bold "  Step 2b — Enter your tokens:"
  echo
  printf "  Bot Token (xoxb-...): "
  read -r -s SLACK_BOT_TOKEN
  echo
  [[ "$SLACK_BOT_TOKEN" == xoxb-* ]] || die "Bot token must start with 'xoxb-'"
  ok "Bot token accepted"

  echo
  echo "  Your User Token (xoxp-) lets us look up your Slack UID automatically."
  echo "  Find it at: https://api.slack.com/apps → your app → OAuth & Permissions → User OAuth Token"
  echo "  (Or press Enter to skip and type your UID manually.)"
  echo
  printf "  User Token (xoxp-...) or Enter to skip: "
  read -r -s SLACK_USER_TOKEN
  echo

  # ── 2c. Get master UID ───────────────────────────────────────────
  MASTER_UID=""

  if [[ -n "$SLACK_USER_TOKEN" ]]; then
    if [[ "$SLACK_USER_TOKEN" != xoxp-* ]]; then
      warn "User token doesn't start with 'xoxp-' — skipping auto-lookup"
    else
      echo "  Looking up your Slack UID via auth.test..."
      AUTH_RESP=$(slack_api GET "auth.test" "$SLACK_USER_TOKEN") || true
      if [[ -n "$AUTH_RESP" ]]; then
        AUTH_OK=$(echo "$AUTH_RESP" | jq -r '.ok // "false"')
        if [[ "$AUTH_OK" == "true" ]]; then
          MASTER_UID=$(echo "$AUTH_RESP" | jq -r '.user_id // ""')
          [[ -n "$MASTER_UID" && "$MASTER_UID" != "null" ]] \
            && ok "Master Slack UID: $MASTER_UID" \
            || { warn "Could not extract user_id from response"; MASTER_UID=""; }
        else
          warn "auth.test error: $(echo "$AUTH_RESP" | jq -r '.error // "unknown"')"
        fi
      fi
    fi
  fi

  if [[ -z "$MASTER_UID" ]]; then
    echo
    echo "  How to find your Slack UID manually:"
    echo "    1. Open Slack → click your name/avatar in the sidebar"
    echo "    2. Click the '...' (More) menu → 'Copy member ID'"
    echo "    It looks like: U0123456789"
    echo
    printf "  Your Slack UID (U...): "
    read -r MASTER_UID
    [[ "$MASTER_UID" == U* ]] || die "Slack UID must start with 'U' — got: $MASTER_UID"
    ok "Master Slack UID: $MASTER_UID"
  fi

  # ── Create private channel ───────────────────────────────────────
  echo
  echo "  Creating private channel #${CHANNEL_NAME}..."
  CREATE_RESP=$(slack_api POST "conversations.create" "$SLACK_BOT_TOKEN" \
    "{\"name\":\"${CHANNEL_NAME}\",\"is_private\":true}") \
    || die "HTTP request to conversations.create failed"

  CREATE_OK=$(echo "$CREATE_RESP" | jq -r '.ok // "false"')
  if [[ "$CREATE_OK" == "true" ]]; then
    CHANNEL_ID=$(echo "$CREATE_RESP" | jq -r '.channel.id')
    ok "Channel #${CHANNEL_NAME} created: $CHANNEL_ID"
  else
    CREATE_ERR=$(echo "$CREATE_RESP" | jq -r '.error // "unknown"')
    if [[ "$CREATE_ERR" == "name_taken" ]]; then
      warn "Channel #${CHANNEL_NAME} already exists — looking it up..."
      LIST_RESP=$(curl -sf --max-time 30 \
        -X GET "https://slack.com/api/conversations.list?types=private_channel&limit=200&exclude_archived=true" \
        --header "Authorization: Bearer ${SLACK_BOT_TOKEN}" 2>/dev/null) \
        || die "Failed to list channels"
      CHANNEL_ID=$(echo "$LIST_RESP" | jq -r \
        ".channels[] | select(.name==\"${CHANNEL_NAME}\") | .id" | head -1)
      if [[ -n "$CHANNEL_ID" && "$CHANNEL_ID" != "null" ]]; then
        ok "Found existing channel #${CHANNEL_NAME}: $CHANNEL_ID"
      else
        die "Channel #${CHANNEL_NAME} exists but bot cannot see it. Add the bot manually then re-run."
      fi
    else
      die "conversations.create failed: $CREATE_ERR"
    fi
  fi

  # ── Invite master user to channel ───────────────────────────────
  echo
  echo "  Inviting you ($MASTER_UID) to #${CHANNEL_NAME}..."
  INV_RESP=$(slack_api POST "conversations.invite" "$SLACK_BOT_TOKEN" \
    "{\"channel\":\"${CHANNEL_ID}\",\"users\":\"${MASTER_UID}\"}") || true
  INV_OK=$(echo "$INV_RESP" | jq -r '.ok // "false"' 2>/dev/null || echo "false")
  if [[ "$INV_OK" == "true" ]]; then
    ok "You have been invited to #${CHANNEL_NAME}"
  else
    INV_ERR=$(echo "$INV_RESP" | jq -r '.error // ""' 2>/dev/null || echo "")
    case "$INV_ERR" in
      already_in_channel|cant_invite_self) ok "Already in #${CHANNEL_NAME}" ;;
      *) warn "Could not auto-invite you (${INV_ERR:-unknown}). Join #${CHANNEL_NAME} manually in Slack." ;;
    esac
  fi
}

# ════════════════════════════════════════════════════════════════════
# PHASE 3 — Key Generation
# ════════════════════════════════════════════════════════════════════

phase3_keys() {
  step "PHASE 3 — Key Generation"
  echo

  MASTER_KEY=$(openssl rand -hex 32)
  [[ ${#MASTER_KEY} -eq 64 ]] || die "openssl rand produced unexpected output (${#MASTER_KEY} chars, want 64)"
  ok "Generated MASTER_KEY (${#MASTER_KEY}-char hex)"

  COORDINATOR_HMAC_KEY=$(printf '%s' "COORDINATOR_VALIDATION_V1" \
    | openssl dgst -sha256 -hmac "$MASTER_KEY" 2>/dev/null | awk '{print $NF}')
  [[ ${#COORDINATOR_HMAC_KEY} -eq 64 ]] || die "HMAC key derivation failed (got ${#COORDINATOR_HMAC_KEY} chars)"
  ok "Derived COORDINATOR_HMAC_KEY"

  COORDINATOR_LEADER_TOKEN=$(printf '%s' "LEADER_DELEGATION_TOKEN" \
    | openssl dgst -sha256 -hmac "$MASTER_KEY" 2>/dev/null | awk '{print $NF}')
  [[ ${#COORDINATOR_LEADER_TOKEN} -eq 64 ]] || die "Leader token derivation failed (got ${#COORDINATOR_LEADER_TOKEN} chars)"
  ok "Derived COORDINATOR_LEADER_TOKEN"

  # Write cfg.cfg — single hex line (the master key)
  printf '%s\n' "$MASTER_KEY" > "$CFG_OUT"
  VERIFY=$(tr -d '[:space:]' < "$CFG_OUT")
  [[ ${#VERIFY} -eq 64 ]] || die "cfg.cfg validation failed: expected 64 chars, got ${#VERIFY}"
  ok "Written and validated: $CFG_OUT"

  # Write coordinator-creds.cfg — 3 KEY=VALUE lines
  {
    echo "COORDINATOR_TOKEN=${SLACK_BOT_TOKEN}"
    echo "COORDINATOR_CHANNEL_ID=${CHANNEL_ID}"
    echo "COORDINATOR_MASTER_USER_ID=${MASTER_UID}"
  } > "$CREDS_OUT"

  grep -q "^COORDINATOR_TOKEN=" "$CREDS_OUT"         || die "creds validation: missing COORDINATOR_TOKEN"
  grep -q "^COORDINATOR_CHANNEL_ID=" "$CREDS_OUT"    || die "creds validation: missing COORDINATOR_CHANNEL_ID"
  grep -q "^COORDINATOR_MASTER_USER_ID=" "$CREDS_OUT" || die "creds validation: missing COORDINATOR_MASTER_USER_ID"
  ok "Written and validated: $CREDS_OUT"

  echo
  echo "  Keys in memory (not written to disk beyond cfg.cfg):"
  echo "    COORDINATOR_HMAC_KEY    = ${COORDINATOR_HMAC_KEY:0:12}... (${#COORDINATOR_HMAC_KEY} chars)"
  echo "    COORDINATOR_LEADER_TOKEN = ${COORDINATOR_LEADER_TOKEN:0:12}... (${#COORDINATOR_LEADER_TOKEN} chars)"
}

# ════════════════════════════════════════════════════════════════════
# PHASE 4 — Installer Compilation
# ════════════════════════════════════════════════════════════════════

phase4_compile() {
  step "PHASE 4 — Installer Compilation"
  echo
  echo "  Copying template → $INSTALLER_OUT"
  cp "$TEMPLATE" "$INSTALLER_OUT"
  chmod +x "$INSTALLER_OUT"

  # Pre-escape all replacement strings for sed (|, &, \ are safe now)
  local E_KEY_URL E_CREDS_URL E_INSTALLER_URL E_EMAIL E_DOMAIN E_FILENAME
  E_KEY_URL=$(sed_esc "$KEY_URL")
  E_CREDS_URL=$(sed_esc "$CREDS_URL")
  E_INSTALLER_URL=$(sed_esc "$INSTALLER_URL")
  E_EMAIL=$(sed_esc "$USER_EMAIL")
  E_DOMAIN=$(sed_esc "$TRUST_DOMAIN")
  E_FILENAME=$(sed_esc "$INSTALLER_FILENAME")

  echo
  echo "  Applying substitutions..."

  # 1. COORDINATOR_KEY_URL variable (line ~401)
  sed -i \
    "s|COORDINATOR_KEY_URL=\"https://<YOUR_SERVER_URL>/<KEY_FILE>\"|COORDINATOR_KEY_URL=\"${E_KEY_URL}\"|g" \
    "$INSTALLER_OUT"
  ok "COORDINATOR_KEY_URL → $KEY_URL"

  # 2. COORDINATOR_CREDS_URL variable (line ~402)
  sed -i \
    "s|COORDINATOR_CREDS_URL=\"https://<YOUR_SERVER_URL>/<CREDS_FILE>\"|COORDINATOR_CREDS_URL=\"${E_CREDS_URL}\"|g" \
    "$INSTALLER_OUT"
  ok "COORDINATOR_CREDS_URL → $CREDS_URL"

  # 3. All email occurrences (lines 677, 691, 1494, 1547, 1557, 1579)
  sed -i "s|<YOUR_USERNAME>@gmail\.com|${E_EMAIL}|g" "$INSTALLER_OUT"
  ok "<YOUR_EMAIL> → $USER_EMAIL"

  # 4. Installer URL — current version (lines 13, 1642, 1689)
  sed -i \
    "s|https://<YOUR_SERVER_URL>/install.sh|${E_INSTALLER_URL}|g" \
    "$INSTALLER_OUT"
  ok "<YOUR_SERVER_URL>/claude-4-install.sh → $INSTALLER_URL"

  # 5. Installer URL — v4.3 reference in OAuth recovery section (line ~1316)
  sed -i \
    "s|https://<YOUR_SERVER_URL>/install.sh|${E_INSTALLER_URL}|g" \
    "$INSTALLER_OUT"
  ok "<YOUR_SERVER_URL>/claude-4.3-install.sh → $INSTALLER_URL"

  # 6. Bare installer filename in comments, echo strings, re-run instructions
  #    Covers: line 1726 (COORDINATOR_LEADER=1 sudo ./claude-4-install.sh),
  #            line 1800 (generated by comment), line 1864 (echo), line 1940 (re-run),
  #            line 1556 (backtick reference)
  sed -i "s|claude-4-install\.sh|${E_FILENAME}|g" "$INSTALLER_OUT"
  ok "claude-4-install.sh → $INSTALLER_FILENAME"

  # 7. Catch-all: remaining <YOUR_SERVER_URL> occurrences in comments and warn strings
  #    Covers: line 1505 (trusted domain), 1727 (fetched from), 1737 (HTTPS warn),
  #            1750 (fetch creds comment)
  sed -i "s|<YOUR_SERVER_URL>|${E_DOMAIN}|g" "$INSTALLER_OUT"
  ok "<YOUR_SERVER_URL> → $TRUST_DOMAIN (all remaining references)"

  # Syntax check
  echo
  echo "  Running syntax check (bash -n)..."
  if bash -n "$INSTALLER_OUT" 2>&1; then
    ok "Syntax check passed"
  else
    warn "Syntax check failed — review $INSTALLER_OUT before using"
  fi

  # Final verification — check for remaining hardcoded values
  echo
  echo "  Verifying no hardcoded values remain..."

  local VG_COUNT DB_COUNT
  VG_COUNT=$(grep -c "<YOUR_SERVER_URL>" "$INSTALLER_OUT" 2>/dev/null || echo "0")
  DB_COUNT=$(grep -c "<YOUR_USERNAME>" "$INSTALLER_OUT" 2>/dev/null || echo "0")

  if [[ "$VG_COUNT" -gt 0 ]]; then
    warn "$VG_COUNT remaining <YOUR_SERVER_URL> reference(s) — review manually:"
    grep -n "<YOUR_SERVER_URL>" "$INSTALLER_OUT" || true
  else
    ok "No remaining <YOUR_SERVER_URL> references"
  fi

  if [[ "$DB_COUNT" -gt 0 ]]; then
    warn "$DB_COUNT remaining '<YOUR_USERNAME>' reference(s) — review manually:"
    grep -n "<YOUR_USERNAME>" "$INSTALLER_OUT" || true
  else
    ok "No remaining '<YOUR_USERNAME>' references"
  fi

  echo
  ok "Installer compiled: $INSTALLER_OUT"
}

# ════════════════════════════════════════════════════════════════════
# PHASE 5 — File Hosting
# ════════════════════════════════════════════════════════════════════

phase5_hosting() {
  step "PHASE 5 — File Hosting"
  echo

  local FILES=("$CFG_OUT" "$CREDS_OUT" "$INSTALLER_OUT")

  case "$HOST_TYPE" in

    web)
      echo "  Uploading 3 files via SCP to ${SCP_DEST}..."
      scp "${FILES[@]}" "$SCP_DEST" || die "SCP upload failed"
      ok "Uploaded: cfg.cfg, coordinator-creds.cfg, $INSTALLER_FILENAME"
      ;;

    github)
      echo "  Creating private GitHub repository ${GH_USER}/${GH_REPO}..."
      gh repo create "${GH_REPO}" --private 2>/dev/null \
        || warn "Repo may already exist — will push to it"

      local TMP_CLONE
      TMP_CLONE=$(mktemp -d)

      # Try to clone existing; if repo is empty/new, init fresh
      if gh repo clone "${GH_USER}/${GH_REPO}" "$TMP_CLONE" -- --quiet 2>/dev/null; then
        cp "${FILES[@]}" "${TMP_CLONE}/"
        (
          cd "$TMP_CLONE"
          git add .
          git diff --cached --quiet \
            || git commit -m "Add coordinator network files for ${NET_LABEL}" --quiet
          git push --quiet
        )
        ok "Files pushed to GitHub"
      else
        cp "${FILES[@]}" "$TMP_CLONE/"
        (
          cd "$TMP_CLONE"
          git init --quiet
          git checkout -b main 2>/dev/null || true
          git add .
          git commit -m "Initial coordinator network files for ${NET_LABEL}" --quiet
          git remote add origin "https://github.com/${GH_USER}/${GH_REPO}.git"
          git push -u origin main --quiet
        )
        ok "Files pushed to GitHub (fresh repo)"
      fi
      rm -rf "$TMP_CLONE"
      ;;

    gcp)
      echo "  Creating GCP bucket gs://${GCP_BUCKET}..."
      gsutil mb "gs://${GCP_BUCKET}" 2>/dev/null \
        || warn "Bucket may already exist — continuing"
      echo "  Uploading files..."
      gsutil cp "${FILES[@]}" "gs://${GCP_BUCKET}/" || die "gsutil cp failed"
      echo "  Setting public read access..."
      gsutil iam ch allUsers:objectViewer "gs://${GCP_BUCKET}" \
        || die "gsutil iam failed — check GCP permissions"
      ok "Files uploaded to gs://${GCP_BUCKET} (public)"
      ;;

  esac

  # Verify reachability (skip for GitHub private repos — expected to require auth)
  if [[ "$HOST_TYPE" != "github" ]]; then
    echo
    echo "  Verifying hosted files are reachable..."
    local any_fail=false
    for url in "$KEY_URL" "$CREDS_URL"; do
      if curl -sf --max-time 25 "$url" &>/dev/null; then
        ok "Reachable: $url"
      else
        warn "Not yet reachable: $url"
        warn "  (DNS/CDN may take a moment — verify manually before running installs)"
        any_fail=true
      fi
    done
    $any_fail || ok "All hosted files verified reachable"
  fi
}

# ════════════════════════════════════════════════════════════════════
# PHASE 6 — Summary & First Server Bootstrap
# ════════════════════════════════════════════════════════════════════

phase6_summary() {
  step "PHASE 6 — Summary"

  echo
  c_green "╔══════════════════════════════════════════════════════════════════════╗"
  c_green "║         Claude Coordinator Network — Setup Complete                 ║"
  c_green "╚══════════════════════════════════════════════════════════════════════╝"
  echo
  echo "  Network name:   ${NET_LABEL}"
  echo "  Channel:        #${CHANNEL_NAME}  (ID: ${CHANNEL_ID})"
  echo "  Master UID:     ${MASTER_UID}"
  echo "  Master email:   ${USER_EMAIL}"
  echo
  echo "  Key URL:        ${KEY_URL}"
  echo "  Creds URL:      ${CREDS_URL}"
  echo "  Installer URL:  ${INSTALLER_URL}"
  echo
  echo "  Local files:"
  echo "    ${CFG_OUT}"
  echo "    ${CREDS_OUT}"
  echo "    ${INSTALLER_OUT}"
  echo

  c_bold "  ─────────────────────────────────────────────────────────────────────"
  c_bold "  To install on any server:"
  echo
  echo "    sudo wget -O /tmp/install.sh '${INSTALLER_URL}'"
  echo "    sudo chmod +x /tmp/install.sh"
  echo "    sudo /tmp/install.sh"
  echo
  c_bold "  To install as leader-capable:"
  echo
  echo "    COORDINATOR_LEADER=1 sudo /tmp/install.sh"
  echo
  c_bold "  ─────────────────────────────────────────────────────────────────────"
  echo

  printf "  Install on this machine now? [y/N]: "
  read -r INSTALL_NOW

  if [[ "$INSTALL_NOW" =~ ^[Yy]$ ]]; then
    echo
    c_bold "  Running installer on this machine..."
    echo
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      bash "$INSTALLER_OUT"
    else
      sudo bash "$INSTALLER_OUT"
    fi
  else
    echo
    echo "  Skipping local install."
    echo "  Use the install command above to deploy on your servers."
  fi
}

# ════════════════════════════════════════════════════════════════════
# Main
# ════════════════════════════════════════════════════════════════════

main() {
  c_bold "══════════════════════════════════════════════════════════════════════"
  c_bold "       Claude Coordinator Network — New Network Bootstrap            "
  c_bold "══════════════════════════════════════════════════════════════════════"
  echo
  echo "  Bootstraps a brand-new coordinator network from scratch."
  echo "  You will need:"
  echo "    • A Slack workspace (free tier works)"
  echo "    • Access to a hosting location for 3 small files"
  echo "    • ~10 minutes"
  echo

  # Declare all globals upfront so phase functions can reference them
  USER_EMAIL=""
  NET_LABEL=""
  CHANNEL_NAME=""
  INSTALLER_FILENAME=""
  CFG_OUT=""
  CREDS_OUT=""
  INSTALLER_OUT=""
  HOST_TYPE=""
  HOST_CHOICE=""
  BASE_URL=""
  KEY_URL=""
  CREDS_URL=""
  INSTALLER_URL=""
  TRUST_DOMAIN=""
  SCP_DEST=""
  GH_USER=""
  GH_REPO=""
  GCP_BUCKET=""
  SLACK_BOT_TOKEN=""
  SLACK_USER_TOKEN=""
  MASTER_UID=""
  CHANNEL_ID=""
  MASTER_KEY=""
  COORDINATOR_HMAC_KEY=""
  COORDINATOR_LEADER_TOKEN=""

  phase1_preflight
  phase2_slack
  phase3_keys
  phase4_compile
  phase5_hosting
  phase6_summary
}

main "$@"
