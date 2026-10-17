#!/bin/bash
# Runs inside the container, started by vpn-lxc.sh on the Proxmox host.
# Prints "STEP/WARN/FAIL/RESULT text" lines that the host draws as a checklist.
umask 022   # the host script runs with 077 and pct exec passes it on
set -uo pipefail
S=/root/.vpnguard-stage
cfg()  { sed -n "s/^$1=//p" "$S/vpnguard.env" "$S/apply.env" 2>/dev/null | head -n 1; }
step() { printf 'STEP %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; exit 1; }

ROLE=$(cfg ROLE); PROTO=$(cfg PROTO); VPN_IF=$(cfg VPN_IF); UNIT=$(cfg TUNNEL_UNIT)
APPS=$(cfg APPS); PF_MODE=$(cfg PF_MODE); PF_PORT=$(cfg PF_PORT)
DNS_PRIMARY=$(cfg DNS_PRIMARY); RETIRE=$(cfg RETIRE_LEGACY)
QBIT_SYNC=$(cfg QBIT_SYNC); KEEP_CRED=$(cfg KEEP_QBIT_CRED); VPNNET_IF=$(cfg VPNNET_IF)
FW_ONLY=$(cfg FW_ONLY)   # 1 = only reload the firewall / port forwarding, leave the tunnel running
BK=/etc/vpnguard/backup/$(date +%Y%m%d-%H%M%S)

nft -c -f "$S/vpnguard.nft" || fail "the generated firewall failed nft's check, nothing was changed"

# backups
install -d -m 700 /etc/vpnguard /etc/vpnguard/backup "$BK"
for f in /etc/wireguard/wg0.conf /etc/openvpn/client/vpnguard.conf /etc/nftables.conf /etc/resolv.conf \
         /etc/vpnguard/vpnguard.env /etc/vpnguard/vpnguard.nft /etc/dnsmasq.d/vpnguard.conf \
         /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
    [ -e "$f" ] && cp -aL "$f" "$BK/"
done
command -v iptables-save  >/dev/null 2>&1 && iptables-save  > "$BK/iptables.save"  2>/dev/null
command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > "$BK/ip6tables.save" 2>/dev/null
step "backed up the current setup"

# files
install -m 600 "$S/vpnguard.env" /etc/vpnguard/vpnguard.env
install -m 600 "$S/vpnguard.nft" /etc/vpnguard/vpnguard.nft
install -m 755 "$S/nftables.conf" /etc/nftables.conf
install -d -m 755 /etc/dhcp/dhclient-enter-hooks.d
install -m 644 "$S/dhclient-vpnguard" /etc/dhcp/dhclient-enter-hooks.d/vpnguard
install -d -m 755 /etc/systemd/system/nftables.service.d
install -m 644 "$S/dropin-nftables.conf" /etc/systemd/system/nftables.service.d/vpnguard.conf
for f in vpn-status vpnguard-dns vpnguard-switch vpnguard-ovpn-up vpnguard-qbit-port vpnguard-natpmp; do
    install -m 755 "$S/$f" "/usr/local/sbin/$f"
done
if [ "$FW_ONLY" != 1 ]; then
    rm -rf /etc/vpnguard/slots
    install -d -m 700 /etc/vpnguard/slots
    for f in "$S"/slot-*; do
        [ -e "$f" ] || continue
        install -m 600 "$f" "/etc/vpnguard/slots/${f##*/slot-}"
    done
fi

# one target that means "the tunnel is up", whatever the protocol
cat > /etc/systemd/system/vpnguard-tunnel.target <<EOF
[Unit]
Description=VPN tunnel is up (vpn-lxc.sh)
BindsTo=$UNIT
PartOf=$UNIT
After=$UNIT
Wants=$APPS$([ "$PF_MODE" = natpmp ] && echo " vpnguard-natpmp.service")
EOF
if [ "$PROTO" = openvpn ]; then
    install -m 644 "$S/vpnguard-openvpn.service" /etc/systemd/system/vpnguard-openvpn.service
    if systemctl is-enabled --quiet wg-quick@wg0 2>/dev/null || systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        systemctl disable --now wg-quick@wg0 >/dev/null 2>&1
        step "switched from WireGuard to OpenVPN"
    fi
    rm -rf /etc/systemd/system/wg-quick@wg0.service.d
else
    install -d -m 755 "/etc/systemd/system/wg-quick@$VPN_IF.service.d"
    printf '# vpn-lxc.sh: the firewall is always up before the tunnel.\n[Unit]\nRequires=nftables.service\nAfter=nftables.service\nWants=vpnguard-tunnel.target\n' \
        > "/etc/systemd/system/wg-quick@$VPN_IF.service.d/vpnguard.conf"
    if [ -e /etc/systemd/system/vpnguard-openvpn.service ]; then
        systemctl disable --now vpnguard-openvpn >/dev/null 2>&1
        rm -f /etc/systemd/system/vpnguard-openvpn.service /etc/openvpn/client/vpnguard.conf
        step "switched from OpenVPN to WireGuard"
    fi
fi

# apps: only while the tunnel is up (tunnel role)
for dd in /etc/systemd/system/*.service.d/vpnguard-app.conf; do
    [ -e "$dd" ] || continue
    u=$(basename "$(dirname "$dd")" .d)
    case " $APPS " in *" $u "*) ;; *) rm -f "$dd"; rmdir "$(dirname "$dd")" 2>/dev/null; step "untied $u from the VPN" ;; esac
done
for a in $APPS; do
    install -d -m 755 "/etc/systemd/system/$a.d"
    printf '# vpn-lxc.sh: only run while the VPN tunnel is up.\n[Unit]\nBindsTo=vpnguard-tunnel.target\nAfter=vpnguard-tunnel.target\nPartOf=vpnguard-tunnel.target\n' \
        > "/etc/systemd/system/$a.d/vpnguard-app.conf"
done

if [ -f "$S/qbit.env" ]; then install -m 600 "$S/qbit.env" /etc/vpnguard/qbit.env
elif [ "$KEEP_CRED" != 1 ]; then rm -f /etc/vpnguard/qbit.env; fi

if [ "$PF_MODE" = natpmp ]; then
    install -m 644 "$S/vpnguard-natpmp.service" /etc/systemd/system/vpnguard-natpmp.service
elif [ -e /etc/systemd/system/vpnguard-natpmp.service ]; then
    systemctl disable --now vpnguard-natpmp >/dev/null 2>&1
    rm -f /etc/systemd/system/vpnguard-natpmp.service /run/vpnguard-pf-port
    step "NAT-PMP port forwarding turned off"
fi

if [ "$ROLE" = gateway ]; then
    printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.disable_ipv6 = 1\n' > /etc/sysctl.d/99-vpnguard.conf
    sysctl -q -p /etc/sysctl.d/99-vpnguard.conf >/dev/null 2>&1 || sysctl -q -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] || fail "could not turn on IP forwarding"
    install -d -m 755 /etc/dnsmasq.d
    install -m 644 "$S/dnsmasq.conf" /etc/dnsmasq.d/vpnguard.conf
    [ -f /etc/vpnguard-upstream.conf ] || : > /etc/vpnguard-upstream.conf
    chmod 644 /etc/vpnguard-upstream.conf
    step "routing for the VPN network ($VPNNET_IF) is on"
fi
systemctl daemon-reload

# firewall first: from here on nothing leaves except through the tunnel
systemctl enable nftables >/dev/null 2>&1
if [ "$FW_ONLY" = 1 ]; then
    # restarting the service would restart the tunnel unit that requires it: swap the rules in place instead (one atomic step)
    nft -f /etc/nftables.conf || fail "the firewall did not load, the previous rules are still active"
else
    systemctl restart nftables || fail "the firewall did not load: journalctl -u nftables"
fi
nft list table inet vpnguard >/dev/null 2>&1 || fail "the firewall table is missing after loading"
step "kill switch firewall active (default-deny)"

if [ "$RETIRE" = 1 ] && [ "$FW_ONLY" != 1 ]; then
    for t in iptables ip6tables; do
        command -v "$t" >/dev/null 2>&1 || continue
        "$t" -F; "$t" -X
        for c in INPUT FORWARD OUTPUT; do "$t" -P "$c" ACCEPT; done
    done
    for f in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do [ -f "$f" ] && mv "$f" "$f.vpnguard-disabled"; done
    step "old iptables rules retired"
fi

if [ "$FW_ONLY" != 1 ]; then
# swap the tunnel
for a in $APPS; do systemctl stop "$a" 2>/dev/null; done
systemctl stop vpnguard-natpmp 2>/dev/null
systemctl stop "$UNIT" 2>/dev/null
ip link del "$VPN_IF" 2>/dev/null
if [ "$PROTO" = openvpn ]; then
    install -d -m 700 /etc/openvpn/client
    install -m 600 /etc/vpnguard/slots/primary.conf /etc/openvpn/client/vpnguard.conf
else
    install -d -m 700 /etc/wireguard
    install -m 600 /etc/vpnguard/slots/primary.conf "/etc/wireguard/$VPN_IF.conf"
fi
echo primary > /etc/vpnguard/active-slot

if [ "$ROLE" = gateway ]; then
    printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf.vpnguard && mv -f /etc/resolv.conf.vpnguard /etc/resolv.conf
    # shellcheck disable=SC2086
    [ -n "$DNS_PRIMARY" ] && /usr/local/sbin/vpnguard-dns $DNS_PRIMARY
    systemctl enable dnsmasq >/dev/null 2>&1
    systemctl restart dnsmasq || fail "dnsmasq did not start: journalctl -u dnsmasq"
    step "DNS and DHCP for the VPN network running"
elif [ -n "$DNS_PRIMARY" ]; then
    # shellcheck disable=SC2086
    /usr/local/sbin/vpnguard-dns $DNS_PRIMARY
fi

systemctl enable "$UNIT" >/dev/null 2>&1
if ! timeout 75 systemctl start "$UNIT"; then
    fail "the tunnel did not come up: journalctl -u $UNIT"
fi
up=0
for _ in $(seq 1 25); do
    timeout 4 getent hosts example.com >/dev/null 2>&1 && dns_ok=1 || dns_ok=0
    if [ "$PROTO" = wireguard ]; then
        t=$(wg show "$VPN_IF" latest-handshakes 2>/dev/null | awk 'NR == 1 {print $2}')
        [ "${t:-0}" -gt 0 ] 2>/dev/null && [ "$dns_ok" = 1 ] && { up=1; break; }
    else
        ip link show "$VPN_IF" >/dev/null 2>&1 && [ "$dns_ok" = 1 ] && { up=1; break; }
    fi
    sleep 1
done
if [ "$up" = 1 ]; then step "tunnel up, DNS answers through it"
elif ! systemctl is-active --quiet "$UNIT"; then
    fail "the tunnel service is not running: journalctl -u $UNIT"
else warn "tunnel started, but no traffic through it yet"; fi
systemctl start vpnguard-tunnel.target 2>/dev/null

for a in $APPS; do
    if systemctl start "$a"; then step "started ${a%.service}"
    else warn "${a%.service} did not start: journalctl -u $a"; fi
done
fi   # FW_ONLY

case $PF_MODE in
    static)
        step "port $PF_PORT forwarded"
        if [ "$QBIT_SYNC" = 1 ]; then
            ok=0
            for _ in $(seq 1 10); do
                /usr/local/sbin/vpnguard-qbit-port "$PF_PORT" >/dev/null 2>&1 && { ok=1; break; }
                sleep 2
            done
            if [ "$ok" = 1 ]; then step "qBittorrent now listens on $PF_PORT"
            else warn "could not set qBittorrent's port (check the WebUI login)"; fi
        fi
        ;;
    natpmp)
        systemctl enable vpnguard-natpmp >/dev/null 2>&1
        systemctl restart vpnguard-natpmp
        port=""
        for _ in $(seq 1 25); do port=$(cat /run/vpnguard-pf-port 2>/dev/null); [ -n "$port" ] && break; sleep 1; done
        if [ -n "$port" ]; then step "forwarded port from the VPN: $port"; echo "RESULT PF_PORT=$port"
        else warn "no forwarded port yet: journalctl -u vpnguard-natpmp"; fi
        ;;
esac

echo "RESULT DNS=$(tr '\n' ' ' < /run/vpnguard-dns 2>/dev/null)"
echo "RESULT BACKUP=$BK"
rm -rf "$S"
