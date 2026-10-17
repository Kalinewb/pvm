# ════════════════════════════════════════════════════════════
#  Port forwarding menu (per gateway). Two kinds:
#    · from the internet, through the VPN, to one container (NAT-PMP or a fixed port)
#    · from your home network, through the gateway's address, to a container's ports
#  Changes only reload the gateway's firewall; the tunnel is never restarted.
# ════════════════════════════════════════════════════════════

# pf_load_gateway GWID : fill V from the registry and the gateway's own settings file
pf_load_gateway() {
    local g=$1 envf="$STAGE/gw-$g.env" c
    local -A GE=()
    pct pull "$g" /etc/vpnguard/vpnguard.env "$envf" >/dev/null 2>&1 || return 1
    read_kv_into GE "" < "$envf"
    V[gw.mode]=reconfig; V[gw.ct]=$g; V[gw.name]=$(reg_get "$g" NAME); V[gw.name]=${V[gw.name]:-$(ct_name "$g")}
    V[gw.provider]=${GE[PROVIDER]:-other}; V[gw.bridge]=$(reg_get "$g" BRIDGE); V[gw.net]=${GE[VPN_NET]}; V[gw.ip]=${GE[GW_IP]}
    V[gw.lanaddr]=$(reg_get "$g" LAN_ADDR); V[lan_net]=${GE[LAN_NET]}; V[gw.lan_mode]=${GE[LAN_MODE]:-open}; V[gw.lan_out]=${GE[LAN_OUT]}
    V[gw.primary.kind]=${GE[PROTO]:-wireguard}; V[gw.primary.endpoints]=${GE[ENDPOINTS]}; V[gw.primary.dns]=${GE[DNS_PRIMARY]}
    V[gw.pf_mode]=${GE[PF_MODE]:-none}; V[gw.pf_port]=${GE[PF_PORT]}; V[gw.pf_gw]=${GE[PF_GATEWAY]}; V[gw.qbit_url]=${GE[QBIT_URL]}
    V[home_ip]=${GE[HOME_IP]}
    V[gw.clients]=""; V[gw.pf_target]=""
    for c in $(gateway_clients_of "$g"); do
        V[gw.clients]="${V[gw.clients]} $c"
        V[c$c.name]=$(reg_get "$c" NAME); V[c$c.ip]=$(reg_get "$c" IP); V[c$c.publish]=$(reg_get "$c" PUBLISH)
        [ -n "${GE[PF_TARGET]}" ] && [ "${V[c$c.ip]}" = "${GE[PF_TARGET]}" ] && V[gw.pf_target]=$c
    done
    V[gw.clients]=${V[gw.clients]# }
    # a stored qBittorrent login stays in place unless the forwarded port setup is redone
    if cexec "$g" test -f /etc/vpnguard/qbit.env 2>/dev/null; then V[gw.qbit_sync]=1; V[gw.qbit_keep]=1; fi
    return 0
}

pf_tables() {
    local gwaddr=${V[gw.lanaddr]%/*} c e pf port rows=0
    [ "$gwaddr" = dhcp ] && gwaddr="the gateway"
    case ${V[gw.pf_mode]:-none} in
        none)   pf="off" ;;
        natpmp) port=$(cexec "${V[gw.ct]}" cat /run/vpnguard-pf-port 2>/dev/null)
                pf="NAT-PMP · port ${port:-pending} → CT ${V[gw.pf_target]:-?} ${V[c${V[gw.pf_target]:-0}.name]:-}" ;;
        static) pf="fixed port ${V[gw.pf_port]} → CT ${V[gw.pf_target]:-?} ${V[c${V[gw.pf_target]:-0}.name]:-}" ;;
    esac
    box_top "From the internet, through the VPN"
    box_row "$pf"
    box_bot
    box_top "From your home network, through ${gwaddr}"
    for c in ${V[gw.clients]}; do
        for e in ${V[c$c.publish]}; do
            box_row "${CY}${gwaddr}:${e%%:*}${R}  →  ${V[c$c.name]} (CT $c) port ${e#*:}"; rows=1
        done
    done
    [ "$rows" = 0 ] && box_row "${GR}nothing published${R}"
    box_bot
}

# edit one container's published ports
pf_edit_published() {
    local -a items=(); local c pick_c pub e ok_all other taken
    for c in ${V[gw.clients]}; do items+=("$c|CT $c ${V[c$c.name]}|${V[c$c.publish]:-nothing published}"); done
    [ ${#items[@]} -gt 0 ] || { warn "no containers behind this gateway yet"; pause; return 0; }
    echo
    pick pick_c "Which container?" "" "${items[@]}" || return 0
    if [ -z "${D[c$pick_c.LISTEN_TCP]+x}" ]; then
        V[c$pick_c.name]=${V[c$pick_c.name]:-$(ct_name "$pick_c")}
        detect_task "looking at CT $pick_c ${V[c$pick_c.name]}" "c$pick_c" "$pick_c" || warn "could not look inside, you can still type ports by hand"
    fi
    [ -n "${D[c$pick_c.LISTEN_TCP]:-}" ] && note "CT $pick_c listens on: tcp ${D[c$pick_c.LISTEN_TCP]}"
    note "type ports like: 8090 9696, or outside:inside like 2222:22 (- for none)"
    while true; do
        field pub "Ports to publish for ${V[c$pick_c.name]}" "${V[c$pick_c.publish]}" v_publish || return 0
        ok_all=1; taken=" 53 67 "
        for other in ${V[gw.clients]}; do
            [ "$other" = "$pick_c" ] && continue
            for e in ${V[c$other.publish]}; do taken="$taken${e%%:*} "; done
        done
        for e in $pub; do
            case "$taken" in *" ${e%%:*} "*) bad "outside port ${e%%:*} is already used by another container (try $((${e%%:*} + 10000)):${e#*:})"; ok_all=0 ;; esac
        done
        [ "$ok_all" = 1 ] && break
    done
    V[c$pick_c.publish]=$pub
    PF_CHANGED=1
}

# change the port the VPN forwards (mode, target container, qBittorrent sync)
pf_edit_vpn() {
    local c
    [ -n "${V[gw.clients]}" ] || { warn "no containers behind this gateway yet"; pause; return 0; }
    for c in ${V[gw.clients]}; do
        [ -n "${D[c$c.LISTEN_TCP]+x}" ] && continue
        V[c$c.name]=${V[c$c.name]:-$(ct_name "$c")}
        detect_task "looking at CT $c ${V[c$c.name]}" "c$c" "$c" || true
    done
    V[gw.qbit_sync]=0; V[gw.qbit_keep]=0
    local rc
    pg_pf gw; rc=$?
    case $rc in 0) PF_CHANGED=1 ;; 2) return 2 ;; esac
    return 0
}

pf_apply() {
    local g=${V[gw.ct]} rc c
    FLOW="port forwarding"; PAGE_TOTAL=0; CONTEXT=""
    page "Applying" "Only the gateway's firewall and port forwarding are reloaded. The VPN stays connected."
    FW_ONLY=1
    run_task "preparing the firewall" stage_gateway "$STAGE/outgw" || { FW_ONLY=0; pause; return 1; }
    run_task "copying files in" push_dir "$g" "$STAGE/outgw" || { FW_ONLY=0; pause; return 1; }
    FW_ONLY=0
    apply_in_ct "$g"; rc=$?
    if [ "$rc" != 0 ]; then bad "the gateway did not take the change (the previous firewall is still in place if it failed its check)"; pause; return 1; fi
    for c in ${V[gw.clients]}; do reg_set "$c" PUBLISH "${V[c$c.publish]}"; done
    PF_CHANGED=0
    echo
    pf_tables
    pause
}

port_screen() {
    local g a name
    new_stage; write_payload "$STAGE/payload"
    FLOW="port forwarding"; PAGE_TOTAL=0; CONTEXT=""
    PF_CHANGED=0
    page "Port forwarding" "Choose a gateway, then change what is reachable from the internet (through the VPN) and from your home network."
    pick_managed g "gateway" "Which gateway?" || return 0
    V=(); D=()
    pf_load_gateway "$g" || { bad "could not read the gateway's settings (is CT $g running?)"; pause; return 0; }
    name=${V[gw.name]}
    while true; do
        FLOW="port forwarding"; PAGE_TOTAL=0; CONTEXT=""
        page "Port forwarding · $name" "Nothing changes until you choose Apply."
        pf_tables
        [ "$PF_CHANGED" = 1 ] && printf '\n    %s▲ unsaved changes%s\n' "$WA" "$R"
        echo
        pick a "What now?" "$([ "$PF_CHANGED" = 1 ] && echo apply || echo back)" \
            "ports|Published ports|choose which of a container's ports your home network can reach" \
            "vpn|Port from the VPN|the port your provider forwards, and which container gets it" \
            "apply|Apply changes|reload the gateway's firewall (the VPN stays connected)" \
            "back|Back|$([ "$PF_CHANGED" = 1 ] && echo "discard unsaved changes")" || return 0
        case $a in
            ports) pf_edit_published ;;
            vpn)   pf_edit_vpn; [ $? = 2 ] && return 0 ;;
            apply) [ "$PF_CHANGED" = 1 ] || { note "nothing to apply"; nap 0.8; continue; }
                   pf_apply && { pf_load_gateway "$g"; } ;;
            back)  return 0 ;;
        esac
    done
}
