#!/usr/bin/env bash
# Harden a FLEX VM into a tunnel-only jumphost.
#
# Run ON THE BASTION VM (the one holding the floating IP), as a sudo-capable user.
#
#   sudo ./setup-bastion.sh            # apply
#   ./setup-bastion.sh --check         # report only, change nothing
#
# What it produces: an account that can forward ONE port to ONE host and can do
# nothing else — no shell, no SFTP, no agent forwarding, no reaching any other
# machine on the tenant network. That last part is the whole point; a bastion
# that hands out a shell is just another server on the internet.

. "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"
load_env

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

require_real APP_PRIVATE_IP APP_PORT COMPANY_CIDR
valid_ipv4 "$APP_PRIVATE_IP" || die "APP_PRIVATE_IP is not a valid IPv4: $APP_PRIVATE_IP"
valid_ipv4 "$COMPANY_CIDR"   || die "COMPANY_CIDR is not a valid CIDR: $COMPANY_CIDR"

SSHD_DROPIN=/etc/ssh/sshd_config.d/60-bastion.conf

report() {
  step "Current state"
  printf '  tunnel account %-14s : %s\n' "$BASTION_USER" \
    "$(id -u "$BASTION_USER" >/dev/null 2>&1 && echo present || echo missing)"
  printf '  sshd drop-in                 : %s\n' \
    "$([ -f "$SSHD_DROPIN" ] && echo present || echo missing)"
  printf '  authorized_keys entries      : %s\n' \
    "$(wc -l < "/home/$BASTION_USER/.ssh/authorized_keys" 2>/dev/null || echo 0)"
  printf '  ufw                          : %s\n' \
    "$(command -v ufw >/dev/null && ufw status 2>/dev/null | head -1 || echo 'not installed')"
  printf '  fail2ban                     : %s\n' \
    "$(systemctl is-active fail2ban 2>/dev/null || echo inactive)"
  printf '  app reachable from here      : '
  if command -v nc >/dev/null && nc -z -w3 "$APP_PRIVATE_IP" "$APP_PORT" 2>/dev/null; then
    c_grn "yes ($APP_PRIVATE_IP:$APP_PORT)"
  else
    c_red "NO — the bastion itself cannot reach the app; fix that first"
  fi
}

if [ "$CHECK_ONLY" = 1 ]; then report; exit 0; fi
[ "$(id -u)" -eq 0 ] || die "run with sudo"

step "Plan"
cat <<PLAN
  tunnel account : $BASTION_USER   (no shell, no password)
  may forward to : $APP_PRIVATE_IP:$APP_PORT   and nothing else
  ssh reachable  : $COMPANY_CIDR only
PLAN
confirm "Apply this to $(hostname)?"

step "Creating the tunnel account"
if ! id -u "$BASTION_USER" >/dev/null 2>&1; then
  # /usr/sbin/nologin: this account exists to hold a key and forward a port.
  useradd --create-home --shell /usr/sbin/nologin "$BASTION_USER"
  c_grn "  created $BASTION_USER"
else
  c_dim "  $BASTION_USER already exists"
fi
passwd -l "$BASTION_USER" >/dev/null      # no password login, ever
install -d -m 700 -o "$BASTION_USER" -g "$BASTION_USER" "/home/$BASTION_USER/.ssh"
touch "/home/$BASTION_USER/.ssh/authorized_keys"
chown "$BASTION_USER:$BASTION_USER" "/home/$BASTION_USER/.ssh/authorized_keys"
chmod 600 "/home/$BASTION_USER/.ssh/authorized_keys"

step "Hardening sshd"
install -d -m 755 /etc/ssh/sshd_config.d
cat > "$SSHD_DROPIN" <<EOF
# Managed by junphostrain/bastion/setup-bastion.sh — edit env, re-run.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
X11Forwarding no
AllowAgentForwarding no
PermitTunnel no
ClientAliveInterval 30
ClientAliveCountMax 4
MaxAuthTries 3

# The tunnel account: forwarding only, and only to the app.
Match User $BASTION_USER
    AllowTcpForwarding local
    AllowAgentForwarding no
    X11Forwarding no
    PermitOpen $APP_PRIVATE_IP:$APP_PORT
    ForceCommand echo 'This account is for port forwarding only.'; sleep infinity
EOF
chmod 644 "$SSHD_DROPIN"

# Never reload a config that will not parse — that locks you out of the VM.
if sshd -t; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
  c_grn "  sshd config valid, reloaded"
else
  rm -f "$SSHD_DROPIN"
  die "sshd config rejected — drop-in removed, nothing changed"
fi

step "Firewall"
if command -v ufw >/dev/null 2>&1; then
  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow from "$COMPANY_CIDR" to any port "$BASTION_SSH_PORT" proto tcp >/dev/null
  ufw --force enable >/dev/null
  c_grn "  ssh allowed from $COMPANY_CIDR only"
else
  c_ylw "  ufw not installed — restrict port $BASTION_SSH_PORT in the OpenStack security group instead"
fi

step "Brute-force protection"
if command -v apt-get >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban >/dev/null 2>&1 \
    && systemctl enable --now fail2ban >/dev/null 2>&1 \
    && c_grn "  fail2ban active" || c_ylw "  fail2ban not installed (optional)"
fi

report
step "Next"
cat <<NEXT
  Add an engineer:   sudo ./bastion/add-engineer.sh alice ~/keys/alice.pub
  They then run:     ./bastion/tunnel.sh
  And open:          http://localhost:$APP_PORT
NEXT
