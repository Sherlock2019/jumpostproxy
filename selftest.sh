#!/usr/bin/env bash
# Verify the kit itself: syntax, guards, rendering and the security properties
# that matter. Touches no infrastructure and needs no credentials.
#
#   ./selftest.sh

cd "$(dirname "$0")" || exit 1

# Private scratch dir. NOT fixed paths in /tmp: this kit is run both as you and
# as root, and with fs.protected_regular set (default on Ubuntu) the kernel
# refuses to let one user open the other's file for writing inside a sticky
# world-writable directory. A shared /tmp/e made every check fail under sudo
# with an empty error, because the redirect failed before the command ran.
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
try()  { if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }

head_ "1. Shell syntax"
for f in launch.sh install-requirements.sh lib.sh selftest.sh \
         bastion/*.sh sso-proxy/*.sh openstack/*.sh; do
  [ -f "$f" ] || continue
  # Capture stderr into a variable rather than a file: no temp path to collide
  # on, and the error can never come back empty.
  if err="$(bash -n "$f" 2>&1)"; then
    ok "$f parses"
  else
    no "$f — ${err:-bash could not read it}"
  fi
done

head_ "2. Placeholder guard (a half-configured run must abort)"
# Quoted heredoc, path passed as $1: with an unquoted one the outer shell
# expands the inner variables and the generated script tests empty strings.
cat > "$TMPD/guard.sh" <<'EOF'
KIT_DIR="$1"
. "$1/lib.sh"
load_env
require_real APP_PRIVATE_IP PUBLIC_HOSTNAME
echo "GUARD DID NOT FIRE"
EOF
mkdir -p "$TMPD/kit" && cp lib.sh "$TMPD/kit/" && cp env.example "$TMPD/kit/env"
if bash "$TMPD/guard.sh" "$TMPD/kit" 2>&1 | grep -q 'still the example value'; then
  ok "refuses placeholder values"
else
  no "placeholder values were accepted — a run could publish an open proxy"
fi

# and that it accepts real ones
sed -e 's|^APP_PRIVATE_IP=.*|APP_PRIVATE_IP="10.20.30.40"|' \
    -e 's|^PUBLIC_HOSTNAME=.*|PUBLIC_HOSTNAME="app.rackspace.com"|' \
    -e 's|^COMPANY_CIDR=.*|COMPANY_CIDR="198.51.100.0/24"|' \
    -e 's|^BASTION_FLOATING_IP=.*|BASTION_FLOATING_IP="198.51.100.9"|' \
    env.example > "$TMPD/kit/env"
if bash "$TMPD/guard.sh" "$TMPD/kit" 2>&1 | grep -q 'GUARD DID NOT FIRE'; then
  ok "accepts configured values"
else
  no "rejected a valid config"
fi

head_ "3. IPv4 / CIDR validation"
cat > "$TMPD/ipt.sh" <<'EOF'
KIT_DIR="$1"; . "$1/lib.sh"
for good in 10.0.0.1 192.168.1.0/24 203.0.113.5; do valid_ipv4 "$good" || { echo "REJECTED $good"; exit 1; }; done
for bad in 10.0.0 300.1.1.1 10.0.0.1/33 not-an-ip ""; do valid_ipv4 "$bad" && { echo "ACCEPTED $bad"; exit 1; }; done
echo IPOK
EOF
if bash "$TMPD/ipt.sh" "$TMPD/kit" 2>&1 | grep -q IPOK; then ok "accepts valid, rejects malformed"
else no "validation wrong: $(bash "$TMPD/ipt.sh" "$TMPD/kit" 2>&1 | tail -1)"; fi

head_ "4. nginx template renders to valid config"
if command -v envsubst >/dev/null 2>&1; then
  export APP_SCHEME=http APP_PRIVATE_IP=10.20.30.40 APP_PORT=5001 \
         PUBLIC_HOSTNAME=app.rackspace.com
  T=$(mktemp -d); mkdir -p "$T/conf" "$T/logs" "$T/ssl"
  openssl req -x509 -nodes -newkey rsa:2048 -days 1 -keyout "$T/ssl/k" -out "$T/ssl/c" \
    -subj "/CN=app.rackspace.com" >/dev/null 2>&1
  export TLS_CERT="$T/ssl/c" TLS_KEY="$T/ssl/k"
  envsubst '${APP_SCHEME} ${APP_PRIVATE_IP} ${APP_PORT} ${PUBLIC_HOSTNAME} ${TLS_CERT} ${TLS_KEY}' \
    < sso-proxy/nginx-app-sso.conf.tmpl > "$T/conf/site.conf"

  # Directives are column-aligned in the template, so match on whitespace runs.
  grep -Eq 'proxy_pass[[:space:]]+http://10\.20\.30\.40:5001;' "$T/conf/site.conf" \
    && ok "upstream points at the private app" || no "upstream not substituted"
  # Ignore comment lines: the header comment legitimately contains the string
  # "${...}" while explaining what gets substituted.
  if grep -v '^[[:space:]]*#' "$T/conf/site.conf" | grep -q '\${'; then
    no "unsubstituted \${...} left in a directive"
  else
    ok "no placeholders left in any directive"
  fi

  if command -v nginx >/dev/null 2>&1; then
    MIME=/etc/nginx/mime.types; [ -f "$MIME" ] || MIME=/dev/null
    cat > "$T/nginx.conf" <<EOF
worker_processes 1; pid $T/nginx.pid; error_log $T/logs/e.log;
events { worker_connections 64; }
http {
  include $MIME;
  access_log $T/logs/a.log;
  client_body_temp_path $T/logs/b; proxy_temp_path $T/logs/p;
  fastcgi_temp_path $T/logs/f; uwsgi_temp_path $T/logs/u; scgi_temp_path $T/logs/s;
  map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
  include $T/conf/site.conf;
}
EOF
    sed -i 's/listen 443 ssl http2;/listen 15443 ssl;/; s/listen 80;/listen 15080;/' "$T/conf/site.conf"
    if ngout="$(nginx -p "$T" -c "$T/nginx.conf" -t 2>&1)"; then
      ok "nginx accepts the rendered site"
    else
      no "nginx rejected it: $(printf '%s' "$ngout" | grep -m1 -E 'emerg|error' || printf '%s' "$ngout" | head -1)"
    fi
  else
    printf '  \033[33mSKIP\033[0m nginx not installed — cannot syntax-check the site\n'
  fi
  rm -rf "$T"
else
  no "envsubst missing (apt install gettext-base)"
fi

head_ "5. Header-smuggling defence"
for h in X-Forwarded-User X-SSO-User X-Forwarded-Preferred-Username \
         X-SSO-Role X-Forwarded-Groups X-Remote-User Remote-User; do
  grep -q "proxy_set_header $h  *\"\";" sso-proxy/nginx-app-sso.conf.tmpl \
    && ok "blanks $h" || no "$h NOT blanked — a client could forge it"
done
grep -Eq 'auth_request_set[[:space:]]+\$ar_email[[:space:]]+\$upstream_http_x_auth_request_email' \
  sso-proxy/nginx-app-sso.conf.tmpl \
  && ok "identity taken from the verified subrequest" || no "identity not from auth_request"

head_ "5b. Sign-in page collects nothing"
if [ -f sso-proxy/signin.html.tmpl ]; then
  grep -qiE 'type=["'"'"']?password|<input[^>]+pass' sso-proxy/signin.html.tmpl \
    && no "sign-in page has a PASSWORD FIELD — credentials must go to Microsoft" \
    || ok "no password field"
  grep -qiE '<input' sso-proxy/signin.html.tmpl \
    && no "sign-in page has an <input> — it should only link out" \
    || ok "no input elements at all"
  grep -qiE '<form' sso-proxy/signin.html.tmpl \
    && no "sign-in page has a <form> — nothing should post here" \
    || ok "no form"
  grep -q '/oauth2/start' sso-proxy/signin.html.tmpl \
    && ok "button starts the real OIDC flow" || no "button does not link to /oauth2/start"
  grep -q 'die "signin.html contains a password field' sso-proxy/setup-sso-proxy.sh \
    && ok "installer refuses a password field" || no "installer would install one"
  # An absolute URL in ?rd= would make this page an open redirect.
  grep -q "\^\\\\/(?!\\\\/)" sso-proxy/signin.html.tmpl \
    && ok "rd= restricted to same-site paths (no open redirect)" \
    || no "rd= not restricted — open-redirect risk"
  grep -q 'auth_request off' sso-proxy/nginx-app-sso.conf.tmpl \
    && ok "/signin is reachable without a session" \
    || no "/signin behind auth — sign-in would deadlock"
else
  no "sso-proxy/signin.html.tmpl missing"
fi

head_ "6. Bastion restricts the key to a tunnel"
grep -q 'restrict,port-forwarding,permitopen=' bastion/add-engineer.sh \
  && ok "authorized_keys uses restrict + permitopen" || no "key is not restricted"
grep -q 'ForceCommand' bastion/setup-bastion.sh \
  && ok "ForceCommand blocks a shell" || no "no ForceCommand — the account could get a shell"
grep -q 'AllowAgentForwarding no' bastion/setup-bastion.sh \
  && ok "agent forwarding disabled" || no "agent forwarding left on"
grep -q 'sshd -t' bastion/setup-bastion.sh \
  && ok "validates sshd config before reload (no lockout)" || no "reloads sshd unchecked"
grep -q 'nologin' bastion/setup-bastion.sh \
  && ok "tunnel account has no login shell" || no "tunnel account has a shell"

head_ "7. Guards against publishing to the world"
grep -q '0.0.0.0/0) die' openstack/provision-jumphost.sh \
  && ok "refuses COMPANY_CIDR=0.0.0.0/0" || no "would accept 0.0.0.0/0"
grep -q -- '--dry-run' sso-proxy/setup-sso-proxy.sh \
  && ok "SSO setup has a dry run" || no "no dry run"
grep -q -- '--plan' openstack/provision-jumphost.sh \
  && ok "provisioning has a plan mode" || no "no plan mode"
grep -q 'the app answered WITHOUT auth' sso-proxy/setup-sso-proxy.sh \
  && ok "verify flags an open proxy" || no "verify does not check for an open proxy"

head_ "7b. No fixed /tmp paths (they break under sudo)"
# fs.protected_regular stops one user opening another's file for writing inside
# sticky /tmp. A shared path therefore works until someone runs with sudo, then
# fails with an EMPTY error because the redirect dies before the command runs.
if hits="$(grep -nE '^[^#]*[^$]/tmp/[A-Za-z0-9_.]' \
             launch.sh selftest.sh lib.sh install-requirements.sh \
             bastion/*.sh sso-proxy/*.sh openstack/*.sh 2>/dev/null)"; then
  no "hardcoded /tmp path(s):"
  printf '%s\n' "$hits" | sed 's/^/         /'
else
  ok "all scratch space via mktemp or shell variables"
fi

head_ "8. Secrets never land in git"
grep -qx 'env' .gitignore 2>/dev/null && ok "env is gitignored" || no "env not gitignored"
grep -q 'oauth2-proxy.cfg' .gitignore 2>/dev/null \
  && ok "rendered oauth2-proxy.cfg ignored" || no "rendered config not ignored"
grep -RIl 'client_secret *= *"[^<]' --include='*.tmpl' --include='*.example' . 2>/dev/null | grep -q . \
  && no "a real-looking secret is committed" || ok "no literal secrets in tracked files"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ))
