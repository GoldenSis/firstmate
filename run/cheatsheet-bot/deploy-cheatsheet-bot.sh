#!/usr/bin/env bash
# deploy-cheatsheet-bot.sh — install/update the personal Telegram cheat-sheet bot
# on the always-on VPS as a systemd service. Mirrors the cloud-bots pattern
# (Lou/brain bots): isolated venv, 0600 env file, Restart=always, enabled on
# boot, anti-crash-loop rollback. Adds a NEW service; never touches other bots.
#
# Run from the MacBook (creds only live in your shell + the VPS env file):
#   TELEGRAM_BOT_TOKEN=xxxx OWNER_ID=nnnn bash deploy-cheatsheet-bot.sh
# Re-deploy after a content/code change (creds already saved on the VPS):
#   bash deploy-cheatsheet-bot.sh
set -euo pipefail

VPS_HOST="${VPS_HOST:-root@164.92.207.154}"
SRC="${SRC:-/Users/arnaudchretien/firstmate/projects/cheatsheet-bot}"
NAME=cheatsheet
REMOTE_DIR=/opt/bots/$NAME

[ -f "$SRC/bot.py" ] || { echo "source not found at $SRC"; exit 1; }
echo "== Cheat-sheet bot deploy -> $VPS_HOST =="

# --- 1. ship only the runtime files (never .env / .venv / .run) ---
# REMOTE_DIR is a fixed local constant; client-side expansion is intended.
# shellcheck disable=SC2029
tar -C "$SRC" -czf - bot.py cheatsheet.py triage.py panic_command.py requirements.txt content \
  | ssh "$VPS_HOST" "mkdir -p $REMOTE_DIR && tar -C $REMOTE_DIR -xzf -"

# --- 1b. ship the /panic kill-switch executor (from the vault, not the bot dir) ---
scp -q "$HOME/BrainShared/tools/panic.sh" "$VPS_HOST:/opt/bots/panic.sh"
ssh "$VPS_HOST" "chmod +x /opt/bots/panic.sh"

# --- 2. remote setup: venv, env file, systemd unit, verify it stays up ---
# Creds must expand client-side to be passed into the remote shell. Intended.
# shellcheck disable=SC2029
ssh "$VPS_HOST" "TELEGRAM_BOT_TOKEN='${TELEGRAM_BOT_TOKEN:-}' OWNER_ID='${OWNER_ID:-}' HF_TOKEN='${HF_TOKEN:-}' bash -s" <<'REMOTE'
set -euo pipefail
NAME=cheatsheet
BOTS=/opt/bots
DIR=$BOTS/$NAME
ENVF=$BOTS/$NAME.env
VENV=$BOTS/$NAME-venv
UNIT=/etc/systemd/system/$NAME-bot.service

get() { [ -f "$ENVF" ] && grep -E "^$1=" "$ENVF" | cut -d= -f2- || true; }
TOKEN="${TELEGRAM_BOT_TOKEN:-$(get TELEGRAM_BOT_TOKEN)}"
OWNER="${OWNER_ID:-$(get OWNER_ID)}"
HF="${HF_TOKEN:-$(get HF_TOKEN)}"   # optional — enables /triage; preserved across re-deploys
[ -n "$TOKEN" ] || { echo "need TELEGRAM_BOT_TOKEN (pass it on first run)"; exit 1; }

[ -d "$VENV" ] || python3 -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip >/dev/null
"$VENV/bin/pip" install -q -r "$DIR/requirements.txt" >/dev/null
"$VENV/bin/python" -c "import ast; ast.parse(open('$DIR/bot.py').read()); ast.parse(open('$DIR/triage.py').read()); ast.parse(open('$DIR/panic_command.py').read())"

umask 077
# /panic kill switch — VPS-only, LOCAL systemctl, UNARMED (no PANIC_ARM = dry-run).
# Arming is a deliberate later step: add PANIC_ARM=1 here after a live rehearsal.
{ echo "TELEGRAM_BOT_TOKEN=$TOKEN"; echo "OWNER_ID=$OWNER"; [ -n "$HF" ] && echo "HF_TOKEN=$HF"; \
  echo "PANIC_SCRIPT=/opt/bots/panic.sh"; echo "PANIC_SCOPE=vps"; echo "PANIC_VPS_LOCAL=1"; } > "$ENVF"

cat > "$UNIT" <<UNITEOF
[Unit]
Description=Cheat-sheet bot - Arnaud's personal command/shortcut reference
After=network-online.target
StartLimitIntervalSec=120
StartLimitBurst=4

[Service]
WorkingDirectory=$DIR
EnvironmentFile=$ENVF
ExecStart=$VENV/bin/python $DIR/bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable $NAME-bot >/dev/null 2>&1 || true
systemctl restart $NAME-bot

sleep 6
if ! systemctl is-active --quiet $NAME-bot; then
  echo "FAILED: $NAME-bot did not stay up:"; journalctl -u $NAME-bot -n 25 --no-pager || true
  systemctl stop $NAME-bot || true
  exit 1
fi
echo "OK: $NAME-bot is live and will auto-start on boot. Logs: journalctl -u $NAME-bot -f"
REMOTE
echo "== done =="
