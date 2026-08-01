#!/usr/bin/env bash
# Dry-run the whole kit end to end. Nothing is created, changed or deleted.
#
#   sudo ./launch.sh         # ON THE JUMPHOST with ./env complete: installs
#                            # EVERYTHING — deps, bastion, SSO proxy — and
#                            # verifies it. This is the one command.
#
#   ./launch.sh              # anywhere else: preflight, then SHOW the sign-in
#                            # page in your browser. Changes nothing.
#   ./launch.sh --no-web     # preflight only, no page, no browser
#   ./launch.sh --dry-run    # force the preflight even as root
#   ./launch.sh --init       # create ./env, or top it up with new settings
#   ./launch.sh --preview    # render the sign-in page and serve it locally
#   ./launch.sh --verbose    # also print the rendered files
#
#   sudo ./launch.sh --install bastion   # just one path
#   sudo ./launch.sh --install sso
#
# Use this before the first real run, and again after editing env. Every stage
# is skipped gracefully when its prerequisites are absent, so this is safe to
# run from a laptop with no cloud credentials and no jumphost.

cd "$(dirname "$0")" || exit 1
VERBOSE=0; INIT=0; FORCE_DRY=0
case "${1:-}" in
  --verbose) VERBOSE=1 ;;
  --init)    INIT=1 ;;
  --preview) PREVIEW=1 ;;
  --install) INSTALL="${2:-all}" ;;
  --dry-run) FORCE_DRY=1 ;;
  --no-web)  NO_WEB=1 ;;
  --help|-h) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# Open a URL in whatever browser this machine can reach. WSL is handled first:
# xdg-open exists there but usually fails, while wslview / explorer.exe reach the
# Windows browser. Silent no-op on a headless jumphost — printing the URL is the
# fallback, and the caller always prints it too.
open_url() {
  local url="$1"
  if grep -qi microsoft /proc/version 2>/dev/null; then
    command -v wslview     >/dev/null 2>&1 && { wslview "$url" >/dev/null 2>&1 & return 0; }
    command -v explorer.exe >/dev/null 2>&1 && { explorer.exe "$url" >/dev/null 2>&1 & return 0; }
  fi
  for o in xdg-open open sensible-browser x-www-browser; do
    command -v "$o" >/dev/null 2>&1 && { "$o" "$url" >/dev/null 2>&1 & return 0; }
  done
  return 1
}

# Is every value this machine needs actually filled in?
#   $1 = role. Prints nothing; returns the number of unfilled settings.
cfg_missing() {
  local role="$1" n=0 v
  for v in APP_PRIVATE_IP APP_PORT COMPANY_CIDR; do
    case "${!v-}" in
      ''|*'<'*'>'*|0.0.0.0|10.0.0.0|203.0.113.0/24) n=$((n+1)) ;;
    esac
  done
  if [ "$role" != bastion ]; then
    for v in PUBLIC_HOSTNAME ENTRA_TENANT_ID ENTRA_CLIENT_ID ENTRA_CLIENT_SECRET; do
      case "${!v-}" in
        ''|*'<'*'>'*|app.example.com) n=$((n+1)) ;;
      esac
    done
  fi
  return "$n"
}

# Run bare, as root, on a machine whose config is complete? Then the intent is
# obviously "set this up", not "show me a report" — so do it. Everywhere else,
# including a laptop or a half-filled env, stays a dry run.
if [ -z "${INSTALL:-}" ] && [ "${PREVIEW:-0}" != 1 ] && [ "$INIT" = 0 ] \
   && [ "$FORCE_DRY" = 0 ] && [ "$(id -u)" -eq 0 ] && [ -f env ]; then
  # shellcheck disable=SC1091
  . ./env
  if cfg_missing all; then INSTALL=all; fi
fi

# --init: create env from the template, or top up an existing one with any keys
# added since it was made. Never changes a value you have already set.
if [ "$INIT" = 1 ]; then
  if [ -f env ]; then
    added=0
    while IFS= read -r line; do
      case "$line" in
        [A-Z_]*=*)
          k="${line%%=*}"
          grep -q "^${k}=" env || { printf '\n%s\n' "$line" >> env; added=$((added+1)); }
          ;;
      esac
    done < env.example
    [ "$added" -gt 0 ] \
      && printf 'env exists — added %d new setting(s) from env.example.\n' "$added" \
      || printf 'env already has every setting. Nothing changed.\n'
  else
    cp env.example env && chmod 600 env
    printf 'Created ./env (mode 600). Fill in the values marked below.\n'
  fi
fi

# Render the sign-in page and serve it locally, so the UI can be seen before any
# jumphost, DNS or Entra registration exists. Used by --preview and by the tail
# of a normal dry run.
serve_preview() {
  [ -f env ] && . ./env
  if ! command -v envsubst >/dev/null 2>&1; then
    printf '   (no envsubst — sudo apt install gettext-base to preview the page)\n'; return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    printf '   (no python3 — cannot serve the preview)\n'; return 1
  fi
  D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
  export APP_NAME="${APP_NAME:-Application}" \
         ORG_NAME="${ORG_NAME:-Rackspace}" \
         ALLOWED_EMAIL_DOMAIN="${ALLOWED_EMAIL_DOMAIN:-rackspace.com}"
  envsubst '${APP_NAME} ${ORG_NAME} ${ALLOWED_EMAIL_DOMAIN}' \
    < sso-proxy/signin.html.tmpl > "$D/index.html"

  local P="${PREVIEW_PORT:-8088}"
  # A port already in use would make the server exit and the browser show
  # somebody else's page, which is worse than saying so.
  if command -v ss >/dev/null 2>&1 && ss -ltn "( sport = :$P )" 2>/dev/null | grep -q LISTEN; then
    printf '   port %s is in use — retry with PREVIEW_PORT=<other> ./launch.sh\n' "$P"; return 1
  fi
  local URL="http://localhost:$P"
  printf '\n%s   Sign-in page:  %s%s\n' "$G" "$URL" "$N"
  printf '   Showing: %s / %s / @%s\n' "$ORG_NAME" "$APP_NAME" "$ALLOWED_EMAIL_DOMAIN"
  printf '   The button goes to /oauth2/start, which only exists on the deployed\n'
  printf '   proxy — clicking it here 404s. That is expected.\n'
  printf '   %sCtrl-C to stop.%s\n\n' "$D_" "$N"
  ( sleep 1; open_url "$URL" || printf '   (open %s yourself)\n' "$URL" ) &
  exec python3 -m http.server "$P" --directory "$D" --bind 127.0.0.1
}

if [ "${PREVIEW:-0}" = 1 ]; then serve_preview; exit $?; fi

# D_ not D: serve_preview() uses D for its temp directory.
R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; D_=$'\033[2m'; N=$'\033[0m'
STAGE_OK=0; STAGE_SKIP=0; STAGE_FAIL=0
title() { printf '\n%s┌─ %s %s\n' "$B" "$1" "$N"; }
good()  { printf '   %s✔%s %s\n' "$G" "$N" "$1"; STAGE_OK=$((STAGE_OK+1)); }
skip()  { printf '   %s–%s %s\n' "$Y" "$N" "$1"; STAGE_SKIP=$((STAGE_SKIP+1)); }
bad()   { printf '   %s✘%s %s\n' "$R" "$N" "$1"; STAGE_FAIL=$((STAGE_FAIL+1)); }
note()  { printf '     %s%s%s\n' "$D_" "$1" "$N"; }

# --install: the real thing. Runs ON THE JUMPHOST and does the whole path —
# dependencies, config, service, verification — in one command.
if [ -n "${INSTALL:-}" ]; then
  ROLE="$INSTALL"
  case "$ROLE" in sso|bastion|all) ;; *) echo "role must be sso | bastion | all"; exit 1 ;; esac
  [ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo ./launch.sh --install $ROLE"; exit 1; }
  [ -f env ] || { echo "no ./env — run ./launch.sh --init and fill it in first"; exit 1; }
  . ./env

  printf '%s\n' "$B== junphostrain — installing '$ROLE' on $(hostname) ==$N"

  # Refuse a half-filled config. On the SSO path that would stand up a proxy
  # pointing at nothing, reachable from anywhere.
  if ! cfg_missing "$ROLE"; then
    printf '\n   %sConfiguration is incomplete:%s\n' "$R" "$N"
    for v in APP_PRIVATE_IP APP_PORT COMPANY_CIDR PUBLIC_HOSTNAME \
             ENTRA_TENANT_ID ENTRA_CLIENT_ID ENTRA_CLIENT_SECRET; do
      [ "$ROLE" = bastion ] && case "$v" in PUBLIC_HOSTNAME|ENTRA_*) continue ;; esac
      case "${!v-}" in
        ''|*'<'*'>'*|0.0.0.0|10.0.0.0|203.0.113.0/24|app.example.com)
          printf '     %s✘%s %-22s %s\n' "$R" "$N" "$v" "${!v:-<empty>}" ;;
      esac
    done
    printf '\n   Fill these in ./env, then re-run.\n'
    exit 1
  fi

  printf '\n   %sThis WILL change this machine.%s\n' "$Y" "$N"
  printf '     app        : %s://%s:%s\n' "$APP_SCHEME" "$APP_PRIVATE_IP" "$APP_PORT"
  printf '     inbound    : %s only\n' "$COMPANY_CIDR"
  [ "$ROLE" != bastion ] && printf '     public URL : https://%s\n' "$PUBLIC_HOSTNAME"
  printf '   %sCtrl-C now to stop, or run ./launch.sh --dry-run to preview.%s\n' "$D_" "$N"
  sleep 3

  title "Dependencies"
  ./install-requirements.sh "--$ROLE" || exit 1

  if [ "$ROLE" = bastion ] || [ "$ROLE" = all ]; then
    title "Bastion"
    ./bastion/setup-bastion.sh || exit 1
  fi
  if [ "$ROLE" = sso ] || [ "$ROLE" = all ]; then
    title "SSO proxy"
    ./sso-proxy/setup-sso-proxy.sh || exit 1
    title "Verifying"
    ./sso-proxy/setup-sso-proxy.sh --verify
  fi

  printf '\n%s== done ==%s\n' "$B" "$N"
  if [ "$ROLE" != bastion ]; then
    printf '   Share this link:  %shttps://%s%s\n' "$G" "$PUBLIC_HOSTNAME" "$N"
    printf '   Colleagues sign in with their company account. No credential changes hands.\n'
    # Only worth attempting where a browser can exist; a jumphost is usually
    # headless, and the URL above is the real deliverable either way.
    open_url "https://$PUBLIC_HOSTNAME" 2>/dev/null && printf '   (opening it now)\n'
  fi
  [ "$ROLE" != sso ] && printf '   Add an engineer:  sudo ./bastion/add-engineer.sh <name> <key.pub>\n'
  exit 0
fi

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
elif [ "${TODO:-0}" -gt 0 ]; then
  printf '\n   %d value(s) still to fill in ./env, then re-run ./launch.sh\n' "$TODO"
else
  cat <<NEXT

   Config looks complete. When you are ready, in this order:
     source ~/openrc.sh
     ./openstack/provision-jumphost.sh          # creates the VM + floating IP
     # copy the printed IP into env as BASTION_FLOATING_IP, then ON the jumphost:
     sudo ./launch.sh                           # installs everything, verifies
NEXT
fi

# Finish by putting the sign-in page on screen. The report says what will
# happen; this shows what people will actually see. Skipped as root (a jumphost
# is usually headless and this would block the terminal) and with --no-web.
if [ "${NO_WEB:-0}" != 1 ] && [ "$(id -u)" -ne 0 ]; then
  serve_preview || true
fi
