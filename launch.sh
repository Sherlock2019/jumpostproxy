#!/usr/bin/env bash
# Dry-run the whole kit end to end. Nothing is created, changed or deleted.
#
#   ./launch.sh              # preflight everything, print what WOULD happen
#   ./launch.sh --verbose    # also print the rendered files
#
# Use this before the first real run, and again after editing env. Every stage
# is skipped gracefully when its prerequisites are absent, so this is safe to
# run from a laptop with no cloud credentials and no jumphost.

cd "$(dirname "$0")" || exit 1
VERBOSE=0; INIT=0
case "${1:-}" in
  --verbose) VERBOSE=1 ;;
  --init)    INIT=1 ;;
  --help|-h) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# --init: create env from the template so the checklist below has something to
# report on. Never overwrites an existing env.
if [ "$INIT" = 1 ]; then
  if [ -f env ]; then
    printf 'env already exists — not overwriting. Edit it directly.\n'
  else
    cp env.example env && chmod 600 env
    printf 'Created ./env (mode 600). Fill in the values marked below.\n'
  fi
fi

R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
STAGE_OK=0; STAGE_SKIP=0; STAGE_FAIL=0
title() { printf '\n%s┌─ %s %s\n' "$B" "$1" "$N"; }
good()  { printf '   %s✔%s %s\n' "$G" "$N" "$1"; STAGE_OK=$((STAGE_OK+1)); }
skip()  { printf '   %s–%s %s\n' "$Y" "$N" "$1"; STAGE_SKIP=$((STAGE_SKIP+1)); }
bad()   { printf '   %s✘%s %s\n' "$R" "$N" "$1"; STAGE_FAIL=$((STAGE_FAIL+1)); }
note()  { printf '     %s%s%s\n' "$D" "$1" "$N"; }

printf '%s\n' "$B== junphostrain — dry run ==$N"
note "Nothing below creates, changes or deletes anything."

# ── 1. the kit itself ───────────────────────────────────────────────────────
title "1. Kit self-test"
if [ -x ./selftest.sh ]; then
  if out="$(./selftest.sh 2>&1)"; then
    # Strip the ANSI sequence, not every digit — `tr -d '0-9'` ate the counts.
    good "$(printf '%s' "$out" | tail -1 | sed 's/\x1b\[[0-9;]*m//g')"
  else
    bad "self-test failed"
    printf '%s\n' "$out" | grep -E 'FAIL' | sed 's/^/     /'
  fi
else
  bad "selftest.sh missing or not executable  (chmod +x selftest.sh)"
fi

# ── 2. configuration ────────────────────────────────────────────────────────
title "2. Configuration (env)"
TODO=0
if [ ! -f env ]; then
  skip "no env yet  —  run:  ./launch.sh --init"
  note "Later stages need it, so they will be skipped too."
else
  # shellcheck disable=SC1091
  . ./env
  perm="$(stat -c '%a' env 2>/dev/null || echo '?')"
  [ "$perm" = "600" ] && good "env present, mode 600" \
                      || bad "env is mode $perm — chmod 600 env (it holds a client secret)"

  # A value still on its example is a TODO, not a failure: the scripts
  # themselves refuse to run on placeholders, so this is a checklist, not a gate.
  for v in APP_PRIVATE_IP APP_PORT COMPANY_CIDR BASTION_FLOATING_IP; do
    val="${!v-}"
    case "$val" in
      ''|*'<'*'>'*|0.0.0.0|10.0.0.0|203.0.113.0/24)
        skip "$v — still to fill in  (currently: ${val:-empty})"; TODO=$((TODO+1)) ;;
      *) good "$v = $val" ;;
    esac
  done
  # This one is never a TODO. It is the outer gate.
  case "${COMPANY_CIDR:-}" in
    0.0.0.0/0) bad "COMPANY_CIDR is 0.0.0.0/0 — that publishes the jumphost to the internet" ;;
  esac
  [ "$TODO" -gt 0 ] && note "Edit ./env, then re-run ./launch.sh"
fi

# ── 3. OpenStack plan ───────────────────────────────────────────────────────
title "3. OpenStack — what would be created"
if ! command -v openstack >/dev/null 2>&1; then
  skip "openstack CLI not installed"
elif [ -z "${OS_AUTH_URL:-}" ]; then
  skip "no cloud credentials in this shell  —  source ~/openrc.sh"
  note "Plan mode still works once sourced; it prints commands and runs none."
elif [ ! -f env ]; then
  skip "needs env"
else
  if out="$(./openstack/provision-jumphost.sh --plan 2>&1)"; then
    good "plan generated for project '${OS_PROJECT_NAME:-?}'"
    printf '%s\n' "$out" | grep -E '^\s+openstack' | sed 's/^/     /' | head -12
  else
    bad "plan failed"; printf '%s\n' "$out" | tail -4 | sed 's/^/     /'
  fi
fi

# ── 4. SSO proxy render ─────────────────────────────────────────────────────
title "4. SSO proxy — render without installing"
if [ ! -f env ]; then
  skip "needs env"
elif ! command -v envsubst >/dev/null 2>&1; then
  bad "envsubst missing  —  sudo apt install gettext-base"
else
  if out="$(./sso-proxy/setup-sso-proxy.sh --dry-run 2>&1)"; then
    good "rendered to sso-proxy/.rendered/"
    up="$(grep -E 'proxy_pass[[:space:]]+https?://' sso-proxy/.rendered/app-sso.conf 2>/dev/null \
          | grep -v 127.0.0.1 | tr -s ' ' | sed 's/^ *//')"
    note "upstream: ${up:-<none found>}"
    if grep -v '^[[:space:]]*#' sso-proxy/.rendered/app-sso.conf 2>/dev/null | grep -q '\${'; then
      bad "a \${placeholder} survived into a directive"
    else
      good "no placeholders left in any directive"
    fi
    [ "$VERBOSE" = 1 ] && sed 's/^/     /' sso-proxy/.rendered/app-sso.conf
  else
    skip "not rendered"
    printf '%s\n' "$out" | grep -E 'ERROR|still the example' | sed 's/^/     /' | head -3
  fi
fi

# ── 5. bastion ──────────────────────────────────────────────────────────────
title "5. Bastion"
if [ ! -f env ]; then
  skip "needs env"
elif [ ! -f /etc/ssh/sshd_config ]; then
  skip "no sshd here — this stage reports only when run ON the jumphost"
else
  if out="$(./bastion/setup-bastion.sh --check 2>&1)"; then
    good "state read"
    printf '%s\n' "$out" | grep -E '^\s{2}\w' | sed 's/^/     /'
  else
    skip "could not read state"
  fi
fi

# ── 6. reachability ─────────────────────────────────────────────────────────
title "6. Can anything here reach the app?"
if [ ! -f env ]; then
  skip "needs env"
elif ! command -v nc >/dev/null 2>&1; then
  skip "nc not installed"
else
  if nc -z -w3 "$APP_PRIVATE_IP" "$APP_PORT" 2>/dev/null; then
    good "$APP_PRIVATE_IP:$APP_PORT reachable from this machine"
  else
    skip "$APP_PRIVATE_IP:$APP_PORT not reachable from here"
    note "Expected from a laptop — a private IP is not routable outside the tenant."
    note "It MUST succeed from the jumphost, or nothing downstream will work."
  fi
fi

# ── summary ─────────────────────────────────────────────────────────────────
printf '\n%s== summary ==%s\n' "$B" "$N"
printf '   %s%d ok%s   %s%d skipped%s   %s%d problems%s\n' \
  "$G" "$STAGE_OK" "$N" "$Y" "$STAGE_SKIP" "$N" "$R" "$STAGE_FAIL" "$N"

if [ "$STAGE_FAIL" -gt 0 ]; then
  printf '\n   Fix the %s✘%s items before any real run.\n' "$R" "$N"
  exit 1
fi

if [ ! -f env ]; then
  cat <<NEXT

   Next:  ./launch.sh --init      creates ./env for you
          \$EDITOR env             fill in the marked values
          ./launch.sh             re-check
NEXT
  exit 0
fi
if [ "${TODO:-0}" -gt 0 ]; then
  printf '\n   %d value(s) still to fill in ./env, then re-run ./launch.sh\n' "$TODO"
  exit 0
fi
cat <<NEXT

   Config looks complete. When you are ready, in this order:
     source ~/openrc.sh
     ./openstack/provision-jumphost.sh          # creates the VM + floating IP
     # copy the printed IP into env as BASTION_FLOATING_IP, then ON the jumphost:
     sudo ./bastion/setup-bastion.sh            # tunnel path
     sudo ./sso-proxy/setup-sso-proxy.sh        # SSO path
NEXT
