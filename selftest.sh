#!/usr/bin/env bash
# Verify the kit itself: syntax, guards, rendering and the security properties
# that matter. Touches no infrastructure and needs no credentials.
#
#   ./selftest.sh

cd "$(dirname "$0")" || exit 1
PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
try()  { if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }

head_ "1. Shell syntax"
for f in lib.sh selftest.sh bastion/*.sh sso-proxy/*.sh openstack/*.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/tmp/e; then ok "$f parses"; else no "$f — $(head -1 /tmp/e)"; fi
done

head_ "2. Placeholder guard (a half-configured run must abort)"
cp env.example /tmp/env.placeholder
cat > /tmp/guard.sh <<'EOF'
KIT_DIR=/tmp/kit
. /tmp/kit/lib.sh
load_env
require_real APP_PRIVATE_IP PUBLIC_HOSTNAME
echo "GUARD DID NOT FIRE"
EOF
mkdir -p /tmp/kit && cp lib.sh /tmp/kit/ && cp env.example /tmp/kit/env
if bash /tmp/guard.sh 2>&1 | grep -q 'still the example value'; then
  ok "refuses placeholder values"
else
  no "placeholder values were accepted — a run could publish an open proxy"
fi

# and that it accepts real ones
sed -e 's|^APP_PRIVATE_IP=.*|APP_PRIVATE_IP="10.20.30.40"|' \
    -e 's|^PUBLIC_HOSTNAME=.*|PUBLIC_HOSTNAME="app.rackspace.com"|' \
    -e 's|^COMPANY_CIDR=.*|COMPANY_CIDR="198.51.100.0/24"|' \
    -e 's|^BASTION_FLOATING_IP=.*|BASTION_FLOATING_IP="198.51.100.9"|' \
    env.example > /tmp/kit/env
if bash /tmp/guard.sh 2>&1 | grep -q 'GUARD DID NOT FIRE'; then
  ok "accepts configured values"
else
  no "rejected a valid config"
fi

head_ "3. IPv4 / CIDR validation"
cat > /tmp/ipt.sh <<'EOF'
KIT_DIR=/tmp/kit; . /tmp/kit/lib.sh
for good in 10.0.0.1 192.168.1.0/24 203.0.113.5; do valid_ipv4 "$good" || { echo "REJECTED $good"; exit 1; }; done
for bad in 10.0.0 300.1.1.1 10.0.0.1/33 not-an-ip ""; do valid_ipv4 "$bad" && { echo "ACCEPTED $bad"; exit 1; }; done
echo IPOK
EOF
if bash /tmp/ipt.sh 2>&1 | grep -q IPOK; then ok "accepts valid, rejects malformed"
else no "validation wrong: $(bash /tmp/ipt.sh 2>&1 | tail -1)"; fi

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
    if nginx -p "$T" -c "$T/nginx.conf" -t >/tmp/ng 2>&1; then ok "nginx accepts the rendered site"
    else no "nginx rejected it: $(grep -m1 emerg /tmp/ng)"; fi
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

head_ "8. Secrets never land in git"
grep -qx 'env' .gitignore 2>/dev/null && ok "env is gitignored" || no "env not gitignored"
grep -q 'oauth2-proxy.cfg' .gitignore 2>/dev/null \
  && ok "rendered oauth2-proxy.cfg ignored" || no "rendered config not ignored"
grep -RIl 'client_secret *= *"[^<]' --include='*.tmpl' --include='*.example' . 2>/dev/null | grep -q . \
  && no "a real-looking secret is committed" || ok "no literal secrets in tracked files"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
rm -rf /tmp/kit /tmp/guard.sh /tmp/ipt.sh /tmp/env.placeholder
exit $(( FAIL > 0 ))
