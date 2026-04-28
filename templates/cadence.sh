#!/usr/bin/env bash
# /opt/ralph/cadence.sh — emit sleep duration based on inbox-hash stability.
# Outputs RALPH_MIN_CADENCE_SEC normally; bumps to RALPH_MAX_CADENCE_SEC
# after 3 consecutive iterations with an unchanged inbox hash.

set -uo pipefail

# shellcheck disable=SC1091
source /etc/ralph/env

state_file="/var/lib/ralph/cadence.state"
mkdir -p "$(dirname "$state_file")"

# Build the inbox-relevance signal.  Five cheap reads.
sig=""
sig+="$(gh issue list --repo akkerkid/meshcore-planner --label bot-eligible \
        --state open --json number,updatedAt 2>/dev/null | jq -c . || echo '[]')"
sig+="$(gh pr list --repo akkerkid/meshcore-planner --author MeshOMatic \
        --state open --json number,updatedAt,comments 2>/dev/null | jq -c . || echo '[]')"
sig+="$(git -C /home/bot/work/meshcore-planner ls-remote upstream main 2>/dev/null | awk '{print $1}')"
sig+="$(git -C /home/bot/work/bot-rules ls-remote origin main 2>/dev/null | awk '{print $1}')"
sig+="$(curl -fsS -m 10 -H "X-API-Key: $MESHOMATIC_API_KEY" \
        https://map.meshomatic.net/api/docs/how-it-works/annotation-summary 2>/dev/null || echo '{}')"

current=$(echo -n "$sig" | sha256sum | awk '{print $1}')

prev_hash=""
stable=0
[[ -f "$state_file" ]] && read -r prev_hash stable < "$state_file"

if [[ "$current" == "$prev_hash" ]]; then
  stable=$((stable + 1))
else
  stable=0
fi

# 60 min normally; 4 h after 3 stable iters.
if (( stable >= 3 )); then
  echo "${RALPH_MAX_CADENCE_SEC:-14400}"
else
  echo "${RALPH_MIN_CADENCE_SEC:-3600}"
fi

echo "$current $stable" > "$state_file"
