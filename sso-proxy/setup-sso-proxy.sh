#!/usr/bin/env bash
# Put company SSO in front of a private app. Run ON THE PROXY VM (the one with
# the floating IP), with sudo.
#
#   sudo ./setup-sso-proxy.sh --dry-run   # render everything, install nothing
#   sudo ./setup-sso-proxy.sh             # install and start
#   ./setup-sso-proxy.sh --verify         # test the running result
#
# MFA is not configured here. It is an Entra Conditional Access policy on the
# tenant; nothing in this kit implements or can bypass it.

. "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"
load_env

MODE="${1:-install}"
HERE="$(cd "$(dirname "$0")" && pwd)"
NGINX_SITE=/etc/nginx/sites-available/app-sso.conf
O2P_CFG=/etc/oauth2-proxy/oauth2-proxy.cfg
O2P_UNIT=/etc/systemd/system/oauth2-proxy.service

verify() {
  step "Verifying"
  local base="https://$PUBLIC_HOSTNAME"
  printf '  nginx config            : '
  nginx -t >/dev/null 2>&1 && c_grn ok || { c_red "invalid"; nginx -t; }
  printf '  oauth2-proxy service    : '
  systemctl is-active oauth2-proxy 2>/dev/null | grep -q active && c_grn active || c_red inactive
  printf '  app reachable privately : '
  curl -sk -o /dev/null -w '%{http_code}\n' --max-time 6 \
    "$APP_SCHEME://$APP_PRIVATE_IP:$APP_PORT/" 2>/dev/null || c_red "no answer"
  printf '  unauthenticated request : '
  local code
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "$base/" || echo 000)"
  case "$code" in
    302|303) c_grn "$code — redirected to sign-in (correct)" ;;
    200)     c_red "$code — the app answered WITHOUT auth. Stop and fix." ;;
    *)       c_ylw "$code" ;;
  esac
  printf '  header smuggling refused: '
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 \
          -H 'X-Forwarded-User: nobody@example.com' \
          -H 'X-Auth-Request-Email: nobody@example.com' "$base/" || echo 000)"
  case "$code" in
    302|303) c_grn "$code — still redirected (correct)" ;;
    200)     c_red "$code — a forged header got in. Stop and fix." ;;
    *)       c_ylw "$code" ;;
  esac
}

[ "$MODE" = "--verify" ] && { verify; exit 0; }

require_real APP_PRIVATE_IP APP_PORT PUBLIC_HOSTNAME \
             ENTRA_TENANT_ID ENTRA_CLIENT_ID ENTRA_CLIENT_SECRET
valid_ipv4 "$APP_PRIVATE_IP" || die "APP_PRIVATE_IP invalid: $APP_PRIVATE_IP"

DRY=0; [ "$MODE" = "--dry-run" ] && DRY=1
[ "$DRY" = 1 ] || [ "$(id -u)" -eq 0 ] || die "run with sudo (or --dry-run)"

TLS_CERT="${TLS_CERT:-/etc/letsencrypt/live/$PUBLIC_HOSTNAME/fullchain.pem}"
TLS_KEY="${TLS_KEY:-/etc/letsencrypt/live/$PUBLIC_HOSTNAME/privkey.pem}"

step "Plan"
cat <<PLAN
  public       : https://$PUBLIC_HOSTNAME   (DNS must point at $BASTION_FLOATING_IP)
  upstream app : $APP_SCHEME://$APP_PRIVATE_IP:$APP_PORT   (stays private)
  identity     : Entra tenant $ENTRA_TENANT_ID
  allowed      : @$ALLOWED_EMAIL_DOMAIN${ALLOWED_GROUP_ID:+ , group $ALLOWED_GROUP_ID}
  redirect URI : https://$PUBLIC_HOSTNAME/oauth2/callback
PLAN
c_ylw "  The redirect URI above must match the Entra app registration exactly."

RENDER_DIR="$HERE/.rendered"; mkdir -p "$RENDER_DIR"

# ── nginx site ──────────────────────────────────────────────────────────────
export APP_SCHEME APP_PRIVATE_IP APP_PORT PUBLIC_HOSTNAME TLS_CERT TLS_KEY
envsubst '${APP_SCHEME} ${APP_PRIVATE_IP} ${APP_PORT} ${PUBLIC_HOSTNAME} ${TLS_CERT} ${TLS_KEY}' \
  < "$HERE/nginx-app-sso.conf.tmpl" > "$RENDER_DIR/app-sso.conf"

# ── branded sign-in page ────────────────────────────────────────────────────
export APP_NAME="${APP_NAME:-Application}" ORG_NAME="${ORG_NAME:-Rackspace}" ALLOWED_EMAIL_DOMAIN
envsubst '${APP_NAME} ${ORG_NAME} ${ALLOWED_EMAIL_DOMAIN}' \
  < "$HERE/signin.html.tmpl" > "$RENDER_DIR/signin.html"

# A password field here would defeat the entire design, so fail loudly if one
# ever appears — including via a hand-edited template.
if grep -qiE 'type=["'"'"']?password|<input[^>]+pass' "$RENDER_DIR/signin.html"; then
  die "signin.html contains a password field — refusing to install. \
Credentials must be entered on login.microsoftonline.com, never here."
fi

# ── oauth2-proxy config ─────────────────────────────────────────────────────
COOKIE_SECRET="$(openssl rand -base64 32 | tr -- '+/' '-_')"
{
  cat <<CFG
provider        = "oidc"
oidc_issuer_url = "https://login.microsoftonline.com/$ENTRA_TENANT_ID/v2.0"
client_id       = "$ENTRA_CLIENT_ID"
client_secret   = "$ENTRA_CLIENT_SECRET"
redirect_url    = "https://$PUBLIC_HOSTNAME/oauth2/callback"
scope           = "openid email profile"

http_address  = "127.0.0.1:4180"
reverse_proxy = true

email_domains = ["$ALLOWED_EMAIL_DOMAIN"]
CFG
  [ -n "${ALLOWED_GROUP_ID:-}" ] && echo "allowed_groups = [\"$ALLOWED_GROUP_ID\"]"
  cat <<'CFG'

cookie_secure   = true
cookie_httponly = true
cookie_samesite = "lax"
cookie_expire   = "8h"
cookie_refresh  = "1h"

# Populates the X-Auth-Request-* response headers the nginx site captures.
# Without it the proxy authenticates but passes no identity through.
set_xauthrequest = true

# The app has no use for raw tokens and should not receive them: what it never
# holds cannot leak from it.
pass_access_token         = false
pass_authorization_header = false
pass_basic_auth           = false
skip_provider_button      = true
CFG
  echo "cookie_secret = \"$COOKIE_SECRET\""
} > "$RENDER_DIR/oauth2-proxy.cfg"
chmod 600 "$RENDER_DIR/oauth2-proxy.cfg"

if [ "$DRY" = 1 ]; then
  step "Rendered (not installed)"
  echo "  $RENDER_DIR/app-sso.conf"
  echo "  $RENDER_DIR/signin.html        (branded sign-in page, no password field)"
  echo "  $RENDER_DIR/oauth2-proxy.cfg   (contains a generated cookie secret)"
  c_dim "  Re-run without --dry-run to install."
  exit 0
fi

confirm "Install on $(hostname)?"

step "Packages"
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx certbot python3-certbot-nginx gettext-base >/dev/null
if ! command -v oauth2-proxy >/dev/null 2>&1; then
  c_ylw "  oauth2-proxy not found — install it from"
  c_ylw "  https://github.com/oauth2-proxy/oauth2-proxy/releases and re-run"
  die "oauth2-proxy is required"
fi

step "TLS certificate"
if [ ! -f "$TLS_CERT" ]; then
  certbot certonly --nginx -n --agree-tos -m "$LETSENCRYPT_EMAIL" -d "$PUBLIC_HOSTNAME" \
    || die "certbot failed — is DNS for $PUBLIC_HOSTNAME pointing at this VM, and port 80 open?"
fi
c_grn "  $TLS_CERT"

step "Installing"
install -D -m 600 "$RENDER_DIR/oauth2-proxy.cfg" "$O2P_CFG"
install -D -m 644 "$RENDER_DIR/app-sso.conf" "$NGINX_SITE"
install -D -m 644 "$RENDER_DIR/signin.html" /var/www/sso-signin/signin.html
ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/app-sso.conf
rm -f /etc/nginx/sites-enabled/default

# $connection_upgrade is referenced by the site; define it once, globally.
cat > /etc/nginx/conf.d/websocket-upgrade.conf <<'MAP'
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
MAP

cat > "$O2P_UNIT" <<UNIT
[Unit]
Description=oauth2-proxy (Entra ID in front of $PUBLIC_HOSTNAME)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$(command -v oauth2-proxy) --config=$O2P_CFG
Restart=always
RestartSec=3
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now oauth2-proxy

nginx -t || die "nginx config invalid — nothing reloaded"
systemctl reload nginx
c_grn "  installed"

verify

step "Next"
cat <<NEXT
  Share this link:  https://$PUBLIC_HOSTNAME
  Nobody needs a cloud credential. They sign in with their company account.
  Revoke someone by removing them from the Entra group — no VM changes.
NEXT
