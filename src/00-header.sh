#!/bin/bash
# ╭──────────────────────────────────────────────────────────────╮
# │  PVM · Proxmox VPN Manager                                   │
# │                                                              │
# │  Put containers behind a VPN, with a kill switch             │
# │    · gateways: one VPN container + a private bridge; any     │
# │      container plugged into that bridge goes through it      │
# │    · per-container: each container runs its own tunnel       │
# │                                                              │
# │  WireGuard or OpenVPN · Mullvad, Proton, AirVPN, any other   │
# │  port forwarding · dashboard · watchdog with failover ·      │
# │  saved config library · ntfy / Gotify notifications          │
# ╰──────────────────────────────────────────────────────────────╯
#
# Run on the PROXMOX HOST as root (the command is pvm or vpn, in any capitals):
#   pvm               the full-screen app
#   pvm status CTID   status screen for one container
#   pvm watchdog      one watchdog round (the timer runs this)
#   pvm --help

[ -n "$BASH_VERSION" ] || exec bash "$0" "$@"
set -o pipefail
umask 077
export LC_ALL=C.UTF-8

VERSION="3.1.0"
BIN_DIR=${PVM_BIN_DIR:-/usr/local/sbin}
REPO_RAW=${PVM_RAW:-https://raw.githubusercontent.com/Kalinewb/pvm}
REPO_API=${PVM_API:-https://api.github.com/repos/Kalinewb/pvm}
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
ETC=${PVM_ETC:-/etc/pvm}
VARD=${PVM_VAR:-/var/lib/pvm}
IFACES_FILE=${PVM_IFACES:-/etc/network/interfaces}
LIB=$ETC/library
REG=$ETC/registry
SETTINGS=$ETC/settings.env
STAGE_CT=/root/.vpnguard-stage
ANIM=${PVM_ANIM:-1}

