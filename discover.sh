#!/usr/bin/env bash
# Work out what this machine already knows, and write it into ./env.
#
#   ./discover.sh            # detect, show, ask before writing
#   ./discover.sh --show     # detect and print only
#   ./discover.sh --yes      # write without asking
#
# Intended to run ON the jumphost — the FLEX VM that holds the floating IP.
# Everything here is read-only against the machine and the OpenStack metadata
# service; nothing is created and no cloud credentials are required.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# Discovery is a sequence of things that are EXPECTED to fail — no metadata
# service off-cloud, no OpenStack CLI, no egress. lib.sh sets `set -e` and
# pipefail, under which the first curl timeout (exit 28) killed this script
# mid-report. Failures are handled explicitly from here on.
set +e +o pipefail

MODE="${1:-write}"
MD="http://169.254.169.254"          # OpenStack/EC2 metadata service
CURL="curl -s --max-time 2"

FOUND_PUBLIC=""; FOUND_FIXED=""; FOUND_NAME=""; FOUND_PROJECT=""
FOUND_APP_IP=""; FOUND_APP_PORT=""; SRC_PUBLIC=""; SRC_APP=""

step "Instance"

# ── name / project, from the metadata service ───────────────────────────────
if md="$($CURL "$MD/openstack/latest/meta_data.json" 2>/dev/null)" && [ -n "$md" ]; then
  if command -v jq >/dev/null 2>&1; then
    FOUND_NAME="$(printf '%s' "$md" | jq -r '.name // empty')"
    FOUND_PROJECT="$(printf '%s' "$md" | jq -r '.project_id // empty')"
  else
    FOUND_NAME="$(printf '%s' "$md" | grep -o '"name"[^,]*' | cut -d'"' -f4)"
  fi
  c_grn "  metadata service reachable — this is an OpenStack instance"
  [ -n "$FOUND_NAME" ]    && printf '    name       : %s\n' "$FOUND_NAME"
  [ -n "$FOUND_PROJECT" ] && printf '    project    : %s\n' "$FOUND_PROJECT"
else
  c_ylw "  no metadata service — not an OpenStack VM, or egress to 169.254.169.254 is blocked"
fi

# ── fixed (tenant) address: the source IP of the default route ──────────────
FOUND_FIXED="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
[ -n "$FOUND_FIXED" ] && printf '    fixed IP   : %s\n' "$FOUND_FIXED"

step "Public address (the floating IP)"
# A floating IP is NAT'd, so it does NOT appear in `ip addr`. Ask, in order:
#   1. the EC2-compat metadata key, which OpenStack populates when a floating
#      IP is associated
#   2. the OpenStack API, if credentials happen to be present
#   3. an outside echo service, only if there is egress
pub="$($CURL "$MD/latest/meta-data/public-ipv4" 2>/dev/null | tr -d '[:space:]')"
if [ -n "$pub" ] && valid_ipv4 "$pub"; then
  FOUND_PUBLIC="$pub"; SRC_PUBLIC="metadata service"
elif command -v openstack >/dev/null 2>&1 && [ -n "${OS_AUTH_URL:-}" ] && [ -n "$FOUND_NAME" ]; then
  pub="$(openstack server show "$FOUND_NAME" -f json 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | grep -v "^${FOUND_FIXED}$" | tail -1)"
  [ -n "$pub" ] && { FOUND_PUBLIC="$pub"; SRC_PUBLIC="openstack API"; }
fi
if [ -z "$FOUND_PUBLIC" ]; then
  pub="$($CURL https://ifconfig.me 2>/dev/null | tr -d '[:space:]')"
  if valid_ipv4 "${pub:-x}"; then
    FOUND_PUBLIC="$pub"; SRC_PUBLIC="outbound echo (this is the NAT address — confirm it is your floating IP)"
  fi
fi
if [ -n "$FOUND_PUBLIC" ]; then
  c_grn "  $FOUND_PUBLIC"
  printf '    source: %s\n' "$SRC_PUBLIC"
else
  c_red "  not determined — set BASTION_FLOATING_IP by hand"
fi

step "The app"
# If the app runs on this same VM, the proxy should talk to 127.0.0.1 rather
# than out and back through the network.
if [ -f env ]; then . ./env; fi
hint="${APP_PORT:-}"
mapfile -t LISTEN < <(ss -ltnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' \
                      | grep -E '^[0-9]+$' | sort -un \
                      | grep -vE '^(22|53|68|123|323|631|5353)$')
if [ "${#LISTEN[@]}" -gt 0 ]; then
  printf '  ports listening on this VM: %s\n' "${LISTEN[*]}"
  for p in "${LISTEN[@]}"; do
    if [ -n "$hint" ] && [ "$p" = "$hint" ]; then
      FOUND_APP_IP="127.0.0.1"; FOUND_APP_PORT="$p"; SRC_APP="running here, matches APP_PORT"
      break
    fi
  done
  if [ -z "$FOUND_APP_PORT" ]; then
    c_dim "  none matches APP_PORT=${hint:-unset} — the app is probably on another VM"
  fi
else
  c_dim "  nothing listening here — the app is on another VM"
fi

# Can we reach the configured app from this machine? That is the check that
# decides whether anything downstream can work.
if [ -n "${APP_PRIVATE_IP:-}" ] && [ -n "${APP_PORT:-}" ] && command -v nc >/dev/null 2>&1; then
  printf '  reaching %s:%s ... ' "$APP_PRIVATE_IP" "$APP_PORT"
  if nc -z -w3 "$APP_PRIVATE_IP" "$APP_PORT" 2>/dev/null; then
    c_grn "ok"
  else
    c_red "no route/refused"
    c_dim "    the app's security group must allow this VM, or the app is bound to 127.0.0.1"
  fi
fi

step "Cannot be detected — you must supply these"
printf '  %-22s %s\n' "COMPANY_CIDR" "policy: who may reach this VM. Ask your network team."
printf '  %-22s %s\n' "PUBLIC_HOSTNAME" "a decision, plus a DNS A record -> ${FOUND_PUBLIC:-<floating ip>}"
printf '  %-22s %s\n' "ENTRA_TENANT_ID" "identity team"
printf '  %-22s %s\n' "ENTRA_CLIENT_ID" "identity team - app registration"
printf '  %-22s %s\n' "ENTRA_CLIENT_SECRET" "identity team - and it expires"

[ "$MODE" = "--show" ] && exit 0

# ── write ───────────────────────────────────────────────────────────────────
step "Writing to ./env"
[ -f env ] || { cp env.example env; chmod 600 env; c_dim "  created ./env"; }

set_kv() {           # only fills a value that is still an example
  local k="$1" v="$2" cur
  [ -n "$v" ] || return 0
  # Strip the inline comment and quotes: env.example annotates its values, and
  # reading `10.0.0.0   # e.g. ...` as the value defeats the placeholder match.
  cur="$(grep -E "^$k=" env | head -1 | cut -d= -f2- \
         | sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
         | tr -d '"')"
  case "$cur" in
    ''|*'<'*'>'*|0.0.0.0|10.0.0.0|203.0.113.0/24|app.example.com) ;;
    *) c_dim "  $k already set to $cur — left alone"; return 0 ;;
  esac
  if grep -qE "^$k=" env; then
    sed -i "s|^$k=.*|$k=\"$v\"|" env
  else
    printf '%s="%s"\n' "$k" "$v" >> env
  fi
  c_grn "  $k = $v"
}

if [ "$MODE" != "--yes" ]; then
  printf '\n  Will set: '
  [ -n "$FOUND_PUBLIC" ]   && printf 'BASTION_FLOATING_IP=%s ' "$FOUND_PUBLIC"
  [ -n "$FOUND_APP_IP" ]   && printf 'APP_PRIVATE_IP=%s ' "$FOUND_APP_IP"
  [ -n "$FOUND_APP_PORT" ] && printf 'APP_PORT=%s ' "$FOUND_APP_PORT"
  printf '\n'
  confirm "  Write these into ./env?"
fi

set_kv BASTION_FLOATING_IP "$FOUND_PUBLIC"
set_kv APP_PRIVATE_IP      "$FOUND_APP_IP"
set_kv APP_PORT            "$FOUND_APP_PORT"

step "Next"
echo "  \$EDITOR env      # fill COMPANY_CIDR, and the ENTRA_* values for the SSO path"
echo "  ./launch.sh      # re-check"
