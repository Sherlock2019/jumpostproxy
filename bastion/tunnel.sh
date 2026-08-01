#!/usr/bin/env bash
# Client side. Run on YOUR laptop — opens the tunnel and holds it.
#
#   ./tunnel.sh              # forward and stay in the foreground
#   ./tunnel.sh --test       # connect, probe the app, report, exit
#
# Nothing about the app is exposed publicly: the traffic rides inside your SSH
# session to the bastion, which is the only machine with a floating IP.

. "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"
load_env
require_real APP_PRIVATE_IP APP_PORT BASTION_FLOATING_IP
need_cmd ssh

LOCAL_PORT="${LOCAL_PORT:-$APP_PORT}"
TARGET="$BASTION_USER@$BASTION_FLOATING_IP"
FWD="$LOCAL_PORT:$APP_PRIVATE_IP:$APP_PORT"

# A local port already in use silently makes ssh drop the forward and you spend
# ten minutes wondering why the page will not load.
if command -v ss >/dev/null && ss -ltn "( sport = :$LOCAL_PORT )" | grep -q LISTEN; then
  die "local port $LOCAL_PORT is already in use — set LOCAL_PORT=<other> and retry"
fi

if [ "${1:-}" = "--test" ]; then
  step "Testing the path"
  printf '  ssh to bastion ... '
  if ssh -o BatchMode=yes -o ConnectTimeout=8 -p "$BASTION_SSH_PORT" \
         -O check "$TARGET" >/dev/null 2>&1 ||
     ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
         -p "$BASTION_SSH_PORT" -N -f -L "$FWD" "$TARGET" 2>/tmp/jh.err; then
    c_grn "ok"
  else
    c_red "failed"; sed 's/^/    /' /tmp/jh.err; exit 1
  fi
  sleep 1
  printf '  app through tunnel ... '
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 \
          "$APP_SCHEME://localhost:$LOCAL_PORT/" || true)"
  [ "$code" != "000" ] && c_grn "HTTP $code" || c_red "no response"
  pkill -f "ssh.*-L $FWD" 2>/dev/null || true
  exit 0
fi

step "Tunnel"
cat <<INFO
  localhost:$LOCAL_PORT  ->  $BASTION_FLOATING_IP  ->  $APP_PRIVATE_IP:$APP_PORT

  Open:  $APP_SCHEME://localhost:$LOCAL_PORT
  Stop:  Ctrl-C
INFO

# ExitOnForwardFailure: fail loudly instead of connecting with no forward.
exec ssh -N \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -p "$BASTION_SSH_PORT" \
  -L "$FWD" "$TARGET"
