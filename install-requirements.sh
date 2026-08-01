#!/usr/bin/env bash
# Install everything the kit needs, so it runs unattended afterwards.
#
#   ./install-requirements.sh --check      report only, change nothing
#   sudo ./install-requirements.sh         install for this machine's role
#   sudo ./install-requirements.sh --sso   force the SSO proxy set
#
# Roles are detected, because the three machines need different things:
#   control  – your laptop: the OpenStack client, to create the jumphost
#   bastion  – the jumphost, tunnel path: sshd hardening tools
#   sso      – the jumphost, SSO path: nginx, certbot, oauth2-proxy
# Passing --control / --bastion / --sso overrides the guess.

. "$(cd "$(dirname "$0")" && pwd)/lib.sh" 2>/dev/null || { echo "run from the kit directory"; exit 1; }

OAUTH2_PROXY_VERSION="${OAUTH2_PROXY_VERSION:-v7.7.1}"

MODE=install; ROLE=""
for a in "$@"; do
  case "$a" in
    --check)   MODE=check ;;
    --control) ROLE=control ;;
    --bastion) ROLE=bastion ;;
    --sso)     ROLE=sso ;;
    --all)     ROLE=all ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

# ── what is this machine? ───────────────────────────────────────────────────
if [ -z "$ROLE" ]; then
  if [ -f /etc/nginx/sites-enabled/app-sso.conf ]; then ROLE=sso
  elif [ -f /etc/ssh/sshd_config.d/60-bastion.conf ]; then ROLE=bastion
  elif grep -qi microsoft /proc/version 2>/dev/null; then ROLE=control   # WSL
  else ROLE=control
  fi
fi

# package -> the command that proves it is present
CORE="curl:curl openssl:openssl gettext-base:envsubst jq:jq netcat-openbsd:nc ca-certificates:update-ca-certificates"
CONTROL="python3-openstackclient:openstack"
BASTION="openssh-server:sshd fail2ban:fail2ban-client ufw:ufw"
SSO="nginx:nginx certbot:certbot python3-certbot-nginx:certbot"

want_pkgs() {
  printf '%s ' $CORE
  case "$ROLE" in
    control) printf '%s ' $CONTROL ;;
    bastion) printf '%s ' $BASTION ;;
    sso)     printf '%s ' $SSO ;;
    all)     printf '%s %s %s ' $CONTROL $BASTION $SSO ;;
  esac
}

step "Role: $ROLE   (override with --control | --bastion | --sso | --all)"

MISSING=()
printf '\n  %-28s %s\n' "REQUIREMENT" "STATE"
printf '  %-28s %s\n' "---------------------------" "-----"
for pair in $(want_pkgs); do
  pkg="${pair%%:*}"; cmd="${pair##*:}"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf '  %-28s %s\n' "$pkg" "$(c_grn present)"
  else
    printf '  %-28s %s\n' "$pkg" "$(c_ylw missing)"
    MISSING+=("$pkg")
  fi
done

# oauth2-proxy is not in the distro repos; it ships as a release binary.
NEED_O2P=0
if [ "$ROLE" = sso ] || [ "$ROLE" = all ]; then
  if command -v oauth2-proxy >/dev/null 2>&1; then
    printf '  %-28s %s\n' "oauth2-proxy" "$(c_grn "present ($(oauth2-proxy --version 2>&1 | head -1))")"
  else
    printf '  %-28s %s\n' "oauth2-proxy" "$(c_ylw "missing (installs $OAUTH2_PROXY_VERSION)")"
    NEED_O2P=1
  fi
fi

if [ "${#MISSING[@]}" -eq 0 ] && [ "$NEED_O2P" -eq 0 ]; then
  printf '\n%s\n' "$(c_grn "Everything this machine needs is already installed.")"
  [ "$MODE" = check ] && exit 0
  exit 0
fi

if [ "$MODE" = check ]; then
  printf '\n  To install:  sudo ./install-requirements.sh --%s\n' "$ROLE"
  exit 1
fi

[ "$(id -u)" -eq 0 ] || die "run with sudo (or use --check)"
command -v apt-get >/dev/null 2>&1 || die "this installer expects apt (Debian/Ubuntu)"

confirm "Install ${#MISSING[@]} package(s)$([ $NEED_O2P = 1 ] && echo ' + oauth2-proxy') on $(hostname)?"

if [ "${#MISSING[@]}" -gt 0 ]; then
  step "apt"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING[@]}"
  c_grn "  installed: ${MISSING[*]}"
fi

if [ "$NEED_O2P" = 1 ]; then
  step "oauth2-proxy $OAUTH2_PROXY_VERSION"
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
  BASE="https://github.com/oauth2-proxy/oauth2-proxy/releases/download/$OAUTH2_PROXY_VERSION"
  TAR="oauth2-proxy-${OAUTH2_PROXY_VERSION}.linux-${ARCH}.tar.gz"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

  curl -fsSL "$BASE/$TAR" -o "$TMP/$TAR" || die "download failed: $BASE/$TAR"
  # Verify against the checksums published with that same release rather than a
  # hash hardcoded here, which nobody would ever re-check.
  if curl -fsSL "$BASE/checksums.txt" -o "$TMP/checksums.txt" 2>/dev/null; then
    ( cd "$TMP" && grep " $TAR\$" checksums.txt | sha256sum -c - ) \
      || die "checksum mismatch — refusing to install"
    c_grn "  checksum verified"
  else
    c_ylw "  no checksums.txt in that release — install not verified"
    confirm "  Continue anyway?"
  fi

  tar -xzf "$TMP/$TAR" -C "$TMP"
  install -m 755 "$TMP"/oauth2-proxy-*/oauth2-proxy /usr/local/bin/oauth2-proxy
  c_grn "  /usr/local/bin/oauth2-proxy  ($(oauth2-proxy --version 2>&1 | head -1))"
fi

step "Re-checking"
exec "$0" --check "--$ROLE"
