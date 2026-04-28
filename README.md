# autobox-provision

Idempotent bash provisioner for the autonomous MeshOMatic bot's "autobox" VM.

## Usage

```
ssh root@<autobox-ip>
git clone https://github.com/akkerkid/autobox-provision.git
cd autobox-provision
./provision-autobox.sh
```

The script prompts for secrets the first time it runs and never commits them. Re-running is safe — it detects already-present pieces and skips.

## What it builds

- Debian 13 host with `bot` user, ufw outbound allowlist, chrony.
- Pinned Claude Code CLI (logged in interactively to AkkerKid's Anthropic account — shared Max plan).
- GPG signing key for `MeshOMatic`, configured for git (printed for upload to GitHub).
- Cloned `MeshOMatic/meshcore-planner` fork + read-only `akkerkid/bot-rules`.
- Initial `/data/` mirror from prod via SSH-keyed rsync (forced-command on prod's `bot-readonly` user).
- systemd-managed Ralph loop (`ralph.service`).
- Localhost-only health endpoint (`127.0.0.1:9090`).

## What it does NOT build

- Discord receiver service (Plan 3).
- Reviewer-agent on prod (Plan 4).
