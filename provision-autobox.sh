#!/usr/bin/env bash
# provision-autobox.sh — turn a fresh Debian 13 host into the autobox.
#
# Idempotent. Run as root on the autobox.
#
# Stages:
#   1. apt deps
#   2. chrony (NTP)
#   3. bot user (must already exist with key + sudo NOPASSWD; we won't create it here)
#   4. ufw outbound allowlist
#   5. pinned Claude Code (interactive `claude /login` is a separate manual step)
#   6. GPG key for MeshOMatic (interactive paste-to-GitHub gate)
#   7. GitHub fork verification + clones (bot-rules, meshcore-planner)
#   8. secrets layout (/etc/ralph/env, /etc/ralph/secrets/)
#   9. initial /data/ mirror from prod
#  10. bootstrap.md + cadence.sh + loop.sh + healthz
#  11. systemd unit (installed but NOT enabled — operator runs the smoke first)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Must be run as root." >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-2.1.0}"

log() { printf "==> [%s] %s\n" "$(date +%H:%M:%S)" "$*"; }
warn() { printf "!!  %s\n" "$*" >&2; }
die() { printf "FATAL: %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Phase 1: system packages
# ---------------------------------------------------------------------------
log "[1/N] Installing system packages..."

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    git curl jq mosquitto-clients postgresql-client rsync \
    iptables-persistent ufw chrony gnupg2 build-essential \
    python3-venv python3-pip nodejs npm tmux htop ca-certificates \
    >/dev/null

log "Installing gh CLI..."
if ! command -v gh >/dev/null 2>&1; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg status=none
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq
  apt-get install -y -qq gh >/dev/null
fi

# ---------------------------------------------------------------------------
# Phase 2: time sync
# ---------------------------------------------------------------------------
log "[2/N] Enabling chrony..."
systemctl enable --now chrony >/dev/null 2>&1
sleep 1
chronyc tracking 2>/dev/null | head -3 || warn "chronyc tracking failed (chrony still warming up)"

# ---------------------------------------------------------------------------
# Phase 3: bot user sanity
# ---------------------------------------------------------------------------
log "[3/N] Verifying bot user..."
if ! id bot >/dev/null 2>&1; then
  die "User 'bot' not found. Create it manually with sudo + ssh key first, then re-run."
fi
if ! sudo -u bot -n true 2>/dev/null; then
  die "User 'bot' does not have NOPASSWD sudo. Fix /etc/sudoers.d/99-bot-nopasswd then re-run."
fi
log "bot user present with NOPASSWD sudo"

# ---------------------------------------------------------------------------
# Phase 4: ufw outbound allowlist
# ---------------------------------------------------------------------------
log "[4/N] Configuring ufw outbound allowlist..."

# Defaults
ufw default deny incoming >/dev/null 2>&1
ufw default deny outgoing >/dev/null 2>&1

# Inbound: SSH from LAN only
ufw allow in on lo >/dev/null 2>&1
ufw allow from 172.30.30.0/24 to any port 22 proto tcp comment 'AkkerKid SSH (LAN)' >/dev/null 2>&1

# Outbound: DNS, NTP, HTTP/HTTPS, MQTT to prod, SSH to prod
ufw allow out 53 comment 'DNS' >/dev/null 2>&1
ufw allow out 123 comment 'NTP' >/dev/null 2>&1
ufw allow out 80 comment 'HTTP (apt repos)' >/dev/null 2>&1
ufw allow out 443 comment 'HTTPS (GitHub, Anthropic, npm, pypi, prod webapp, Discord)' >/dev/null 2>&1
ufw allow out 22 comment 'SSH (rsync to prod bot-readonly)' >/dev/null 2>&1
ufw allow out to 172.30.30.137 port 1883 proto tcp comment 'mosquitto live tap' >/dev/null 2>&1
ufw allow out to 172.30.30.137 port 31883 proto tcp comment 'mosquitto TCP listener (broker)' >/dev/null 2>&1

# Discord gateway connection (used by Plan 3)
ufw allow out to any port 6697 comment 'Discord gateway TLS (occasional fallback)' >/dev/null 2>&1

ufw --force enable >/dev/null 2>&1
log "ufw status:"
ufw status verbose | head -20

log "Phase 1-4 complete. Continue to Phase 5+ (Claude Code, GPG, fork, etc.)."
