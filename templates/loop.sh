#!/usr/bin/env bash
# /opt/ralph/loop.sh — the Ralph loop. Fresh claude session per iteration.
# NOT set -e: keep looping even if an iter fails.

set -uo pipefail

# shellcheck disable=SC1091
source /etc/ralph/env

LOG_DIR=/var/log/ralph
STDERR_TAIL="$LOG_DIR/stderr.log.tail"
mkdir -p "$LOG_DIR"

# Verify Claude Code version pin matches.
expected="${RALPH_PINNED_CLAUDE_VERSION:-2.1.0}"
actual=$(sudo -u bot claude --version 2>/dev/null | awk '{print $1}')
if [[ "$actual" != "$expected" ]]; then
  /opt/ralph/bin/say-on-discord "[bot] Claude Code version drift: expected ${expected}, got ${actual}. Refusing to start. Re-run provisioner with new pin."
  exit 1
fi

while true; do

  # Manual pause file — touch /var/run/ralph-pause to halt.
  while [[ -f /var/run/ralph-pause ]]; do
    echo "[ralph $(date -Iseconds)] paused (touch file present), sleeping 1h"
    sleep 3600
  done

  iter_start=$(date +%s)
  echo "[ralph $(date -Iseconds)] iter start"

  # Pull latest rules from upstream — bot is read-only on this repo.
  git -C /home/bot/work/bot-rules pull --ff-only origin main 2>&1 | tail -3 || true

  # Truncate stderr-tail before each iter so detection is per-iter.
  : > "$STDERR_TAIL"

  # Capture full claude output for spend logging (Plan 5).
  claude_out=$(mktemp /tmp/claude-iter.XXXXXX.log)
  trap 'rm -f "$claude_out"' EXIT

  # Fresh session, 90 min cap, dangerous-skip-perms (allowlisted network is the safety).
  timeout 5400 sudo -u bot \
    bash -c "
      cd /home/bot/work/meshcore-planner
      claude --print --dangerously-skip-permissions \
             --append-system-prompt \"\$(cat /etc/ralph/bootstrap.md)\"
    " > "$claude_out" 2> >(tee -a "$STDERR_TAIL" >&2)
  exit_code=$?

  cat "$claude_out"
  echo "[ralph $(date -Iseconds)] iter exit code=$exit_code"

  # Record last-iter timestamp for healthz.
  date +%s > /var/lib/ralph/last-iter.timestamp

  # Spend logger (Plan 5 wires the script; until then, just record empty)
  if [[ -x /opt/ralph/bin/spend-logger.sh ]]; then
    /opt/ralph/bin/spend-logger.sh "$claude_out" || true
  fi

  rm -f "$claude_out"
  trap - EXIT

  # Throttle-aware backoff.
  if grep -qiE "(429|rate.limit|overloaded|throttle)" "$STDERR_TAIL"; then
    /opt/ralph/bin/say-on-discord "[bot] hit rate limit, pausing 2h. AkkerKid in flight?" || true
    echo "[ralph $(date -Iseconds)] rate-limit detected, sleeping 2h"
    sleep 7200
    continue
  fi

  # Adaptive cadence
  sleep_s=$(sudo -u bot /opt/ralph/cadence.sh 2>/dev/null || echo "${RALPH_MIN_CADENCE_SEC:-3600}")
  echo "[ralph $(date -Iseconds)] sleeping ${sleep_s}s"
  sleep "$sleep_s"
done
