#!/bin/bash
# ╭──────────────────────────────────────────────────────────────╮
# │  vpn-lxc.sh · VPN for Proxmox containers                     │
# │                                                              │
# │  Two ways to put containers behind a VPN, with a kill switch │
# │    · per-container: each container runs its own tunnel      │
# │    · gateway: one VPN container + a private bridge; any      │
# │      container plugged into that bridge goes through it     │
# │                                                              │
# │  WireGuard or OpenVPN · Mullvad, Proton, AirVPN, any other   │
# │  port forwarding · dashboard · watchdog with failover ·      │
# │  saved config library · ntfy / Gotify notifications          │
# ╰──────────────────────────────────────────────────────────────╯
#
# Run on the PROXMOX HOST as root:
#   bash vpn-lxc.sh               the full-screen app
#   bash vpn-lxc.sh status CTID   status screen for one container
#   bash vpn-lxc.sh watchdog      one watchdog round (the timer runs this)
#   bash vpn-lxc.sh --help

[ -n "$BASH_VERSION" ] || exec bash "$0" "$@"
set -o pipefail
umask 077
export LC_ALL=C.UTF-8

VERSION="2.0"
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
ETC=${VPNLXC_ETC:-/etc/vpn-lxc}
VARD=${VPNLXC_VAR:-/var/lib/vpn-lxc}
IFACES_FILE=${VPNLXC_IFACES:-/etc/network/interfaces}
LIB=$ETC/library
REG=$ETC/registry
SETTINGS=$ETC/settings.env
STAGE_CT=/root/.vpnguard-stage
ANIM=${VPNLXC_ANIM:-1}

