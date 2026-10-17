# ════════════════════════════════════════════════════════════
#  Add containers: plug more containers into a gateway that already exists, without the VPN steps.
#  The gateway is read back exactly as it is (the same way the Port forwarding screen does it) and
#  only its firewall is reloaded, so the tunnel stays connected. Each new container then moves
#  behind the gateway the same way it does in the gateway wizard (attach_client).
# ════════════════════════════════════════════════════════════

# a short "bridge · address" for the first network card of a container
ac_nic() {   # ac_nic CT
    local line br ip
    line=$(pct config "$1" 2>/dev/null | sed -n 's/^net0: //p')
    br=$(tr ',' '\n' <<<"$line" | sed -n 's/^bridge=//p')
    ip=$(tr ',' '\n' <<<"$line" | sed -n 's/^ip=//p')
    printf '%s' "${br:-?}${ip:+ · $ip}"
}

# an address for a new container on the gateway's VPN network: inside it, free, and clear of the
# gateway (.1) and of the DHCP range (.100-.199)
v_clientip() {
    VERR="use a free address between ${V[gw.net]%.0/24}.10 and ${V[gw.net]%.0/24}.99"
    is_ip4 "$1" || return 1
    [ "$(net_prefix "${V[gw.net]}")" = "${1%.*}" ] || return 1
    [ "$((10#${1##*.}))" -ge 10 ] && [ "$((10#${1##*.}))" -le 99 ] || return 1
    local c
    for c in $(reg_ids); do
        [ "$(reg_get "$c" IP)" = "$1" ] && { VERR="$1 is already used by CT $c"; return 1; }
    done
    for c in ${V[gw.clients]}; do
        [ "${V[c$c.ip]:-}" = "$1" ] && { VERR="$1 is already given to CT $c"; return 1; }
    done
    printf '%s' "$1"
}

# containers PVM doesn't manage yet (not a gateway, a tunnel container, or already behind a gateway)
ac_items() {   # ac_items GWID : prints checklist rows
    local g=$1 c
    for c in $(ct_ids); do
        [ "$c" = "$g" ] && continue
        case "$(reg_get "$c" ROLE)" in client | gateway | tunnel) continue ;; esac
        printf '%s|%s|%s|0\n' "$c" "$c $(ct_name "$c")" "$(ct_status "$c") · $(ac_nic "$c")"
    done
}

ac_apply() {   # ac_apply "new ids"
    local new=$1 g=${V[gw.ct]} c rc
    FLOW="add containers"; PAGE_TOTAL=0; CONTEXT=""
    page "Applying" "The gateway's firewall is reloaded first (the VPN stays connected), then each container moves behind it."
    section_head "Gateway CT $g ${V[gw.name]}" "firewall only · the tunnel is not restarted"
    FW_ONLY=1
    run_task "preparing the firewall" stage_gateway "$STAGE/outgw" || { FW_ONLY=0; pause; return 1; }
    run_task "copying files in" push_dir "$g" "$STAGE/outgw" || { FW_ONLY=0; pause; return 1; }
    FW_ONLY=0
    apply_in_ct "$g"; rc=$?
    if [ "$rc" != 0 ]; then
        bad "the gateway did not take the change (its previous firewall is still in place if it failed its check), so no containers were moved"
        pause; return 1
    fi
    for c in $new; do attach_client "$c"; done
    echo
    gateway_results
}

add_containers_screen() {
    local g c chosen new="" ip pub sugg e ok_all taken x nics key
    new_stage; write_payload "$STAGE/payload"
    FLOW="add containers"; PAGE_TOTAL=0; CONTEXT=""
    page "Add containers" "Put more containers behind a gateway you already have. Its VPN is not touched or restarted; only its firewall is reloaded."
    pick_managed g "gateway" "Which gateway?" || return 0
    V=(); D=()
    pf_load_gateway "$g" || { bad "could not read the gateway's settings (is CT $g running?)"; pause; return 0; }
    V[snap]=y

    local -a items=()
    mapfile -t items < <(ac_items "$g")
    if [ ${#items[@]} -eq 0 ]; then
        warn "no other containers to add: every container is already managed by PVM"
        note "a container that has its own VPN tunnel can be converted from VPN gateways"
        pause; return 0
    fi
    echo
    note "ticked containers move to ${V[gw.bridge]} and get a new address; their old network card is replaced"
    checklist chosen "Containers to put behind ${V[gw.name]}" "${items[@]}" || return 0
    [ -n "$chosen" ] || { warn "nothing ticked"; pause; return 0; }

    # look inside each one (nothing changes yet)
    FLOW="add containers"; PAGE_TOTAL=0; CONTEXT=""
    page "Looking inside" "Checking the containers you ticked. Nothing is changed yet."
    for c in $chosen; do
        V[c$c.name]=$(ct_name "$c")
        if [ "$(ct_status "$c")" != running ]; then
            run_task "starting CT $c" pct start "$c" || { warn "skipping CT $c"; continue; }
            sleep 3
        fi
        detect_task "CT $c ${V[c$c.name]}" "c$c" "$c" || { warn "skipping CT $c"; continue; }
        new="$new $c"
    done
    new=${new# }
    [ -n "$new" ] || { bad "none of them could be checked"; pause; return 0; }

    # a free address on the VPN network for each (you can change it)
    echo
    for c in $new; do
        field ip "Address for CT $c ${V[c$c.name]} on ${V[gw.bridge]}" "$(next_client_ip)" v_clientip || return 0
        V[c$c.ip]=$ip
        V[gw.clients]="${V[gw.clients]} $c"
        nics=$(pct config "$c" | grep -cE '^net[0-9]+:')
        key=$(pct config "$c" | grep -E '^net[0-9]+:' | grep -m 1 "name=${D[c$c.LAN_IF]:-eth0}," | cut -d: -f1)
        V[c$c.netkey]=${key:-net0}
        [ "$nics" -gt 1 ] && warn "CT $c: $((nics - 1)) extra network card(s) get removed (they'd bypass the gateway)"
    done
    V[gw.clients]=${V[gw.clients]# }

    # which of their ports your home network can open through the gateway
    local gwaddr=${V[gw.lanaddr]%/*}
    [ "$gwaddr" = dhcp ] && gwaddr="the gateway"
    echo
    note "your home network opens a container's apps at $gwaddr:port"
    taken=" 53 67 "
    for x in $(gateway_clients_of "$g"); do
        for e in ${V[c$x.publish]:-}; do taken="$taken${e%%:*} "; done
    done
    for c in $new; do
        AP_TAKEN=$taken; auto_publish "$c"; sugg=$AP_OUT
        [ -n "${D[c$c.LISTEN_TCP]:-}" ] && note "CT $c ${V[c$c.name]} listens on: tcp ${D[c$c.LISTEN_TCP]}"
        while true; do
            field pub "CT $c ${V[c$c.name]}: ports to publish (- for none)" "$sugg" v_publish || return 0
            ok_all=1
            for e in $pub; do
                case "$taken" in *" ${e%%:*} "*) bad "outside port ${e%%:*} is already used, try $((${e%%:*} + 10000)):${e#*:}"; ok_all=0 ;; esac
            done
            [ "$ok_all" = 1 ] && break
        done
        for e in $pub; do taken="$taken${e%%:*} "; done
        V[c$c.publish]=$pub
    done

    # review: nothing has happened yet
    FLOW="add containers"; PAGE_TOTAL=0; CONTEXT=""
    page "Review" "Nothing has changed yet. This is what will happen:"
    box_top "Gateway · CT $g ${V[gw.name]}"
    box_row "${GR}VPN${R}            ${OK}untouched, stays connected${R}"
    box_row "${GR}Firewall${R}       reloaded once, to add the new addresses and published ports"
    box_bot
    for c in $new; do
        local pubs=""
        [ -n "${D[c$c.QBIT_IFACE]:-}" ] && pubs=" · qBittorrent unbound from ${D[c$c.QBIT_IFACE]}"
        box_top "CT $c · ${V[c$c.name]}"
        box_row "${GR}New address${R}    ${V[c$c.ip]} on ${V[gw.bridge]} · DNS via the gateway$pubs"
        pubs=""
        for e in ${V[c$c.publish]}; do pubs="$pubs ${gwaddr}:${e%%:*}→${e#*:}"; done
        box_row "${GR}Published${R}     ${pubs:-nothing}"
        box_row "${GR}Restarts${R}       once, to switch networks"
        box_bot
    done
    echo
    local snap go
    yn snap "Take Proxmox snapshots of the new containers first?" y || return 0
    V[snap]=$snap
    yn go "Apply now?" y || return 0
    [ "$go" = y ] || return 0
    ac_apply "$new"
}
