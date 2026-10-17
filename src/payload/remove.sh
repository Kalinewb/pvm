#!/bin/bash
# remove.sh <restore_legacy 0|1> <stop_tunnel 0|1>
umask 022   # the host script runs with 077 and pct exec passes it on
set -uo pipefail
step() { printf 'STEP %s\n' "$*"; }
RESTORE_LEGACY=${1:-0}; STOP_TUNNEL=${2:-0}
cfg() { sed -n "s/^$1=//p" /etc/vpnguard/vpnguard.env 2>/dev/null | head -n 1; }
UNIT=$(cfg TUNNEL_UNIT); UNIT=${UNIT:-wg-quick@wg0.service}
BK=/etc/vpnguard/backup/$(date +%Y%m%d-%H%M%S)-removed
install -d -m 700 "$BK"
cp -a /etc/nftables.conf /etc/vpnguard/vpnguard.env /etc/vpnguard/vpnguard.nft "$BK/" 2>/dev/null
first=""
for d in /etc/vpnguard/backup/*/; do
    [ -d "$d" ] || continue
    case $d in *-removed/) continue ;; esac
    first=${d%/}; break
done
systemctl disable --now vpnguard-natpmp >/dev/null 2>&1
rm -f /etc/systemd/system/vpnguard-natpmp.service /run/vpnguard-pf-port
for dd in /etc/systemd/system/*.service.d/vpnguard-app.conf /etc/systemd/system/*.service.d/vpnguard.conf; do
    [ -e "$dd" ] || continue
    rm -f "$dd"; rmdir "$(dirname "$dd")" 2>/dev/null
done
if [ "$STOP_TUNNEL" = 1 ]; then
    systemctl disable --now "$UNIT" >/dev/null 2>&1
    systemctl disable --now dnsmasq >/dev/null 2>&1
    step "VPN tunnel stopped and disabled"
    # the rendered config holds the private key: put back whatever was there before us, or remove it
    for f in /etc/wireguard/wg0.conf /etc/openvpn/client/vpnguard.conf; do
        if [ -n "$first" ] && [ -f "$first/${f##*/}" ]; then cp -a "$first/${f##*/}" "$f"; else rm -f "$f"; fi
    done
    step "VPN config files removed (your own are back if you had any)"
fi
rm -f /etc/systemd/system/vpnguard-tunnel.target
[ "$STOP_TUNNEL" = 1 ] && rm -f /etc/systemd/system/vpnguard-openvpn.service
if [ -n "$first" ] && [ -f "$first/nftables.conf" ]; then
    cp -a "$first/nftables.conf" /etc/nftables.conf
else
    printf '#!/usr/sbin/nft -f\n' > /etc/nftables.conf
fi
systemctl daemon-reload
if [ -n "$first" ] && [ -s "$first/resolv.conf" ]; then
    cp -aL "$first/resolv.conf" /etc/resolv.conf.vpnguard && mv -f /etc/resolv.conf.vpnguard /etc/resolv.conf
    step "DNS settings put back"
fi
if [ "$RESTORE_LEGACY" = 1 ] && [ -n "$first" ] && [ -s "$first/iptables.save" ]; then
    iptables-restore < "$first/iptables.save" && step "restored your old iptables rules"
    for f in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
        [ -f "$f.vpnguard-disabled" ] && mv "$f.vpnguard-disabled" "$f"
    done
fi
nft delete table inet vpnguard 2>/dev/null && step "kill switch firewall removed"
rm -f /etc/dhcp/dhclient-enter-hooks.d/vpnguard /etc/vpnguard-upstream.conf
rm -f /etc/vpnguard/vpnguard.env /etc/vpnguard/vpnguard.nft /etc/vpnguard/qbit.env /etc/vpnguard/active-slot \
      /usr/local/sbin/vpn-status /usr/local/sbin/vpnguard-dns /usr/local/sbin/vpnguard-switch \
      /usr/local/sbin/vpnguard-ovpn-up /usr/local/sbin/vpnguard-qbit-port /usr/local/sbin/vpnguard-natpmp \
      /etc/sysctl.d/99-vpnguard.conf /etc/dnsmasq.d/vpnguard.conf
rm -rf /etc/vpnguard/slots
step "backups kept in /etc/vpnguard/backup"
