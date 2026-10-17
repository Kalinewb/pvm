#!/bin/bash
# client.sh <nameserver> <qbit_conf or -> : finish moving a container behind the VPN gateway.
umask 022   # the host script runs with 077 and pct exec passes it on
set -uo pipefail
step() { printf 'STEP %s\n' "$*"; }
NS=$1; QCONF=${2:--}
{
    echo "# --- BEGIN PVE ---"
    echo "nameserver $NS"
    echo "# --- END PVE ---"
} > /etc/resolv.conf.vpnguard
[ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
mv -f /etc/resolv.conf.vpnguard /etc/resolv.conf; chmod 644 /etc/resolv.conf
step "DNS now goes to the gateway ($NS)"
if [ "$QCONF" != - ] && [ -f "$QCONF" ]; then
    units=$(systemctl list-units --type=service --all --plain --no-legend 2>/dev/null | awk '{print $1}' | grep -i '^qbittorrent' || true)
    for u in $units; do systemctl stop "$u" 2>/dev/null; done
    sed -i -e 's/^Session\\Interface=.*/Session\\Interface=/' \
           -e 's/^Session\\InterfaceName=.*/Session\\InterfaceName=/' \
           -e 's/^Session\\InterfaceAddress=.*/Session\\InterfaceAddress=/' "$QCONF"
    for u in $units; do systemctl start "$u" 2>/dev/null; done
    step "qBittorrent no longer bound to a VPN interface (the gateway handles it)"
fi
