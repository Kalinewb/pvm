# ════════════════════════════════════════════════════════════
#  Per-container mode
# ════════════════════════════════════════════════════════════
tm_select() {
    FLOW="per-container setup"; CONTEXT=""
    page "Pick containers" "Each one gets its own VPN tunnel and kill switch. Pick as many as you like; shared questions are asked once."
    local -a items=()
    local id name st role mark on
    for id in $(ct_ids); do
        role=$(reg_get "$id" ROLE)
        [ "$role" = gateway ] || [ "$role" = client ] && continue
        name=$(ct_name "$id"); st=$(ct_status "$id")
        mark="$st"
        [ "$role" = tunnel ] && mark="$st · VPN: $(provider_label "$(reg_get "$id" PROVIDER)")"
        on=0; case " ${V[sel]:-} " in *" $id "*) on=1 ;; esac
        items+=("$id|$id $name|$mark|$on")
    done
    [ ${#items[@]} -gt 0 ] || { warn "no containers found"; pause; return 1; }
    local chosen mode
    while true; do
        checklist chosen "Containers" "${items[@]}" || return
        if [ -z "$chosen" ]; then bad "pick at least one"; continue; fi
        echo
        pick mode "How much do you want to decide?" "${V[mode]:-express}" \
            "express|Express (recommended)|only asks for the VPN config; full access to your home network" \
            "custom|Custom|choose ports, apps and a backup config yourself" || { local rc=$?; [ "$rc" = 2 ] && return 2; continue; }
        break
    done
    V[sel]=$chosen; V[mode]=$mode
    local count; count=$(wc -w <<<"$chosen")
    if is_express; then PAGE_TOTAL=$((2 + 2 * count + 1)); else PAGE_TOTAL=$((3 + 6 * count + 1)); fi
}

tm_detect() {
    FLOW="per-container setup"; CONTEXT=""
    [ "$DIR" = back ] && [ "$NT" -gt 0 ] && return 3
    page "Looking inside" "Checking each container: OS, network, apps, and what's already set up. Nothing is changed."
    local id t=0 st
    NT=0
    for id in ${V[sel]}; do
        t=$((t + 1))
        st=$(ct_status "$id")
        if [ "$st" != running ]; then
            run_task "starting CT $id" pct start "$id" || { bad "CT $id won't start, skipping it"; continue; }
            sleep 3
        fi
        V[$t.ct]=$id; V[$t.name]=$(ct_name "$id")
        if detect_task "CT $id ${V[$t.name]}" "$t" "$id"; then
            case " ${D[$t.OS_ID]} ${D[$t.OS_LIKE]} " in
                *" debian "*|*" ubuntu "*) ;;
                *) warn "CT $id runs ${D[$t.OS_NAME]}; only Debian/Ubuntu are supported, skipping it"; t=$((t - 1)); continue ;;
            esac
            [ -n "${D[$t.LAN_IF]}" ] || { warn "CT $id has no network, skipping it"; t=$((t - 1)); continue; }
            NT=$t
        else
            t=$((t - 1))
        fi
    done
    [ "$NT" -gt 0 ] || { bad "none of the containers can be set up"; pause; return 1; }
    echo
    local i
    for ((i = 1; i <= NT; i++)); do
        local extra=""
        [ "${D[$i.HAS_SETUP]:-}" = 1 ] && extra=" · already set up, current choices are the defaults"
        ok "CT ${V[$i.ct]} ${V[$i.name]}: ${D[$i.OS_NAME]} · ${D[$i.LAN_IF]} ${D[$i.LAN_IP]}$extra"
    done
    pause
}

tm_shared() {
    FLOW="per-container setup"; CONTEXT=""
    if is_express && [ -n "${V[lan_net]:-${D[1.CUR_LAN_NET]:-${D[1.LAN_NET]:-}}}" ]; then
        V[lan_net]=${V[lan_net]:-${D[1.CUR_LAN_NET]:-${D[1.LAN_NET]}}}; return 3
    fi
    page "Home network" "Which network is your home LAN? Containers get full access to it (you can narrow that down in Custom setup)."
    local net
    field net "Home network" "${V[lan_net]:-${D[1.CUR_LAN_NET]:-${D[1.LAN_NET]}}}" v_cidr4 || return
    V[lan_net]=$net
}

tm_lan() {
    local t=$1 sugg="" p ports out full
    if is_express; then express_fill "$t"; return 3; fi
    ctx "$t"
    page "Home network access" "Your home network is never behind the VPN: ${V[$t.name]} can reach your NAS, other containers and devices directly, and they can reach it."
    local curmode=${V[$t.lan_mode]:-${D[$t.CUR_LAN_MODE]:-open}}
    yn full "Give ${V[$t.name]} full access to ${V[lan_net]}? (recommended)" "$([ "$curmode" = open ] && echo y || echo n)" || return
    if [ "$full" = y ]; then V[$t.lan_mode]=open; V[$t.lan_tcp]=""; V[$t.lan_out]=""; return 0; fi
    V[$t.lan_mode]=ports
    echo
    note "locked-down mode: only the ports you list below"
    [ -n "${D[$t.LISTEN_TCP]}" ] && note "listening right now: tcp ${D[$t.LISTEN_TCP]}"
    [ -n "${D[$t.QBIT_WEBUI_PORT]:-}" ] && note "qBittorrent WebUI: ${D[$t.QBIT_WEBUI_PORT]}"
    echo
    if [ -n "${V[$t.lan_tcp]+x}" ]; then sugg=${V[$t.lan_tcp]}
    elif [ "${D[$t.HAS_SETUP]:-}" = 1 ]; then sugg=${D[$t.CUR_LAN_TCP_PORTS]:-}
    else
        for p in ${D[$t.LISTEN_TCP]}; do [ "$p" = "${D[$t.QBIT_LISTEN_PORT]:-}" ] || sugg="$sugg $p"; done
        sugg=${sugg# }
    fi
    field ports "TCP ports open to your home network (- for none)" "$sugg" v_ports || return
    V[$t.lan_tcp]=$ports
    echo
    note "only if this app talks to other machines, e.g. Prowlarr → Lidarr 192.168.1.23:8686"
    field out "LAN services it connects to, ip:port (- for none)" "${V[$t.lan_out]:-${D[$t.CUR_LAN_OUT]:-}}" v_lanout || return
    V[$t.lan_out]=$out
}

tm_apps() {
    local t=$1 inp a ok_all
    local -a list
    if is_express; then express_fill "$t"; return 3; fi
    ctx "$t"
    page "Apps" "These stop whenever the tunnel goes down, and only start once it's up."
    [ -n "${D[$t.APP_SERVICES]}" ] && note "found: ${D[$t.APP_SERVICES]}"
    while true; do
        field inp "Services tied to the VPN (- for none)" "${V[$t.apps]:-${D[$t.CUR_APPS]:-${D[$t.APP_SERVICES]}}}" v_any || return
        read -ra list <<<"${inp//,/ }"
        local out=""; ok_all=1
        for a in "${list[@]}"; do
            [[ $a == *.service ]] || a="$a.service"
            if ! is_unit "$a"; then bad "'$a' isn't a service name"; ok_all=0; break; fi
            if ! cexec "${V[$t.ct]}" systemctl cat "$a" >/dev/null 2>&1; then bad "$a doesn't exist in CT ${V[$t.ct]}"; ok_all=0; break; fi
            out="$out $a"
        done
        [ "$ok_all" = 1 ] && break
    done
    V[$t.apps_all]=${out# }
    if [ -n "${V[$t.apps_all]}" ]; then
        echo
        local tie
        yn tie "Stop them while the VPN is down, and start them again when it's back? (recommended)" "${V[$t.tie]:-y}" || return
        V[$t.tie]=$tie
    fi
    if [ "${V[$t.tie]:-y}" = y ]; then V[$t.apps]=${V[$t.apps_all]}; else V[$t.apps]=""; fi
    if [[ ${V[$t.apps_all]} == *qbittorrent* ]] && [ -n "${D[$t.QBIT_IFACE]:-}" ]; then
        local want=wg0; [ "${V[$t.primary.kind]}" = openvpn ] && want=tun0
        [ "${D[$t.QBIT_IFACE]}" != "$want" ] && warn "qBittorrent is bound to ${D[$t.QBIT_IFACE]}; set Options → Advanced → Network interface to $want"
    fi
    return 0
}

# review card for one per-container target
tm_card() {
    local t=$1 pf
    case ${V[$t.pf_mode]:-none} in
        none)   pf="off" ;;
        static) pf="port ${V[$t.pf_port]}$([ "${V[$t.qbit_sync]:-0}" = 1 ] && echo ' · set in qBittorrent')" ;;
        natpmp) pf="NAT-PMP$([ "${V[$t.qbit_sync]:-0}" = 1 ] && echo ' · synced to qBittorrent')" ;;
    esac
    box_top "CT ${V[$t.ct]} · ${V[$t.name]}"
    box_row "${GR}VPN${R}            $(provider_label "${V[$t.provider]}") · ${V[$t.primary.label]}"
    [ -n "${V[$t.backup.kind]:-}" ] && box_row "${GR}Backup${R}         ${V[$t.backup.label]}"
    if [ "${V[$t.lan_mode]:-open}" = open ]; then
        box_row "${GR}Home network${R}   ${V[lan_net]} · ${OK}full access both ways${R}"
    else
        box_row "${GR}From home${R}      ${V[lan_net]} → tcp ${V[$t.lan_tcp]:-none}"
        box_row "${GR}LAN out${R}        ${V[$t.lan_out]:-none}"
    fi
    if [ -n "${V[$t.apps]:-}" ]; then box_row "${GR}Tied to VPN${R}    ${V[$t.apps]} ${GR}· stop when the VPN drops${R}"
    elif [ -n "${V[$t.apps_all]:-}" ]; then box_row "${GR}Apps${R}            ${V[$t.apps_all]} ${GR}· keep running when the VPN drops${R}"
    else box_row "${GR}Tied to VPN${R}    nothing"; fi
    box_row "${GR}Port forward${R}   $pf"
    box_row "${GR}Internet${R}       only through the VPN · IPv6 blocked"
    if [[ ${V[$t.apps]:-} == *qbittorrent* ]] && [ -n "${D[$t.QBIT_IFACE]:-}" ]; then
        local want=wg0; [ "${V[$t.primary.kind]}" = openvpn ] && want=tun0
        [ "${D[$t.QBIT_IFACE]}" != "$want" ] && box_row "${WA}▲${R} qBittorrent is bound to ${D[$t.QBIT_IFACE]}: set Options → Advanced → Network interface to $want"
    fi
    [ "${D[$t.LEGACY_RULES]:-0}" -gt 0 ] && box_row "${WA}▲${R} ${D[$t.LEGACY_RULES]} old iptables rules get retired (backed up)"
    [ "${V[$t.primary.kind]}" = openvpn ] && [ "${D[$t.HAS_TUN]:-}" != 1 ] && box_row "${WA}▲${R} needs /dev/net/tun: the container restarts once"
    box_bot
}

tm_review() {
    FLOW="per-container setup"; CONTEXT=""
    local i tie ask=0
    if is_express; then
        for ((i = 1; i <= NT; i++)); do express_fill "$i"; [ -n "${V[$i.apps_all]:-}" ] && ask=1; done
    fi
    if [ "$ask" = 1 ]; then
        page "Apps" "Apps like qBittorrent can be stopped automatically whenever the VPN is down, and started again when it's back. They can't reach the internet while it's down either way; this just stops them retrying."
        for ((i = 1; i <= NT; i++)); do
            [ -n "${V[$i.apps_all]:-}" ] || continue
            yn tie "CT ${V[$i.ct]} ${V[$i.name]}: stop ${V[$i.apps_all]//.service/} while the VPN is down?" "${V[$i.tie]:-y}" || return
            V[$i.tie]=$tie
            express_fill "$i"
        done
    fi
    page "Review" "Nothing has changed yet. This is what will happen:"
    for ((i = 1; i <= NT; i++)); do tm_card "$i"; done
    echo
    local snap go
    yn snap "Take a Proxmox snapshot of each first, so you can roll back?" "${V[snap]:-y}" || return
    V[snap]=$snap
    yn go "Apply to $NT container$([ "$NT" -gt 1 ] && echo s) now?" y || return
    [ "$go" = y ] || return 1
}

tunnel_wizard() {
    new_stage
    write_payload "$STAGE/payload"
    local rc i
    while true; do
        PB=0; PAGE_TOTAL=${PAGE_TOTAL:-10}
        run_pages "tm_select" "tm_detect" "tm_shared"; rc=$?
        [ "$rc" = 0 ] || return "$rc"
        local -a pages=()
        for ((i = 1; i <= NT; i++)); do
            if is_express; then
                pages+=("pg_config $i")
                [ "${D[$i.HAS_BACKUP]:-}" = 1 ] && pages+=("pg_backup $i")
                pages+=("pg_pf $i")
            else
                pages+=("pg_provider $i" "pg_config $i" "pg_backup $i" "tm_lan $i" "tm_apps $i" "pg_pf $i")
            fi
        done
        pages+=("tm_review")
        if is_express; then PB=2; else PB=3; fi
        PAGE_TOTAL=$((PB + ${#pages[@]}))
        run_pages "${pages[@]}"; rc=$?
        case $rc in
            0) tunnel_apply; return 0 ;;
            1) DIR=back; continue ;;
            *) return 2 ;;
        esac
    done
}
