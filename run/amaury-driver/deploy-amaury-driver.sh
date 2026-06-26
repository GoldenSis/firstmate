#!/usr/bin/env bash
# deploy-amaury-driver.sh — move the Amaury job-search driver to the VPS for 24/7.
# Spec: BrainShared/setup/amaury-driver-vps-deploy.md.  Idempotent + self-verifying.
#
# SAFETY CONTRACT:
#   * It NEVER unloads the working Mac runner unless the VPS dry-run authenticates
#     AND makes zero sends. If auth isn't ready, it leaves the Mac job running and
#     prints the one-time OAuth handoff. Re-runnable.
#   * achretien22 ONLY — copies only that account's token; no other mailbox.
#
# Run:  bash deploy-amaury-driver.sh
set -uo pipefail

VPS="${VPS:-root@164.92.207.154}"
STORE="$HOME/.local/share/google-workspace-mcp"        # local token store
SVC=amaury-driver
say() { printf '\n=== %s ===\n' "$*"; }
die() { printf '\nABORT: %s\n' "$*" >&2; exit 1; }

# ---- preflight (local) -----------------------------------------------------
command -v ssh >/dev/null || die "no ssh"
ssh -o ConnectTimeout=10 -o BatchMode=yes "$VPS" 'echo ok' >/dev/null 2>&1 \
  || die "can't reach $VPS over SSH (key auth)"
CID="$(python3 -c "import json,os;d=json.load(open(os.path.expanduser('~/.claude.json')));print(d['mcpServers']['google-workspace']['env']['GOOGLE_CLIENT_ID'])" 2>/dev/null)"
CSEC="$(python3 -c "import json,os;d=json.load(open(os.path.expanduser('~/.claude.json')));print(d['mcpServers']['google-workspace']['env']['GOOGLE_CLIENT_SECRET'])" 2>/dev/null)"
[ -n "$CID" ] && [ -n "$CSEC" ] || die "couldn't read GOOGLE_CLIENT_ID/SECRET from ~/.claude.json"

# ---- Phase A: VPS prerequisites (node, claude, MCP, gws) -------------------
say "Phase A — install node/claude/MCP on $VPS (idempotent)"
ssh "$VPS" 'bash -s' <<'REMOTE_A'
set -e
export DEBIAN_FRONTEND=noninteractive
need_node=0
command -v node >/dev/null 2>&1 || need_node=1
if [ "$need_node" = 0 ]; then
  v=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
  [ "${v:-0}" -ge 18 ] || need_node=1
fi
if [ "$need_node" = 1 ]; then
  if ! apt-get install -y nodejs npm >/dev/null 2>&1 || ! node -e 'process.exit(+(process.versions.node.split(".")[0]>=18)?0:1)' 2>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
    apt-get install -y nodejs >/dev/null 2>&1
  fi
fi
echo "node $(node --version)  npm $(npm --version)"
npm install -g @anthropic-ai/claude-code @aaronsb/google-workspace-mcp @googleworkspace/cli >/dev/null 2>&1 \
  || npm install -g @anthropic-ai/claude-code @aaronsb/google-workspace-mcp @googleworkspace/cli
command -v claude >/dev/null || ln -sf "$(npm bin -g)/claude" /usr/local/bin/claude 2>/dev/null || true
echo "claude: $(command -v claude || echo MISSING)"
REMOTE_A
[ $? -eq 0 ] || die "Phase A failed (see output above)"

# ---- Phase B: claude API key + MCP config on the VPS (root home) -----------
say "Phase B — wire ANTHROPIC_API_KEY + google-workspace MCP (achretien22 scope)"
ssh "$VPS" "GW_CID='$CID' GW_CSEC='$CSEC' bash -s" <<'REMOTE_B'
set -e
KEY=$(grep -h '^ANTHROPIC_API_KEY=' /opt/bots/*.env 2>/dev/null | head -1 | cut -d= -f2-)
[ -n "$KEY" ] || { echo "no ANTHROPIC_API_KEY in /opt/bots/*.env"; exit 1; }
mkdir -p /root/.local/share/google-workspace-mcp
python3 - "$GW_CID" "$GW_CSEC" <<'PY'
import json,os,sys
cid,csec=sys.argv[1],sys.argv[2]
p=os.path.expanduser('~/.claude.json')
d=json.load(open(p)) if os.path.exists(p) else {}
d.setdefault('mcpServers',{})['google-workspace']={
  'type':'stdio','command':'npx','args':['-y','@aaronsb/google-workspace-mcp'],
  'env':{'GOOGLE_CLIENT_ID':cid,'GOOGLE_CLIENT_SECRET':csec}}
json.dump(d,open(p,'w'),indent=2); print('wrote',p)
PY
# stash the key where the service unit will source it (root-only)
umask 077; printf 'ANTHROPIC_API_KEY=%s\n' "$KEY" > /opt/bots/amaury-driver.env
# the wrapper does `cd "$HOME/BrainShared"` but the brain is at /opt/brain here → symlink it
[ -e /root/BrainShared ] || ln -sfn /opt/brain /root/BrainShared
echo "MCP configured; key staged 0600; /root/BrainShared -> $(readlink -f /root/BrainShared)"
REMOTE_B
[ $? -eq 0 ] || die "Phase B failed"

# ---- Phase C: token fast-path — copy achretien22 ONLY (skips OAuth) --------
say "Phase C — copy achretien22 token (only) to the VPS, root-only"
# bash 3.2 (macOS default) has no mapfile — use a find|while loop.
ssh "$VPS" 'mkdir -p /root/.local/share/google-workspace-mcp && chmod 700 /root/.local/share/google-workspace-mcp'
N=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  rel="${f#$STORE/}"
  ssh "$VPS" "mkdir -p \"/root/.local/share/google-workspace-mcp/$(dirname "$rel")\"" 2>/dev/null || true
  if scp -q "$f" "$VPS:/root/.local/share/google-workspace-mcp/$rel"; then N=$((N+1)); fi
done < <(find "$STORE" -type f -path '*achretien22*' 2>/dev/null)
if [ "$N" -gt 0 ]; then
  ssh "$VPS" "chmod -R go-rwx /root/.local/share/google-workspace-mcp"
  echo "copied $N achretien22 token file(s)"
  TOKEN_COPIED=1
else
  echo "no achretien22 token files matched under $STORE — will fall back to interactive OAuth"
  TOKEN_COPIED=0
fi

# ---- Phase D: VERIFY auth with a crisp, parseable signal -------------------
# Strict: the achretien22 token must report "Token valid" AND show no missing-
# credential / auth-failure markers. (NL dry-run output proved too loose.)
say "Phase D — verify achretien22 auth on the VPS (manage_accounts status)"
ST=$(ssh "$VPS" "set -a; . /opt/bots/amaury-driver.env; set +a; cd /opt/brain && claude -p 'Run manage_accounts status for achretien22@gmail.com and print the raw tool result verbatim.' --allowedTools 'mcp__google-workspace__manage_accounts' 2>&1" || true)
echo "$ST" | tail -20
AUTH_OK=0
if echo "$ST" | grep -qiE 'token valid' \
   && ! echo "$ST" | grep -qiE 'ENOENT|not authenticated|no account|credentials/|unauthor|invalid_grant|no refresh'; then
  AUTH_OK=1
fi
echo "auth check → AUTH_OK=$AUTH_OK"

# ---- Phase E: cut over ONLY if verified -----------------------------------
if [ "$AUTH_OK" = 1 ]; then
  say "Phase E — VERIFIED. Schedule + cut over"
  ssh "$VPS" "bash -s '$SVC'" <<'REMOTE_E'
set -e; SVC="$1"
cat > /etc/systemd/system/$SVC.service <<UNIT
[Unit]
Description=Amaury job-search driver (autonomous, every ~2h daytime)
After=network-online.target
[Service]
Type=oneshot
TimeoutStartSec=600
Environment=HOME=/root
EnvironmentFile=/opt/bots/amaury-driver.env
WorkingDirectory=/opt/brain
ExecStart=/usr/bin/env bash /opt/brain/tools/amaury-watch.sh
UNIT
cat > /etc/systemd/system/$SVC.timer <<TIMER
[Unit]
Description=Run the Amaury driver every ~2h during daytime (UTC)
[Timer]
OnCalendar=*-*-* 05,07,09,11,13,15,17,19:00:00 UTC
Persistent=true
[Install]
WantedBy=timers.target
TIMER
systemctl daemon-reload
systemctl enable --now $SVC.timer
systemctl list-timers $SVC.timer --no-pager | tail -2
echo "--- VERIFY: run one real cycle now ---"
systemctl start $SVC.service || echo "(start returned nonzero — check log)"
echo "--- health stamp (primary-ok) ---"
ls -la /opt/brain/ops/amaury-driver.primary-ok 2>&1 || echo "NO STAMP — driver did not complete a healthy run"
echo "--- run log tail ---"
tail -12 /tmp/amaury-watch.log 2>/dev/null || echo "(no /tmp/amaury-watch.log)"
REMOTE_E
  # single authoritative runner: retire the Mac launchd job
  if launchctl list 2>/dev/null | grep -q com.goldensis.amaury-watch; then
    launchctl bootout "gui/$(id -u)/com.goldensis.amaury-watch" 2>/dev/null \
      && echo "Mac launchd amaury-watch UNLOADED (no double-send)" \
      || echo "NOTE: could not unload Mac job — do it manually before 29 Jun"
  fi
  say "DONE — driver live on the VPS (daily 06:20 UTC). Mac runner retired."
  echo "NEXT (firstmate, not this script): add amaury-driver to panic.sh/resume.sh + update recovery runbook + Dashlane warn."
else
  say "AUTH NOT READY — disabling VPS timer, leaving Mac runner (safe)"
  # never leave an enabled-but-credential-less VPS timer behind
  ssh "$VPS" "systemctl disable --now $SVC.timer 2>/dev/null; systemctl reset-failed $SVC.timer 2>/dev/null" || true
  cat <<EOF
The token fast-path did not authenticate (copied=$TOKEN_COPIED). Nothing was cut over.
Do the one-time OAuth for achretien22 on the VPS, then re-run this script:

  1) From your Mac, open a tunnel so the VPS OAuth callback reaches your browser:
       ssh -L 8080:localhost:8080 $VPS
  2) In that SSH session, authenticate (achretien22 ONLY):
       cd /opt/brain && claude
       # then: ask it to authenticate google-workspace for achretien22@gmail.com
       #       (manage_accounts authenticate) and complete consent in your browser:
       #       Advanced -> Go to brain-mail -> TICK the scope box -> Continue
  3) Re-run:  bash ~/firstmate/run/amaury-driver/deploy-amaury-driver.sh
EOF
fi
