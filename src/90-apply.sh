# ════════════════════════════════════════════════════════════
#  Generating files and applying them
# ════════════════════════════════════════════════════════════

endpoint_elems() {   # "ip:port/proto ..." → "ip . proto . port, ..." (deduplicated)
    local e out="" ip rest port proto
    for e in $(printf '%s\n' $* | sort -u); do
        ip=${e%%:*}; rest=${e#*:}; port=${rest%/*}; proto=${rest#*/}
        out="${out:+$out, }$ip . $proto . $port"
    done
    printf '%s' "$out"
}
csv() { local x=$*; printf '%s' "${x// /, }"; }

needed_pkgs() {   # needed_pkgs TARGET → apt package names that are missing
    local t=$1
    local m=" ${D[$t.MISSING]:-} " p=""
    if [ "${V[$t.primary.kind]}" = openvpn ]; then case $m in *" openvpn "*) p="$p openvpn" ;; esac
    else case $m in *" wg "*|*" wg-quick "*) p="$p wireguard-tools" ;; esac; fi
    case $m in *" nft "*) p="$p nftables" ;; esac
    case $m in *" curl "*) p="$p curl" ;; esac
    case $m in *" ip "*|*" ss "*) p="$p iproute2" ;; esac
    [ "${V[$t.pf_mode]:-none}" = natpmp ] && case $m in *" natpmpc "*) p="$p natpmpc" ;; esac
    [ "$t" = gw ] && case $m in *" dnsmasq "*) p="$p dnsmasq" ;; esac
    printf '%s' "${p# }"
}

install_pkgs() {   # install_pkgs CT "pkgs" : waits for DNS and retries, a fresh container is often not ready for a few seconds
    local ct=$1 try
    for try in 1 2 3; do
        cexec "$ct" bash -c 'for i in $(seq 1 20); do getent hosts deb.debian.org >/dev/null 2>&1 && exit 0; sleep 1; done; exit 0'
        # shellcheck disable=SC2086
        if cexec "$ct" env DEBIAN_FRONTEND=noninteractive apt-get -qq -o Acquire::Retries=5 update \
           && cexec "$ct" env DEBIAN_FRONTEND=noninteractive apt-get -y -qq -o Acquire::Retries=5 install --no-install-recommends $2; then
            return 0
        fi
        sleep 5
    done
    return 1
}

ensure_tun() {   # give a container /dev/net/tun (needs a restart)
    local ct=$1 n
    pct config "$ct" | grep -Eq '^(dev[0-9]+: /dev/net/tun|lxc.mount.entry: /dev/net)' && return 0
    for n in $(seq 0 9); do pct config "$ct" | grep -q "^dev$n:" || break; done
    if ! pct set "$ct" "--dev$n" /dev/net/tun 2>/dev/null; then
        printf 'lxc.cgroup2.devices.allow: c 10:200 rwm\nlxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file\n' >> "/etc/pve/lxc/$ct.conf" || return 1
    fi
    pct reboot "$ct" >/dev/null 2>&1 || { pct stop "$ct"; pct start "$ct"; }
    wait_ct_net "$ct"
}

wait_ct_net() {
    local ct=$1 i
    for i in $(seq 1 40); do
        ct_forget
        [ "$(ct_status "$ct")" = running ] && cexec "$ct" true >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

snapshot_ct() { pct snapshot "$1" "pvm_$(date +%Y%m%d_%H%M%S)" --description "before PVM $(date '+%F %T')"; }
# snapshots made before the rename are called vpnlxc_...; the newest of either kind wins
last_snapshot() { pct listsnapshot "$1" 2>/dev/null | grep -oE '(pvm|vpnlxc)_[0-9]{8}_[0-9]{6}' | sort -t_ -k2,3 | tail -n 1; }

# slots: rendered primary/backup configs (+ OpenVPN logins)
render_slots() {   # render_slots TARGET DIR
    local t=$1 d=$2 s user
    for s in primary backup; do
        [ -n "${V[$t.$s.kind]:-}" ] || continue
        if [ "${V[$t.$s.kind]}" = wireguard ]; then
            wg_render "${V[$t.$s.file]}" "$d/slot-$s.conf" "${V[$t.$s.pin]:-}" "${V[$t.$s.dns]}" || return 1
        else
            local authf=""
            [ "${V[$t.$s.auth]}" = 1 ] && authf="/etc/vpnguard/slots/$s.auth"
            ovpn_render "${V[$t.$s.file]}" "$d/slot-$s.conf" "${V[$t.$s.endpoints]}" "$authf" || return 1
            if [ -n "$authf" ]; then
                user=${V[$t.$s.user]}
                if [ "${V[$t.provider]}" = proton ] && [ "${V[$t.pf_mode]:-none}" = natpmp ] && [[ $user != *+pmp* ]]; then user="$user+pmp"; fi
                printf '%s\n%s\n' "$user" "${V[$t.$s.pass]}" > "$d/slot-$s.auth"
            fi
        fi
    done
}

stage_common() {   # stage_common TARGET DIR
    local t=$1 d=$2 f
    mkdir -p "$d"
    for f in apply.sh vpn-status vpnguard-dns vpnguard-switch vpnguard-ovpn-up vpnguard-qbit-port vpnguard-natpmp \
             vpnguard-natpmp.service vpnguard-openvpn.service nftables.conf dropin-nftables.conf dhclient-vpnguard; do
        cp "$STAGE/payload/$f" "$d/$f"
    done
    [ "${FW_ONLY:-0}" = 1 ] || render_slots "$t" "$d" || return 1
    {
        echo "RETIRE_LEGACY=$([ "${D[$t.LEGACY_RULES]:-0}${D[$t.LEGACY6_RULES]:-0}" != 00 ] && echo 1 || echo 0)"
        echo "QBIT_SYNC=${V[$t.qbit_sync]:-0}"
        echo "FW_ONLY=${FW_ONLY:-0}"
        echo "KEEP_QBIT_CRED=${V[$t.qbit_keep]:-0}"
    } > "$d/apply.env"
    if [ "${V[$t.qbit_sync]:-0}" = 1 ] && [ "${V[$t.qbit_keep]:-0}" != 1 ]; then
        {
            echo "QBIT_URL=${V[$t.qbit_url]}"
            if [ -n "${V[$t.qbit_user]:-}" ]; then echo "QBIT_USER=${V[$t.qbit_user]}"; echo "QBIT_PASS=${V[$t.qbit_pass]}"; fi
        } > "$d/qbit.env"
    fi
}

tunnel_vars() {   # sets PROTO VPN_IF UNIT for a target
    if [ "${V[$1.primary.kind]}" = openvpn ]; then PROTO=openvpn; VPN_IF=tun0; UNIT=vpnguard-openvpn.service
    else PROTO=wireguard; VPN_IF=wg0; UNIT=wg-quick@wg0.service; fi
}

stage_tunnel() {   # stage_tunnel TARGET DIR
    local t=$1 d=$2 PROTO VPN_IF UNIT
    tunnel_vars "$t"
    stage_common "$t" "$d" || return 1
    local lan=${D[$t.LAN_IF]} eps="${V[$t.primary.endpoints]} ${V[$t.backup.endpoints]:-}"
    local dhcp=0
    pct config "${V[$t.ct]}" | grep -E '^net[0-9]+:' | grep "name=$lan," | grep -q 'ip=dhcp' && dhcp=1
    {
        echo "# PVM settings ($(date '+%F %T')). Re-run PVM on the Proxmox host to change them."
        echo "VERSION=$VERSION"; echo "ROLE=tunnel"; echo "PROVIDER=${V[$t.provider]}"
        echo "PROTO=$PROTO"; echo "VPN_IF=$VPN_IF"; echo "TUNNEL_UNIT=$UNIT"
        echo "LAN_IF=$lan"; echo "LAN_NET=${V[lan_net]}"; echo "LAN_MODE=${V[$t.lan_mode]:-open}"; echo "LAN_TCP_PORTS=${V[$t.lan_tcp]}"; echo "LAN_OUT=${V[$t.lan_out]}"
        echo "DNS_PRIMARY=${V[$t.primary.dns]:-}"; echo "DNS_OVERRIDE="
        echo "ENDPOINTS=$(printf '%s\n' $eps | sort -u | tr '\n' ' ')"; echo "HOME_IP=${V[home_ip]:-}"; echo "APPS=${V[$t.apps]}"
        echo "PF_MODE=${V[$t.pf_mode]:-none}"; echo "PF_PORT=${V[$t.pf_port]:-}"; echo "PF_GATEWAY=${V[$t.pf_gw]:-}"
        echo "QBIT_URL=${V[$t.qbit_url]:-}"
    } > "$d/vpnguard.env"
    local out_elems="" e
    for e in ${V[$t.lan_out]}; do out_elems="${out_elems:+$out_elems, }${e%:*} . ${e##*:}"; done
    {
        echo '#!/usr/sbin/nft -f'
        echo "# VPN kill switch for CT ${V[$t.ct]} (${V[$t.name]}), generated by PVM $(date '+%F %T')."
        echo "# Default-deny for IPv4 and IPv6. Re-run PVM on the host to change it."
        echo "table inet vpnguard {}"
        echo "delete table inet vpnguard"
        echo "table inet vpnguard {"
        echo "	set endpoints {"
        echo "		type ipv4_addr . inet_proto . inet_service"
        echo "		elements = { $(endpoint_elems $eps) }"
        echo "	}"
        echo "	set lan_tcp {"
        echo "		type inet_service"
        [ -n "${V[$t.lan_tcp]}" ] && echo "		elements = { $(csv ${V[$t.lan_tcp]}) }"
        echo "	}"
        echo "	set lan_out {"
        echo "		type ipv4_addr . inet_service"
        [ -n "$out_elems" ] && echo "		elements = { $out_elems }"
        echo "	}"
        echo "	set pf_ports {"
        echo "		type inet_service"
        [ "${V[$t.pf_mode]:-none}" = static ] && echo "		elements = { ${V[$t.pf_port]} }"
        echo "	}"
        echo "	chain input {"
        echo "		type filter hook input priority filter; policy drop;"
        echo "		iifname \"lo\" accept"
        echo "		ct state invalid drop"
        echo "		ct state established,related accept"
        echo "		iifname \"$lan\" ip saddr . meta l4proto . th sport @endpoints accept"
        echo "		iifname \"$VPN_IF\" meta l4proto { tcp, udp } th dport @pf_ports accept"
        if [ "${V[$t.lan_mode]:-open}" = open ]; then
            echo "		iifname \"$lan\" ip saddr ${V[lan_net]} accept"
        else
            echo "		iifname \"$lan\" ip saddr ${V[lan_net]} tcp dport @lan_tcp accept"
            echo "		iifname \"$lan\" ip saddr ${V[lan_net]} icmp type echo-request accept"
        fi
        [ "$dhcp" = 1 ] && echo "		iifname \"$lan\" udp sport 67 udp dport 68 accept"
        echo "	}"
        echo "	chain forward {"
        echo "		type filter hook forward priority filter; policy drop;"
        echo "	}"
        echo "	chain output {"
        echo "		type filter hook output priority filter; policy drop;"
        echo "		oifname \"lo\" accept"
        echo "		ct state invalid drop"
        echo "		ct state established,related accept"
        echo "		oifname \"$VPN_IF\" accept"
        echo "		oifname \"$lan\" ip daddr . meta l4proto . th dport @endpoints accept"
        echo "		oifname \"$lan\" ip daddr . tcp dport @lan_out accept"
        if [ "${V[$t.lan_mode]:-open}" = open ]; then
            echo "		oifname \"$lan\" meta l4proto { tcp, udp } th dport { 53, 853 } drop"
            echo "		oifname \"$lan\" ip daddr ${V[lan_net]} accept"
        fi
        [ "$dhcp" = 1 ] && echo "		oifname \"$lan\" udp sport 68 udp dport 67 accept"
        echo "	}"
        echo "}"
    } > "$d/vpnguard.nft"
}

stage_gateway() {   # stage_gateway DIR
    local d=$1 PROTO VPN_IF UNIT
    tunnel_vars gw
    stage_common gw "$d" || return 1
    local eps="${V[gw.primary.endpoints]} ${V[gw.backup.endpoints]:-}" pre gwip c e publish="" pf_ip=""
    pre=$(net_prefix "${V[gw.net]}"); gwip="$pre.1"
    for c in ${V[gw.clients]}; do
        for e in ${V[c$c.publish]:-}; do publish="$publish ${e%%:*}:${V[c$c.ip]}:${e#*:}"; done
    done
    [ -n "${V[gw.pf_target]:-}" ] && pf_ip=${V[c${V[gw.pf_target]}.ip]:-}
    local dhcp=0; [ "${V[gw.lanaddr]:-}" = dhcp ] && dhcp=1
    [ "${V[gw.mode]}" = reconfig ] && [ "$(reg_get "${V[gw.ct]}" LAN_ADDR)" = dhcp ] && dhcp=1
    {
        echo "# PVM settings ($(date '+%F %T')). Re-run PVM on the Proxmox host to change them."
        echo "VERSION=$VERSION"; echo "ROLE=gateway"; echo "PROVIDER=${V[gw.provider]}"
        echo "PROTO=$PROTO"; echo "VPN_IF=$VPN_IF"; echo "TUNNEL_UNIT=$UNIT"
        echo "LAN_IF=eth0"; echo "LAN_NET=${V[lan_net]}"; echo "LAN_MODE=${V[gw.lan_mode]:-open}"; echo "VPNNET_IF=eth1"; echo "VPN_NET=${V[gw.net]}"; echo "GW_IP=$gwip"
        echo "DNS_PRIMARY=${V[gw.primary.dns]:-}"; echo "DNS_OVERRIDE="
        echo "ENDPOINTS=$(printf '%s\n' $eps | sort -u | tr '\n' ' ')"; echo "HOME_IP=${V[home_ip]:-}"; echo "APPS="
        echo "PUBLISH=$(echo $publish)"; echo "LAN_OUT=${V[gw.lan_out]:-}"
        echo "PF_MODE=${V[gw.pf_mode]:-none}"; echo "PF_PORT=${V[gw.pf_port]:-}"; echo "PF_GATEWAY=${V[gw.pf_gw]:-}"; echo "PF_TARGET=$pf_ip"
        echo "QBIT_URL=${V[gw.qbit_url]:-}"
    } > "$d/vpnguard.env"
    cat > "$d/dnsmasq.conf" <<EOF
# PVM: DNS (only through the tunnel) and DHCP for the VPN network
interface=eth1
listen-address=127.0.0.1
bind-dynamic
no-resolv
servers-file=/etc/vpnguard-upstream.conf
domain-needed
bogus-priv
cache-size=1000
dhcp-range=$pre.100,$pre.199,255.255.255.0,12h
dhcp-option=option:router,$gwip
dhcp-option=option:dns-server,$gwip
EOF
    local out_elems=""
    for e in ${V[gw.lan_out]:-}; do out_elems="${out_elems:+$out_elems, }${e%:*} . ${e##*:}"; done
    {
        echo '#!/usr/sbin/nft -f'
        echo "# VPN gateway kill switch, generated by PVM $(date '+%F %T')."
        echo "# The VPN network (${V[gw.net]} on eth1) can only leave through $VPN_IF."
        echo "table inet vpnguard {}"
        echo "delete table inet vpnguard"
        echo "table inet vpnguard {"
        echo "	set endpoints {"
        echo "		type ipv4_addr . inet_proto . inet_service"
        echo "		elements = { $(endpoint_elems $eps) }"
        echo "	}"
        echo "	set lan_out {"
        echo "		type ipv4_addr . inet_service"
        [ -n "$out_elems" ] && echo "		elements = { $out_elems }"
        echo "	}"
        echo "	set pf_ports {"
        echo "		type inet_service"
        [ "${V[gw.pf_mode]:-none}" = static ] && echo "		elements = { ${V[gw.pf_port]} }"
        echo "	}"
        echo "	chain prerouting {"
        echo "		type nat hook prerouting priority dstnat; policy accept;"
        for e in $publish; do
            local ext=${e%%:*} rest=${e#*:}
            echo "		iifname \"eth0\" ip saddr ${V[lan_net]} tcp dport $ext dnat ip to ${rest%%:*}:${rest#*:}"
        done
        [ -n "$pf_ip" ] && echo "		iifname \"$VPN_IF\" meta l4proto { tcp, udp } th dport @pf_ports dnat ip to $pf_ip"
        echo "	}"
        echo "	chain postrouting {"
        echo "		type nat hook postrouting priority srcnat; policy accept;"
        echo "		oifname \"$VPN_IF\" masquerade"
        echo "		oifname \"eth0\" ip saddr ${V[gw.net]} masquerade"
        echo "	}"
        echo "	chain input {"
        echo "		type filter hook input priority filter; policy drop;"
        echo "		iifname \"lo\" accept"
        echo "		ct state invalid drop"
        echo "		ct state established,related accept"
        echo "		iifname \"eth0\" ip saddr . meta l4proto . th sport @endpoints accept"
        echo "		iifname \"eth1\" ip saddr ${V[gw.net]} udp dport { 53, 67 } accept"
        echo "		iifname \"eth1\" ip saddr ${V[gw.net]} tcp dport 53 accept"
        echo "		iifname \"eth1\" udp sport 68 udp dport 67 accept"
        echo "		iifname \"eth1\" icmp type echo-request accept"
        if [ "${V[gw.lan_mode]:-open}" = open ]; then echo "		iifname \"eth0\" ip saddr ${V[lan_net]} accept"
        else echo "		iifname \"eth0\" ip saddr ${V[lan_net]} icmp type echo-request accept"; fi
        [ "$dhcp" = 1 ] && echo "		iifname \"eth0\" udp sport 67 udp dport 68 accept"
        echo "	}"
        echo "	chain forward {"
        echo "		type filter hook forward priority filter; policy drop;"
        echo "		ct state invalid drop"
        echo "		ct state established,related accept"
        echo "		iifname \"eth1\" ip saddr != ${V[gw.net]} drop"
        echo "		iifname \"eth1\" oifname \"$VPN_IF\" accept"
        echo "		iifname \"eth1\" oifname \"eth0\" ip daddr . tcp dport @lan_out accept"
        if [ "${V[gw.lan_mode]:-open}" = open ]; then
            echo "		iifname \"eth1\" oifname \"eth0\" meta l4proto { tcp, udp } th dport { 53, 853 } drop"
            echo "		iifname \"eth1\" oifname \"eth0\" ip daddr ${V[lan_net]} accept"
        fi
        echo "		iifname { \"eth0\", \"$VPN_IF\" } oifname \"eth1\" ct status dnat accept"
        echo "	}"
        echo "	chain output {"
        echo "		type filter hook output priority filter; policy drop;"
        echo "		oifname \"lo\" accept"
        echo "		ct state invalid drop"
        echo "		ct state established,related accept"
        echo "		oifname \"$VPN_IF\" accept"
        echo "		oifname \"eth0\" ip daddr . meta l4proto . th dport @endpoints accept"
        [ "${V[gw.lan_mode]:-open}" = open ] && echo "		oifname \"eth0\" ip daddr ${V[lan_net]} accept"
        echo "		oifname \"eth1\" accept"
        [ "$dhcp" = 1 ] && echo "		oifname \"eth0\" udp sport 68 udp dport 67 accept"
        echo "	}"
        echo "}"
    } > "$d/vpnguard.nft"
}

push_dir() {   # push_dir CT DIR
    local ct=$1 d=$2 f
    cexec "$ct" rm -rf "$STAGE_CT" && cexec "$ct" install -d -m 700 "$STAGE_CT" || return 1
    for f in "$d"/*; do
        [ -f "$f" ] || continue
        cpush "$ct" "$f" "$STAGE_CT/${f##*/}" 600 || return 1
    done
}

apply_in_ct() {   # apply_in_ct CT  (streams the checklist; RESULTS[] stays in this shell)
    RESULTS=()
    render_stream < <(cexec "$1" bash "$STAGE_CT/apply.sh" 2>&1; echo "RESULT __RC=$?")
    return "${RESULTS[__RC]:-1}"
}

section_head() { printf '\n  %s◆%s %s%s%s %s%s%s\n' "$PK" "$R" "$B" "$1" "$R" "$GR" "${2:-}" "$R"; }

install_watchdog() {
    [ "$(set_get WATCHDOG)" = 0 ] && return 0
    [ "$(readlink -f "$BIN_DIR/pvm" 2>/dev/null)" = "$SELF" ] || { install -m 755 "$SELF" "$BIN_DIR/pvm" && install_links; }
    cat > /etc/systemd/system/pvm-watchdog.service <<'EOF'
[Unit]
Description=PVM watchdog: checks VPN tunnels, restarts or fails over, notifies
After=pve-guests.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pvm watchdog
EOF
    cat > /etc/systemd/system/pvm-watchdog.timer <<'EOF'
[Unit]
Description=Run the PVM watchdog every 2 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload && systemctl enable --now pvm-watchdog.timer >/dev/null 2>&1
}

# ── per-container apply ─────────────────────────────────────
tunnel_apply() {
    FLOW="per-container setup"; CONTEXT=""; PAGE_TOTAL=0
    page "Applying" "Each container: snapshot, packages, files, then the firewall goes up before the tunnel does."
    V[home_ip]=$(home_ip)
    local t ct pk dir rc
    declare -gA RES=()
    for ((t = 1; t <= NT; t++)); do
        ct=${V[$t.ct]}
        section_head "CT $ct ${V[$t.name]}" "$(provider_label "${V[$t.provider]}") · ${V[$t.primary.kind]}"
        if [ "${V[snap]}" = y ]; then
            run_task "snapshot" snapshot_ct "$ct" || warn "no snapshot (storage without snapshot support?), file backups still happen"
        fi
        if [ "${V[$t.primary.kind]}" = openvpn ] && [ "${D[$t.HAS_TUN]:-}" != 1 ]; then
            run_task "adding /dev/net/tun (restarts the container)" ensure_tun "$ct" || { RES[$t]=fail; continue; }
        fi
        pk=$(needed_pkgs "$t")
        if [ -n "$pk" ]; then run_task "installing $pk" install_pkgs "$ct" "$pk" || { RES[$t]=fail; continue; }; fi
        dir="$STAGE/out$t"
        run_task "preparing the firewall and configs" stage_tunnel "$t" "$dir" || { RES[$t]=fail; continue; }
        run_task "copying files in" push_dir "$ct" "$dir" || { RES[$t]=fail; continue; }
        if [ -z "$(reg_get "$ct" ORIG_NS_SAVED)" ] && [ "$(reg_get "$ct" ROLE)" != client ]; then
            reg_set "$ct" ORIG_NS "$(pct config "$ct" | sed -n 's/^nameserver: //p')"; reg_set "$ct" ORIG_NS_SAVED 1
        fi
        [ -n "${V[$t.primary.dns]:-}" ] && pct set "$ct" --nameserver "${V[$t.primary.dns]}" >/dev/null 2>&1
        apply_in_ct "$ct"; rc=$?
        if [ "$rc" = 0 ]; then
            RES[$t]=ok
            local pushed; pushed=$(trim "${RESULTS[DNS]:-}")
            [ -z "${V[$t.primary.dns]:-}" ] && [ -n "$pushed" ] && pct set "$ct" --nameserver "$pushed" >/dev/null 2>&1
            reg_set "$ct" ROLE tunnel; reg_set "$ct" NAME "${V[$t.name]}"
            reg_set "$ct" FPS "$(echo ${V[$t.primary.fp]:-} ${V[$t.backup.fp]:-})"
            reg_set "$ct" PROVIDER "${V[$t.provider]}"; reg_set "$ct" PROTO "${V[$t.primary.kind]}"
        else
            RES[$t]=fail
        fi
    done
    echo
    run_task "watchdog timer on this host" install_watchdog
    tunnel_results
}

tunnel_results() {
    local t ct
    while true; do
        FLOW="per-container setup"; PAGE_TOTAL=0; CONTEXT=""
        page "Results" "A quick look at each container through its tunnel."
        run_task "checking the tunnels" brief_all
        for ((t = 1; t <= NT; t++)); do
            ct=${V[$t.ct]}
            if [ "${RES[$t]}" = ok ]; then
                local -A BR=()
                read_kv_into BR "" < "$STAGE/res/$t" 2>/dev/null
                if [ "${BR[TUNNEL]:-}" = up ] && [ -n "${BR[EXIT_IP]:-}" ]; then
                    ok "CT $ct ${V[$t.name]} · exit ${BR[EXIT_IP]} ${BR[CITY]:+(${BR[CITY]}, ${BR[COUNTRY]})}${BR[PF_PORT]:+ · port ${BR[PF_PORT]}}"
                else
                    warn "CT $ct ${V[$t.name]} · applied, but the tunnel isn't passing traffic yet"
                fi
            else
                bad "CT $ct ${V[$t.name]} · failed (the firewall stays closed, nothing leaks)"
            fi
            unset BR
        done
        echo
        local a
        pick a "What next?" "done" \
            "status|Full status screen|for one container" \
            "rollback|Roll back|restore a container's snapshot" \
            "done|Back to the main menu|" || return 0
        case $a in
            status)   pick_ct_from_targets ct && { cls; cexec "$ct" env FORCE_COLOR="$FANCY" /usr/local/sbin/vpn-status; pause; } ;;
            rollback) pick_ct_from_targets ct && rollback_ct "$ct" ;;
            done)     return 0 ;;
        esac
    done
}

brief_all() {
    local t
    mkdir -p "$STAGE/res"
    for ((t = 1; t <= NT; t++)); do
        [ "${RES[$t]}" = ok ] && cexec "${V[$t.ct]}" /usr/local/sbin/vpn-status --brief > "$STAGE/res/$t" 2>/dev/null &
    done
    wait
    return 0
}

pick_ct_from_targets() {
    local -n __out=$1
    local -a items=()
    local t
    for ((t = 1; t <= NT; t++)); do items+=("${V[$t.ct]}|CT ${V[$t.ct]} ${V[$t.name]}|${RES[$t]}"); done
    echo
    pick __out "Which container?" "${V[1.ct]}" "${items[@]}"
}

rollback_ct() {
    local ct=$1 snap a
    snap=$(last_snapshot "$ct")
    [ -n "$snap" ] || { bad "no pvm snapshot found for CT $ct"; pause; return; }
    yn a "Roll CT $ct back to $snap? (it restarts)" n || return
    [ "$a" = y ] || return
    run_task "rolling back CT $ct" bash -c "pct stop $ct >/dev/null 2>&1; pct rollback $ct $snap && pct start $ct" && reg_del "$ct"
    pause
}

# ── gateway apply ───────────────────────────────────────────
add_bridge() {
    local br=$1
    cp -a "$IFACES_FILE" "$IFACES_FILE.pvm.$(date +%Y%m%d-%H%M%S)" || return 1
    printf '\nauto %s\niface %s inet manual\n\tbridge-ports none\n\tbridge-stp off\n\tbridge-fd 0\n#VPN-only network (PVM)\n' "$br" "$br" >> "$IFACES_FILE"
    ifreload -a && ip link show "$br" >/dev/null
}

ensure_template() {
    local store=$1 tpl have arch
    umask 022   # the template cache is shared with Proxmox itself
    arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
    pveam update >/dev/null 2>&1
    # the list has an arm64 build of every template: it must match this host
    tpl=$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E "^debian-13-standard_.*_${arch}\.tar" | sort -V | tail -n 1)
    [ -z "$tpl" ] && tpl=$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E "^debian-12-standard_.*_${arch}\.tar" | sort -V | tail -n 1)
    have=$(pveam list "$store" 2>/dev/null | awk '{print $1}' | sed 's#.*/##' | grep -E "^debian-1[23]-standard_.*_${arch}\.tar" | sort -V | tail -n 1)
    if [ -n "$tpl" ] && ! pveam list "$store" 2>/dev/null | grep -q "$tpl"; then
        pveam download "$store" "$tpl" || { [ -n "$have" ] && tpl=$have || return 1; }
    fi
    [ -n "$tpl" ] || tpl=$have
    [ -n "$tpl" ] || { echo "no Debian template found (pveam available)"; return 1; }
    echo "$store:vztmpl/$tpl" > "$STAGE/template"
}

create_gateway() {
    local id=${V[gw.ct]} lan=${V[gw.lanaddr]} net0 net1 tpl
    tpl=$(cat "$STAGE/template")
    if [ "$lan" = dhcp ]; then net0="name=eth0,bridge=${V[gw.lan_bridge]},ip=dhcp,type=veth"
    else net0="name=eth0,bridge=${V[gw.lan_bridge]},ip=$lan,gw=${V[gw.lan_gw]},type=veth"; fi
    net1="name=eth1,bridge=${V[gw.bridge]},ip=$(net_prefix "${V[gw.net]}").1/24,type=veth"
    local -a args=("$id" "$tpl" --hostname "${V[gw.name]}" --arch "$(dpkg --print-architecture)" --memory 256 --swap 128 --cores 1
                   --rootfs "${V[gw.storage]}:2" --net0 "$net0" --net1 "$net1" --unprivileged 1
                   --features nesting=1 --onboot 1 --startup 'order=1,up=15' --ostype debian
                   --description "VPN gateway, managed by PVM")
    # this script runs with umask 077 to protect its secrets; a container created that way gets a root-only /etc
    umask 022
    if ! pct create "${args[@]}" --dev0 /dev/net/tun; then
        ct_exists "$id" && return 1
        pct create "${args[@]}" || return 1
        printf 'lxc.cgroup2.devices.allow: c 10:200 rwm\nlxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file\n' >> "/etc/pve/lxc/$id.conf"
    fi
    pct start "$id" && wait_ct_net "$id" || return 1
    local i
    for i in $(seq 1 30); do cexec "$id" getent hosts deb.debian.org >/dev/null 2>&1 && return 0; sleep 2; done
    echo "the new container has no internet access on your LAN"
    return 1
}

client_move() {   # client_move CT
    local c=$1
    local key=${V[c$c.netkey]} orig hw fw name newnet line k
    orig=$(pct config "$c" | sed -n "s/^$key: //p")
    reg_set "$c" ORIG_NET "$orig"; reg_set "$c" NETKEY "$key"
    [ -n "$(reg_get "$c" ORIG_NS_SAVED)" ] || { reg_set "$c" ORIG_NS "$(pct config "$c" | sed -n 's/^nameserver: //p')"; reg_set "$c" ORIG_NS_SAVED 1; }
    hw=$(tr ',' '\n' <<<"$orig" | grep '^hwaddr=')
    fw=$(tr ',' '\n' <<<"$orig" | grep '^firewall=')
    name=$(tr ',' '\n' <<<"$orig" | grep '^name='); name=${name:-name=eth0}
    newnet="$name,bridge=${V[gw.bridge]}${hw:+,$hw},ip=${V[c$c.ip]}/24,gw=$(net_prefix "${V[gw.net]}").1,type=veth${fw:+,$fw}"
    pct set "$c" "--$key" "$newnet" || return 1
    local extra=""
    while IFS= read -r line; do
        k=${line%%:*}
        [ "$k" = "$key" ] && continue
        extra="${extra:+$extra;}$line"
        pct set "$c" --delete "$k" || return 1
    done < <(pct config "$c" | grep -E '^net[0-9]+:')
    reg_set "$c" ORIG_EXTRA "$extra"
    pct set "$c" --nameserver "$(net_prefix "${V[gw.net]}").1"
}

client_detach() {   # client_detach CT : back to the network it had before
    local c=$1 key orig extra ns item
    key=$(reg_get "$c" NETKEY); orig=$(reg_get "$c" ORIG_NET); extra=$(reg_get "$c" ORIG_EXTRA); ns=$(reg_get "$c" ORIG_NS)
    [ -n "$key" ] && [ -n "$orig" ] || { echo "no saved network for CT $c"; return 1; }
    pct set "$c" "--$key" "$orig" || return 1
    if [ -n "$extra" ]; then
        local IFS=';'
        for item in $extra; do pct set "$c" "--${item%%: *}" "${item#*: }"; done
        unset IFS
    fi
    if [ -n "$ns" ]; then pct set "$c" --nameserver "$ns"; else pct set "$c" --delete nameserver; fi
    pct reboot "$c" >/dev/null 2>&1
    reg_del "$c"
}

gateway_apply() {
    FLOW="VPN gateway"; CONTEXT=""; PAGE_TOTAL=0
    page "Applying" "The gateway's firewall goes up before its tunnel, and containers only move once the gateway works."
    V[home_ip]=$(home_ip)
    local g=${V[gw.ct]} c rc
    if [ "${V[gw.mode]}" = create ]; then
        section_head "Proxmox host"
        run_task "adding bridge ${V[gw.bridge]}" add_bridge "${V[gw.bridge]}" || { pause; return 1; }
        run_task "fetching the Debian template" ensure_template "${V[gw.tstore]}" || { pause; return 1; }
        run_task "creating CT $g ${V[gw.name]}" create_gateway || { pause; return 1; }
        detect_task "looking inside the new container" gw "$g" || { pause; return 1; }
    elif [ "${V[snap]}" = y ]; then
        section_head "Snapshots"
        run_task "CT $g ${V[gw.name]}" snapshot_ct "$g" || warn "no snapshot for the gateway"
    fi

    section_head "Gateway CT $g ${V[gw.name]}" "$(provider_label "${V[gw.provider]}") · ${V[gw.primary.kind]}"
    if [ "${V[gw.primary.kind]}" = openvpn ] && [ "${D[gw.HAS_TUN]:-}" != 1 ]; then
        run_task "adding /dev/net/tun (restarts the gateway)" ensure_tun "$g" || { pause; return 1; }
    fi
    local pk; pk=$(needed_pkgs gw)
    [ -n "$pk" ] && { run_task "installing $pk" install_pkgs "$g" "$pk" || { pause; return 1; }; }
    run_task "preparing the firewall and configs" stage_gateway "$STAGE/outgw" || { pause; return 1; }
    run_task "copying files in" push_dir "$g" "$STAGE/outgw" || { pause; return 1; }
    pct set "$g" --nameserver 127.0.0.1 >/dev/null 2>&1
    apply_in_ct "$g"; rc=$?
    if [ "$rc" != 0 ]; then
        bad "the gateway didn't come up, so no containers were moved"
        pause; return 1
    fi
    if [ -n "${V[gw.newname]:-}" ] && [ "${V[gw.newname]}" != "${V[gw.name]}" ]; then
        pct set "$g" --hostname "${V[gw.newname]}" >/dev/null 2>&1
        cexec "$g" sh -c "echo '${V[gw.newname]}' > /etc/hostname; hostname '${V[gw.newname]}'" >/dev/null 2>&1
        ok "renamed ${V[gw.name]} → ${V[gw.newname]}"
        V[gw.name]=${V[gw.newname]}
    fi
    reg_set "$g" ROLE gateway; reg_set "$g" NAME "${V[gw.name]}"; reg_set "$g" PROVIDER "${V[gw.provider]}"
    reg_set "$g" FPS "$(echo ${V[gw.primary.fp]:-} ${V[gw.backup.fp]:-})"
    reg_set "$g" PROTO "${V[gw.primary.kind]}"; reg_set "$g" BRIDGE "${V[gw.bridge]}"; reg_set "$g" VPN_NET "${V[gw.net]}"
    [ "${V[gw.mode]}" = create ] && reg_set "$g" LAN_ADDR "${V[gw.lanaddr]}"

    for c in ${V[gw.clients]}; do
        local publish_reg="" e
        for e in ${V[c$c.publish]:-}; do publish_reg="$publish_reg $e"; done
        if [ "$(reg_get "$c" ROLE)" = client ]; then
            reg_set "$c" PUBLISH "${publish_reg# }"
            continue
        fi
        section_head "CT $c ${V[c$c.name]}" "→ ${V[c$c.ip]} behind the gateway"
        [ "${V[snap]}" = y ] && { run_task "snapshot" snapshot_ct "$c" || warn "no snapshot"; }
        local was_tunnel=0; [ "$(reg_get "$c" ROLE)" = tunnel ] && was_tunnel=1
        run_task "moving it to ${V[gw.bridge]}" client_move "$c" || { bad "could not move CT $c"; continue; }
        if [ "$was_tunnel" = 1 ] || [ "${D[c$c.HAS_SETUP]:-}" = 1 ]; then
            cpush "$c" "$STAGE/payload/remove.sh" /tmp/vpnguard-remove.sh 700
            cexec "$c" bash /tmp/vpnguard-remove.sh 0 1 2>&1 | render_stream
        fi
        cpush "$c" "$STAGE/payload/client.sh" /tmp/vpnguard-client.sh 700
        cexec "$c" bash /tmp/vpnguard-client.sh "$(net_prefix "${V[gw.net]}").1" "${D[c$c.QBIT_CONF]:--}" 2>&1 | render_stream
        run_task "restarting it on the new network" bash -c "pct reboot $c >/dev/null 2>&1 || { pct stop $c; pct start $c; }"
        kvfile_del "$REG/$c.env" PROVIDER; kvfile_del "$REG/$c.env" PROTO
        reg_set "$c" ROLE client; reg_set "$c" NAME "${V[c$c.name]}"; reg_set "$c" GATEWAY "$g"
        reg_set "$c" IP "${V[c$c.ip]}"; reg_set "$c" PUBLISH "${publish_reg# }"
    done
    for c in ${V[gw.old_clients]:-}; do
        case " ${V[gw.clients]} " in *" $c "*) continue ;; esac
        section_head "CT $c" "leaves the gateway"
        run_task "back to its old network" client_detach "$c"
    done
    echo
    run_task "watchdog timer on this host" install_watchdog
    gateway_results
}

gateway_results() {
    local g=${V[gw.ct]} c gwexit
    FLOW="VPN gateway"; PAGE_TOTAL=0; CONTEXT=""
    page "Results" "Checking the gateway, then asking each container which IP the internet sees. They should all match the gateway's."
    local -A BR=()
    run_task "gateway tunnel" bash -c "pct exec $g -- /usr/local/sbin/vpn-status --brief > '$STAGE/res-gw' 2>/dev/null"
    read_kv_into BR "" < "$STAGE/res-gw"
    gwexit=${BR[EXIT_IP]:-}
    if [ "${BR[TUNNEL]:-}" = up ] && [ -n "$gwexit" ]; then
        ok "gateway exit $gwexit ${BR[CITY]:+(${BR[CITY]}, ${BR[COUNTRY]})}${BR[PF_PORT]:+ · forwarded port ${BR[PF_PORT]}}"
    else
        warn "the gateway's tunnel isn't passing traffic yet"
    fi
    sleep 4
    for c in ${V[gw.clients]}; do
        local ip=""
        wait_ct_net "$c" >/dev/null 2>&1
        ip=$(cexec "$c" sh -c 'command -v curl >/dev/null && for i in 1 2; do curl -4 -s -m 8 https://ipinfo.io/ip && break; done || wget -qO- -T 8 https://ipinfo.io/ip' 2>/dev/null)
        if [ -z "$ip" ]; then warn "CT $c ${V[c$c.name]}: no internet answer yet (still booting?)"
        elif [ "$ip" = "$gwexit" ]; then ok "CT $c ${V[c$c.name]} (${V[c$c.ip]}) exits as $ip ${OK}· same as the gateway${R}"
        else bad "CT $c ${V[c$c.name]} exits as $ip, not the gateway's $gwexit"; fi
    done
    local gwaddr=${V[gw.lanaddr]%/*}
    [ "${V[gw.mode]}" = reconfig ] && gwaddr=$(reg_get "$g" LAN_ADDR); gwaddr=${gwaddr%/*}
    echo
    box_top "Open your apps at"
    local e any=0
    for c in ${V[gw.clients]}; do
        for e in ${V[c$c.publish]:-}; do box_row "${CY}http://${gwaddr}:${e%%:*}${R}  ${GR}→ ${V[c$c.name]} port ${e#*:}${R}"; any=1; done
    done
    [ "$any" = 0 ] && box_row "${GR}nothing published${R}"
    box_bot
    note "update apps that talk to these (Lidarr's download client, Prowlarr's apps) to the addresses above"
    note "containers behind the gateway reach each other directly on ${V[gw.bridge]}, e.g. Prowlarr → qBittorrent at its 10.x address"
    pause
}
