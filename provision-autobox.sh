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
    ufw chrony gnupg2 build-essential \
    python3-venv python3-pip nodejs npm tmux htop ca-certificates \
    >/dev/null
# NOTE: iptables-persistent omitted — Debian 13 ufw conflicts with it
# and ufw handles rule persistence on its own.

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

# ---------------------------------------------------------------------------
# Phase 5: pinned Claude Code
# ---------------------------------------------------------------------------
log "[5/N] Installing Claude Code (pinned to ${CLAUDE_CODE_VERSION})..."

if command -v claude >/dev/null 2>&1 && \
   claude --version 2>/dev/null | grep -q "${CLAUDE_CODE_VERSION}"; then
  log "Claude Code ${CLAUDE_CODE_VERSION} already installed."
else
  npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" >/dev/null 2>&1 \
    || die "npm install of Claude Code failed"
  claude --version
fi

# Note: `claude /login` is interactive and CANNOT be scripted.
# After this script exits, run as bot:
#   sudo -u bot -i claude /login
# Then continue with the next provision pass (which checks login).
if ! sudo -u bot test -f /home/bot/.claude/.credentials.json; then
  warn "Claude Code is installed but bot has not logged in yet."
  warn "Next step (interactive, manual): sudo -u bot -i  →  then run 'claude /login'"
  warn "Re-run this script after login to continue past this gate."
fi

# ---------------------------------------------------------------------------
# Phase 6: GPG signing key for MeshOMatic
# ---------------------------------------------------------------------------
log "[6/N] Setting up MeshOMatic GPG key..."

if ! sudo -u bot gpg --list-secret-keys --keyid-format=long 2>/dev/null \
       | grep -q "MeshOMatic"; then
  log "Generating new GPG key (Ed25519)..."
  sudo -u bot gpg --batch --gen-key <<'EOF'
%no-protection
Key-Type: EDDSA
Key-Curve: ed25519
Key-Usage: sign
Subkey-Type: ECDH
Subkey-Curve: cv25519
Subkey-Usage: encrypt
Name-Real: MeshOMatic
Name-Email: darius954+meshomatic@gmail.com
Expire-Date: 2y
%commit
EOF
  log "GPG key generated."
else
  log "MeshOMatic GPG key already exists."
fi

# Configure git to sign as MeshOMatic
GPG_KEY_ID=$(sudo -u bot gpg --list-secret-keys --keyid-format=long 2>/dev/null \
              | awk '/^sec/ { split($2, a, "/"); print a[2]; exit }')
if [[ -z "$GPG_KEY_ID" ]]; then
  die "GPG key ID extraction failed"
fi

sudo -u bot git config --global user.name "MeshOMatic"
sudo -u bot git config --global user.email "darius954+meshomatic@gmail.com"
sudo -u bot git config --global user.signingkey "$GPG_KEY_ID"
sudo -u bot git config --global commit.gpgsign true
sudo -u bot git config --global tag.gpgsign true
log "git configured to sign as MeshOMatic (key ${GPG_KEY_ID})"

# Surface public key for AkkerKid to upload to GitHub MeshOMatic account.
# Gate progression on a marker file. Non-blocking: the provisioner continues
# past this gate; bot's commits will fail bot-discipline CI until uploaded.
mkdir -p /etc/ralph
GPG_UPLOADED_MARKER="/etc/ralph/.gpg-uploaded-to-github"
GPG_PUBKEY_FILE="/etc/ralph/meshomatic.gpg.pub"

sudo -u bot gpg --armor --export "$GPG_KEY_ID" > "$GPG_PUBKEY_FILE"
chmod 644 "$GPG_PUBKEY_FILE"

if [[ ! -f "$GPG_UPLOADED_MARKER" ]]; then
  warn "GPG public key written to $GPG_PUBKEY_FILE."
  warn "MANUAL STEP: paste contents into https://github.com/settings/gpg/new"
  warn "             (while logged in as MeshOMatic on github.com)."
  warn "Then mark uploaded:  sudo touch $GPG_UPLOADED_MARKER"
  warn "Continuing — but bot's signed commits will fail CI until done."
fi

# ---------------------------------------------------------------------------
# Phase 7: GitHub fork verification + clones
# ---------------------------------------------------------------------------
log "[7/N] Verifying GitHub fork + cloning repos..."

# Use GH_TOKEN if it's already populated in env (the bot's PAT) so we can
# see private forks. Falls back to unauth (works only if the fork is public).
GH_TOKEN_VAL=$(grep "^GH_TOKEN=" /etc/ralph/env 2>/dev/null | cut -d= -f2-)
fork_check_args=()
if [[ -n "$GH_TOKEN_VAL" && "$GH_TOKEN_VAL" != *REPLACE* ]]; then
  fork_check_args=(-H "Authorization: Bearer $GH_TOKEN_VAL")
fi

if ! curl -fsS "${fork_check_args[@]}" -o /dev/null \
       "https://api.github.com/repos/MeshOMatic/meshcore-planner"; then
  warn "MeshOMatic/meshcore-planner fork not found (or token can't see it)."
  warn "Log in as MeshOMatic on github.com, fork akkerkid/meshcore-planner, then re-run."
  warn "(Skipping clones for now — re-run once fork exists.)"
else
  # Configure a credential helper for the bot user so HTTPS clones to
  # private repos work without interactive prompt.
  sudo -u bot bash -c "
    git config --global credential.helper '!f() { test \"\$1\" = get && echo \"username=meshomatic\" && echo \"password=$GH_TOKEN_VAL\"; }; f'
  "

  sudo -u bot bash -c '
    set -e
    mkdir -p ~/work
    cd ~/work
    if [[ ! -d bot-rules ]]; then
      git clone -q https://github.com/akkerkid/bot-rules.git
      echo "Cloned bot-rules"
    fi
    if [[ ! -d meshcore-planner ]]; then
      git clone -q https://github.com/MeshOMatic/meshcore-planner.git
      cd meshcore-planner
      git remote add upstream https://github.com/akkerkid/meshcore-planner.git
      git fetch -q upstream
      git checkout -q main
      git reset -q --hard upstream/main
      echo "Cloned MeshOMatic/meshcore-planner with upstream pointing at akkerkid/meshcore-planner"
    fi
  '
  log "Clones in /home/bot/work/:"
  ls /home/bot/work/ | sed 's/^/  /'
fi

# ---------------------------------------------------------------------------
# Phase 8: secrets layout
# ---------------------------------------------------------------------------
log "[8/N] Setting up /etc/ralph/{,secrets/} layout..."

mkdir -p /etc/ralph/secrets /var/log/ralph /var/lib/ralph /opt/ralph/bin
chown -R root:bot /etc/ralph
chmod 750 /etc/ralph
chmod 700 /etc/ralph/secrets
chown -R bot:bot /var/log/ralph /var/lib/ralph

# Install env template if not present.
if [[ ! -f /etc/ralph/env ]]; then
  if [[ -f "$REPO_DIR/templates/secrets.env.example" ]]; then
    cp "$REPO_DIR/templates/secrets.env.example" /etc/ralph/env
  else
    # Inline minimal template if running detached from the repo
    cat > /etc/ralph/env <<'TEMPLATE'
# /etc/ralph/env — secrets and tunables.
# Mode 640, owner root:bot. NEVER commit populated values.

# GitHub: fine-grained PAT for MeshOMatic (per spec §2 "bot-write" PAT)
GH_TOKEN=ghp_REPLACE

# Prod webapp read-only X-API-Key (from Plan 1 Task 3)
MESHOMATIC_API_KEY=mesh_REPLACE

# MQTT live-tap
MESHOMATIC_MQTT_HOST=172.30.30.137
MESHOMATIC_MQTT_PORT=31883
MESHOMATIC_MQTT_USER=user_MeshOMatic
MESHOMATIC_MQTT_PASSWORD=REPLACE

# Discord (placeholder until Plan 3)
DISCORD_BOT_TOKEN=PLACEHOLDER_FILL_IN_PLAN_3
DISCORD_CHANNEL_ID=PLACEHOLDER_FILL_IN_PLAN_3

# Tuning
RALPH_MIN_CADENCE_SEC=3600
RALPH_MAX_CADENCE_SEC=14400
RALPH_PINNED_CLAUDE_VERSION=2.1.0

# rsync key for prod /data/ mirror
BOT_RSYNC_KEY=/home/bot/.ssh/autobox-rsync-key
TEMPLATE
  fi
  chown root:bot /etc/ralph/env
  chmod 640 /etc/ralph/env
  warn "Created /etc/ralph/env from template. Edit it with real secrets:"
  warn "  sudo nano /etc/ralph/env"
  warn "Required keys: GH_TOKEN, MESHOMATIC_API_KEY, MESHOMATIC_MQTT_PASSWORD"
  warn "Re-run this script after populating."
  exit 99
fi

# Verify required keys are populated
required_keys=(GH_TOKEN MESHOMATIC_API_KEY MESHOMATIC_MQTT_PASSWORD)
missing=()
for key in "${required_keys[@]}"; do
  val=$(grep "^${key}=" /etc/ralph/env | cut -d= -f2-)
  if [[ -z "$val" || "$val" == *"REPLACE"* || "$val" == *"PLACEHOLDER"* ]]; then
    missing+=("$key")
  fi
done

if (( ${#missing[@]} > 0 )); then
  warn "/etc/ralph/env missing values: ${missing[*]}"
  warn "Continuing past — but bot can't reach GitHub until populated."
else
  log "Required secrets populated."

  # Configure gh CLI for bot user
  sudo -u bot bash -c '
    if ! gh auth status 2>&1 | grep -q "Logged in to github.com as MeshOMatic"; then
      GH_TOKEN=$(grep "^GH_TOKEN=" /etc/ralph/env | cut -d= -f2-)
      echo "$GH_TOKEN" | gh auth login --with-token 2>/dev/null
    fi
    gh auth status 2>&1 | head -5
  '
fi

# ---------------------------------------------------------------------------
# Phase 9: Initial /data/ mirror + ongoing rsync timer
# ---------------------------------------------------------------------------
log "[9/N] Setting up /data/ mirror..."

mkdir -p /data
chown bot:bot /data

if [[ ! -d /data/processed ]]; then
  warn "/data/ is empty. Initial mirror is ~40 GB and slow."
  warn "Run interactively in tmux on first setup:"
  warn "  sudo -u bot tmux new -s data-mirror"
  warn "  rsync -av --info=progress2 -e \"ssh -i \$BOT_RSYNC_KEY\" bot-readonly@172.30.30.137:/processed/ /data/processed/"
  warn "  (and /raw/mqtt/, /db/)"
  warn "  Detach with Ctrl-b d when done."
  warn "Skipping ongoing-mirror timer install until initial mirror exists."
else
  # Ongoing rsync via systemd timer (runs 4× daily).
  # Prod-side /data layout (verified 2026-04-28):
  #   /data/processed/   ~14G  backend JSONs (always mirror)
  #   /data/db/          ~smt  sanitized SQL dump (Plan 1 cron writes nightly)
  #   /data/tiles_uts/   ~15G  UTS tiles (only when bot does tile work — defer)
  # Historical MQTT archive intentionally NOT mirrored — bot reads live MQTT
  # via subscribe ACL on the broker (Plan 1 Task 5) instead.
  cat > /etc/systemd/system/bot-data-rsync.service <<'EOF'
[Unit]
Description=Mirror /data/ from prod (bot-readonly@.137)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=bot
Group=bot
EnvironmentFile=/etc/ralph/env
ExecStart=/bin/bash -c '\
  rsync -a --delete -e "ssh -i $BOT_RSYNC_KEY -o StrictHostKeyChecking=accept-new" \
    bot-readonly@172.30.30.137:/processed/ /data/processed/ ; \
  rsync -a --delete -e "ssh -i $BOT_RSYNC_KEY" \
    bot-readonly@172.30.30.137:/db/ /data/db/ ; \
  echo $(date -Iseconds) ok'
EOF

  cat > /etc/systemd/system/bot-data-rsync.timer <<'EOF'
[Unit]
Description=Periodic /data/ mirror (4× daily)

[Timer]
OnCalendar=*-*-* 03:30:00
OnCalendar=*-*-* 09:30:00
OnCalendar=*-*-* 15:30:00
OnCalendar=*-*-* 21:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now bot-data-rsync.timer >/dev/null 2>&1
  log "rsync timer enabled — next runs:"
  systemctl list-timers bot-data-rsync.timer --no-pager 2>&1 | head -3
fi

# ---------------------------------------------------------------------------
# Phase 10: bootstrap.md, cadence.sh, loop.sh, helpers
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Phase 9b: Python venv + pytest for the bot (so it can verify its own work)
# ---------------------------------------------------------------------------
log "[9b/N] Installing python build deps + venv with pytest..."

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    libpq-dev libgdal-dev libproj-dev gdal-bin python3-dev \
    >/dev/null

if [[ -d /home/bot/work/meshcore-planner ]]; then
  if [[ ! -d /home/bot/work/meshcore-planner/.venv ]]; then
    sudo -u bot bash -c '
      cd /home/bot/work/meshcore-planner
      python3 -m venv .venv
      .venv/bin/pip install -q --upgrade pip pytest
    '
    log "venv created with pytest at /home/bot/work/meshcore-planner/.venv"
  else
    log "venv already exists at /home/bot/work/meshcore-planner/.venv"
  fi
else
  warn "meshcore-planner not yet cloned; skipping venv setup"
fi

# ---------------------------------------------------------------------------
# Phase 10: bootstrap.md, cadence.sh, loop.sh, helpers
# ---------------------------------------------------------------------------
log "[10/N] Installing bootstrap + runtime scripts..."

install -o root -g bot -m 640 "$REPO_DIR/templates/bootstrap.md"     /etc/ralph/bootstrap.md
install -o root -g bot -m 750 "$REPO_DIR/templates/cadence.sh"       /opt/ralph/cadence.sh
install -o root -g bot -m 750 "$REPO_DIR/templates/loop.sh"          /opt/ralph/loop.sh
install -o root -g bot -m 750 "$REPO_DIR/templates/say-on-discord.sh" /opt/ralph/bin/say-on-discord
ln -sf /opt/ralph/bin/say-on-discord /usr/local/bin/say-on-discord
install -o root -g bot -m 750 "$REPO_DIR/templates/healthz.py"       /opt/ralph/bin/healthz.py

# ---------------------------------------------------------------------------
# Phase 11: systemd units (NOT enabled — operator runs smoke first)
# ---------------------------------------------------------------------------
log "[11/N] Installing systemd units..."

install -o root -g root -m 644 "$REPO_DIR/templates/ralph.service"   /etc/systemd/system/ralph.service
install -o root -g root -m 644 "$REPO_DIR/templates/healthz.service" /etc/systemd/system/healthz.service

# Logrotate
cat > /etc/logrotate.d/ralph <<'EOF'
/var/log/ralph/stdout.log /var/log/ralph/stderr.log /var/log/ralph/discord-pending.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    copytruncate
}
EOF

systemctl daemon-reload
systemctl enable --now healthz.service >/dev/null 2>&1
log "healthz.service running on 127.0.0.1:9090"

if ! systemctl is-active ralph >/dev/null 2>&1; then
  warn "ralph.service installed but NOT enabled."
  warn "Run smoke test first:"
  warn "  sudo /opt/ralph/loop.sh   # Ctrl-C after one iter"
  warn "Then:  sudo systemctl enable --now ralph"
fi

log "==============================================================="
log "Provisioning complete (gate-respecting). Manual steps remaining:"
[[ ! -f /etc/ralph/.gpg-uploaded-to-github ]] \
  && log "  • Upload /etc/ralph/meshomatic.gpg.pub to MeshOMatic GitHub" \
  && log "    Then: sudo touch /etc/ralph/.gpg-uploaded-to-github"
[[ ! -d /home/bot/work/meshcore-planner ]] \
  && log "  • Fork akkerkid/meshcore-planner to MeshOMatic on GitHub, then re-run"
grep -q "^GH_TOKEN=ghp_REPLACE" /etc/ralph/env 2>/dev/null \
  && log "  • Generate MeshOMatic GitHub PAT and put it into /etc/ralph/env GH_TOKEN"
[[ ! -d /data/processed ]] \
  && log "  • Run initial /data/ rsync (see Phase 9 instructions above)"
log "==============================================================="
