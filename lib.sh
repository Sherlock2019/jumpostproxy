#!/usr/bin/env bash
# Shared helpers. Sourced by every script in this kit.

set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
c_dim()  { printf '\033[2m%s\033[0m\n' "$*"; }
die()    { c_red "ERROR: $*" >&2; exit 1; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# Load ./env, or fail with instructions rather than half-running.
load_env() {
  local f="$KIT_DIR/env"
  [ -f "$f" ] || die "no $f — run: cp env.example env && chmod 600 env && \$EDITOR env"
  # shellcheck disable=SC1090
  . "$f"
}

# Refuse to act on values that are still placeholders. Catches the classic
# "ran the script before editing the config" failure, which on the SSO path
# would otherwise publish an open proxy.
require_real() {
  local name val
  for name in "$@"; do
    val="${!name-}"
    [ -n "$val" ] || die "$name is empty in env"
    case "$val" in
      *'<'*'>'* | 0.0.0.0 | 10.0.0.0 | app.example.com | 203.0.113.0/24 | you@rackspace.com)
        die "$name is still the example value ($val) — edit env first" ;;
    esac
  done
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

confirm() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  printf '%s [y/N] ' "$1"
  read -r a </dev/tty || a=n
  case "$a" in [yY]*) return 0 ;; *) die "aborted" ;; esac
}

# Validate an IPv4 address or CIDR, so a typo fails here and not as a firewall
# rule that silently matches nothing.
valid_ipv4() {
  local ip="${1%%/*}" mask="${1#*/}" o
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<<"$ip"
  for o in "$a" "$b" "$c" "$d"; do [ "$o" -le 255 ] || return 1; done
  if [ "$1" != "$ip" ]; then [ "$mask" -ge 0 ] && [ "$mask" -le 32 ] || return 1; fi
  return 0
}
