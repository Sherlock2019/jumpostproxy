#!/usr/bin/env bash
# Grant one engineer a tunnel to the app. Run ON THE BASTION with sudo.
#
#   sudo ./add-engineer.sh alice /tmp/alice.pub
#   sudo ./add-engineer.sh --list
#   sudo ./add-engineer.sh --revoke alice
#
# The key is written with an options prefix that removes every capability and
# then re-grants exactly one: forwarding to the app. Even if someone hands their
# key to a third party, that key still cannot get a shell or reach any other
# host on the tenant network.

. "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"
load_env
require_real APP_PRIVATE_IP APP_PORT

AK="/home/$BASTION_USER/.ssh/authorized_keys"

list() {
  step "Engineers with a tunnel"
  [ -s "$AK" ] || { c_dim "  (none)"; return; }
  awk '{
    for (i = 1; i <= NF; i++) if ($i ~ /^(ssh|ecdsa)-/) { t = i; break }
    printf "  %-22s %s...%s\n", $NF, substr($(t+1), 1, 12), substr($(t+1), length($(t+1)) - 7)
  }' "$AK"
}

case "${1:-}" in
  --list) list; exit 0 ;;
  --revoke)
    [ "$(id -u)" -eq 0 ] || die "run with sudo"
    who="${2:?usage: --revoke <name>}"
    [ -f "$AK" ] || die "no authorized_keys yet"
    cp "$AK" "$AK.bak.$(date +%s)"
    # Match on the trailing comment only, so a name cannot collide with base64.
    grep -v " ${who}\$" "$AK" > "$AK.tmp" && mv "$AK.tmp" "$AK"
    chown "$BASTION_USER:$BASTION_USER" "$AK"; chmod 600 "$AK"
    c_grn "revoked $who (backup kept alongside)"
    list; exit 0 ;;
esac

NAME="${1:?usage: add-engineer.sh <name> <path-to-public-key>}"
KEYFILE="${2:?usage: add-engineer.sh <name> <path-to-public-key>}"
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -f "$KEYFILE" ] || die "no such key file: $KEYFILE"
[[ "$NAME" =~ ^[a-z0-9._-]+$ ]] || die "name must be [a-z0-9._-]"

KEY="$(tr -d '\r' < "$KEYFILE" | grep -E '^(ssh|ecdsa)-' | head -1)"
[ -n "$KEY" ] || die "$KEYFILE does not look like an OpenSSH public key"
case "$KEY" in
  *PRIVATE*) die "that is a PRIVATE key — you want the .pub file" ;;
esac
KEYBODY="$(printf '%s' "$KEY" | awk '{print $2}')"
grep -qF "$KEYBODY" "$AK" 2>/dev/null && die "that key is already installed"

# restrict = disable everything (shell, agent, X11, pty, user-rc, forwarding).
# Then re-enable only what a tunnel needs, bound to one destination.
OPTS="restrict,port-forwarding,permitopen=\"$APP_PRIVATE_IP:$APP_PORT\""

printf '%s %s %s\n' "$OPTS" "$KEY" "$NAME" >> "$AK"
chown "$BASTION_USER:$BASTION_USER" "$AK"; chmod 600 "$AK"
c_grn "added $NAME"

step "Send them this"
cat <<INSTRUCTIONS
  ssh -N -L $APP_PORT:$APP_PRIVATE_IP:$APP_PORT \\
      -p $BASTION_SSH_PORT $BASTION_USER@$BASTION_FLOATING_IP

  then open  http://localhost:$APP_PORT

  Their key can do nothing else: no shell, no file transfer, no other host.
INSTRUCTIONS
list
