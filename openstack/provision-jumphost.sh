#!/usr/bin/env bash
# Create the one VM that holds the floating IP, plus a security group that lets
# it reach the app and lets only your company reach it.
#
#   source ~/openrc.sh
#   ./provision-jumphost.sh --plan     # print every command, run nothing
#   ./provision-jumphost.sh            # create
#   ./provision-jumphost.sh --show     # what exists now
#   ./provision-jumphost.sh --destroy  # remove what this script made
#
# Nothing here touches your app VM.

. "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"
load_env
need_cmd openstack

NAME="${JUMPHOST_NAME:-jumphost}"
SG_IN="$NAME-ingress"
MODE="${1:-create}"

[ -n "${OS_AUTH_URL:-}" ] || die "no OpenStack credentials in this shell — source your openrc first"

# Which ports the outside world may reach on the jumphost.
# SSH for the bastion path; 80/443 only if you are running the SSO proxy.
PORTS_SSH="$BASTION_SSH_PORT"
PORTS_WEB="${OPEN_WEB_PORTS:-80,443}"

show() {
  step "Current"
  openstack server list --name "$NAME" -f table 2>/dev/null || true
  openstack security group list --tags-any "" -f value -c Name 2>/dev/null | grep -x "$SG_IN" \
    && openstack security group rule list "$SG_IN" -f table
  openstack floating ip list -f table 2>/dev/null | head -20
}
[ "$MODE" = "--show" ] && { show; exit 0; }

require_real COMPANY_CIDR
valid_ipv4 "$COMPANY_CIDR" || die "COMPANY_CIDR invalid: $COMPANY_CIDR"
case "$COMPANY_CIDR" in
  0.0.0.0/0) die "COMPANY_CIDR is 0.0.0.0/0 — that publishes the jumphost to the internet" ;;
esac

if [ "$MODE" = "--destroy" ]; then
  confirm "Delete server '$NAME', its floating IP and '$SG_IN'?"
  fip="$(openstack server show "$NAME" -f json 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -1 || true)"
  openstack server delete "$NAME" --wait 2>/dev/null && c_grn "  server deleted" || true
  [ -n "$fip" ] && openstack floating ip delete "$fip" 2>/dev/null && c_grn "  floating ip $fip released" || true
  openstack security group delete "$SG_IN" 2>/dev/null && c_grn "  security group deleted" || true
  exit 0
fi

CMDS=$(cat <<CMD
openstack security group create $SG_IN --description "junphostrain: inbound to $NAME"
openstack security group rule create --proto tcp --dst-port $PORTS_SSH --remote-ip $COMPANY_CIDR $SG_IN
$(IFS=,; for p in $PORTS_WEB; do
    echo "openstack security group rule create --proto tcp --dst-port $p --remote-ip $COMPANY_CIDR $SG_IN"
  done)
openstack server create $NAME \\
  --image "$OS_IMAGE" --flavor "$OS_FLAVOR" --key-name "$OS_KEYPAIR" \\
  --network "$OS_TENANT_NETWORK" --security-group $SG_IN --wait
openstack floating ip create $OS_EXTERNAL_NETWORK
openstack server add floating ip $NAME <the-new-floating-ip>
CMD
)

if [ "$MODE" = "--plan" ]; then
  step "Would run"; printf '%s\n' "$CMDS" | sed 's/^/  /'
  c_dim "\n  Nothing was executed."
  exit 0
fi

step "Plan"
printf '%s\n' "$CMDS" | sed 's/^/  /'
c_ylw "\n  Inbound is restricted to $COMPANY_CIDR. The app VM is not touched."
confirm "Create these in project '${OS_PROJECT_NAME:-?}'?"

step "Security group"
openstack security group show "$SG_IN" >/dev/null 2>&1 \
  && c_dim "  $SG_IN exists" \
  || openstack security group create "$SG_IN" --description "junphostrain: inbound to $NAME" >/dev/null
add_rule() {
  openstack security group rule create --proto tcp --dst-port "$1" \
    --remote-ip "$COMPANY_CIDR" "$SG_IN" >/dev/null 2>&1 \
    && c_grn "  tcp/$1 from $COMPANY_CIDR" || c_dim "  tcp/$1 already present"
}
add_rule "$PORTS_SSH"
IFS=, read -ra WEB <<<"$PORTS_WEB"; for p in "${WEB[@]}"; do add_rule "$p"; done

step "Server"
if openstack server show "$NAME" >/dev/null 2>&1; then
  c_dim "  $NAME exists"
else
  openstack server create "$NAME" \
    --image "$OS_IMAGE" --flavor "$OS_FLAVOR" --key-name "$OS_KEYPAIR" \
    --network "$OS_TENANT_NETWORK" --security-group "$SG_IN" --wait >/dev/null
  c_grn "  created"
fi

step "Floating IP"
FIP="$(openstack floating ip create "$OS_EXTERNAL_NETWORK" -f value -c floating_ip_address)"
openstack server add floating ip "$NAME" "$FIP"
c_grn "  $FIP -> $NAME"

step "Next"
cat <<NEXT
  Put this in env:   BASTION_FLOATING_IP="$FIP"

  Then on the jumphost:
    bastion path : sudo ./bastion/setup-bastion.sh
    SSO path     : sudo ./sso-proxy/setup-sso-proxy.sh

  Verify it can see the app first:
    nc -vz $APP_PRIVATE_IP $APP_PORT
  If that fails, the app's own security group needs to allow $SG_IN.
NEXT
