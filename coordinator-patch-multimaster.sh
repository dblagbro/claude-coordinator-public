#!/bin/bash
# Coordinator patch: enable multiple master UIDs
set -e

ENV_FILE="/root/.claude/coordinator.env"
DAEMON="/usr/local/bin/coordinator-daemon"
NEW_IDS="U0AH67SQ63C:U0AHK5EQGC9"

echo "=== coordinator multi-master patch ==="

# 1. Update coordinator.env
if [[ -f "$ENV_FILE" ]]; then
    sed -i "s/^COORDINATOR_MASTER_USER_ID=.*/COORDINATOR_MASTER_USER_ID=${NEW_IDS}/" "$ENV_FILE"
    echo "coordinator.env: updated"
else
    echo "ERROR: $ENV_FILE not found"; exit 1
fi

# 2. Patch daemon — swap single-UID == check for multi-UID list check
python3 - <<'PYEOF'
import sys
f = '/usr/local/bin/coordinator-daemon'
t = open(f).read()

changes = 0

# Pattern A: main loop master check
old_a = 'if [[ -n "$USER_ID" && "$USER_ID" == "$COORDINATOR_MASTER_USER_ID" ]]; then'
new_a = "if [[ -n \"$USER_ID\" ]] && echo \"$COORDINATOR_MASTER_USER_ID\" | tr ':' '\\n' | grep -qxF \"$USER_ID\"; then"
if old_a in t:
    t = t.replace(old_a, new_a)
    changes += 1

# Pattern B: cc-wrapper master check (same text, different context — replace all)
# (already covered by replace above since text is identical)

# Pattern C: watchdog recovery check
old_c = "[[ \"$USER_ID\" != \"$COORDINATOR_MASTER_USER_ID\" ]] && continue"
new_c = "echo \"$COORDINATOR_MASTER_USER_ID\" | tr ':' '\\n' | grep -qxF \"$USER_ID\" || continue"
if old_c in t:
    t = t.replace(old_c, new_c)
    changes += 1

if changes == 0 and "tr ':'" in t:
    print('coordinator-daemon: already patched')
elif changes > 0:
    open(f, 'w').write(t)
    print(f'coordinator-daemon: patched ({changes} locations)')
else:
    print('ERROR: patterns not found — check daemon version', file=sys.stderr)
    sys.exit(1)
PYEOF

# 3. Restart
systemctl restart claude-coordinator
echo "claude-coordinator: restarted"
echo "=== done ==="
