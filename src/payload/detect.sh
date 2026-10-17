#!/bin/bash
umask 022   # the host script runs with 077 and pct exec passes it on
export LC_ALL=C
have() { command -v "$1" >/dev/null 2>&1; }
. /etc/os-release 2>/dev/null
echo "OS_ID=${ID:-unknown}"
echo "OS_LIKE=${ID_LIKE:-}"
echo "OS_NAME=${PRETTY_NAME:-unknown}"
missing=""
for c in wg wg-quick openvpn nft curl ip ss natpmpc dnsmasq; do have "$c" || missing="$missing $c"; done
echo "MISSING=${missing# }"
if have ip; then
    lan_if=$(ip -4 route show default table main 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i+1); exit}}')
    [ -z "$lan_if" ] && lan_if=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2; exit}')
    echo "LAN_IF=$lan_if"
    if [ -n "$lan_if" ]; then
        echo "LAN_IP=$(ip -4 -o addr show dev "$lan_if" 2>/dev/null | awk '{print $4; exit}')"
        echo "LAN_NET=$(ip -4 route show dev "$lan_if" scope link 2>/dev/null | awk '{print $1; exit}')"
    fi
    if ip link add vgtest0 type wireguard 2>/dev/null; then ip link del vgtest0; echo "WG_KERNEL=1"; else echo "WG_KERNEL=0"; fi
fi
[ -c /dev/net/tun ] && echo "HAS_TUN=1"
[ -f /etc/wireguard/wg0.conf ] && echo "HAS_WGCONF=1"
[ -f /etc/openvpn/client/vpnguard.conf ] && echo "HAS_OVPNCONF=1"
if have ss; then
    ports=$(ss -Htln 2>/dev/null | awk '{print $4}' | grep -v '%' | grep -Ev '^(127\.|\[::1\])' | sed -E 's/.*:([0-9]+)$/\1/' | sort -un | tr '\n' ' ')
    echo "LISTEN_TCP=${ports% }"
fi
if have systemctl; then
    svcs=$(systemctl list-units --type=service --all --plain --no-legend --no-pager 2>/dev/null | awk '{print $1}' \
        | grep -Ei '^(qbittorrent|transmission|deluge|rtorrent|sabnzbd|nzbget|prowlarr|jackett|flaresolverr|sonarr|radarr|lidarr|readarr|bazarr|autobrr|aria2)' \
        | tr '\n' ' ')
    echo "APP_SERVICES=${svcs% }"
fi
for f in /root/.config/qBittorrent/qBittorrent.conf /home/*/.config/qBittorrent/qBittorrent.conf /var/lib/qbittorrent*/.config/qBittorrent/qBittorrent.conf; do
    [ -f "$f" ] || continue
    echo "QBIT_CONF=$f"
    echo "QBIT_WEBUI_PORT=$(sed -n 's/^WebUI\\Port=//p' "$f" | head -n 1)"
    echo "QBIT_LISTEN_PORT=$(sed -n 's/^Session\\Port=//p' "$f" | head -n 1)"
    echo "QBIT_IFACE=$(sed -n 's/^Session\\Interface=//p' "$f" | head -n 1)"
    if grep -qi '^WebUI\\HTTPS\\Enabled=true' "$f"; then echo "QBIT_HTTPS=1"; else echo "QBIT_HTTPS=0"; fi
    if grep -qi '^WebUI\\LocalHostAuth=false' "$f"; then echo "QBIT_LOCALAUTH=0"; else echo "QBIT_LOCALAUTH=1"; fi
    break
done
have iptables  && echo "LEGACY_RULES=$(iptables -S 2>/dev/null | grep -c '^-A')"
have ip6tables && echo "LEGACY6_RULES=$(ip6tables -S 2>/dev/null | grep -c '^-A')"
[ -f /etc/vpnguard/qbit.env ] && echo "HAS_QBIT_CRED=1"
[ -f /etc/vpnguard/slots/backup.conf ] && echo "HAS_BACKUP=1"
if [ -f /etc/vpnguard/vpnguard.env ]; then
    echo "HAS_SETUP=1"
    sed -n 's/^\([A-Z][A-Z0-9_]*=\)/CUR_\1/p' /etc/vpnguard/vpnguard.env
fi
