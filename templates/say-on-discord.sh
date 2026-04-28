#!/usr/bin/env bash
# /opt/ralph/bin/say-on-discord — placeholder for Plan 3.
# Until Plan 3 wires the real Discord client, this just logs to disk.

set -uo pipefail

mkdir -p /var/log/ralph
ts=$(date -Iseconds)
echo "[$ts] $*" >> /var/log/ralph/discord-pending.log
echo "(would post to Discord): $*"
