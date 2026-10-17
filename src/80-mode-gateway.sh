# ════════════════════════════════════════════════════════════
#  Gateway mode: one VPN container + a private bridge
# ════════════════════════════════════════════════════════════

gateway_ids() { local id; for id in $(reg_ids); do [ "$(reg_get "$id" ROLE)" = gateway ] && echo "$id"; done; }
gateway_clients_of() { local id; for id in $(reg_ids); do [ "$(reg_get "$id" ROLE)" = client ] && [ "$(reg_get "$id" GATEWAY)" = "$1" ] && echo "$id"; done; }
# names the user gave to gateways (and every container hostname), so a new one can't clash
name_taken() { local id n; for id in $(reg_ids); do [ "$id" = "${V[gw.ct]:-}" ] && continue; [ "$(reg_get "$id" NAME)" = "$1" ] && return 0; done; for id in $(ct_ids); do [ "$id" = "${V[gw.ct]:-}" ] && continue; [ "$(ct_name "$id")" = "$1" ] && return 0; done; return 1; }
suggest_gw_name() { local n=1 cand=vpn-gateway; while name_taken "$cand"; do n=$((n + 1)); cand=vpn-gateway-$n; done; echo "$cand"; }
v_gwname() { VERR="that name is already used by a container or another gateway"; v_host "$1" >/dev/null || { VERR="use letters, digits and - only"; return 1; }; ! name_taken "$1" && printf '%s' "$1"; }
# a VPN network no other gateway uses (10.10.10.0/24, then 10.10.11.0/24, ...)
used_vpnnets() { local id; for id in $(gateway_ids); do [ "$id" = "${V[gw.ct]:-}" ] || reg_get "$id" VPN_NET; done; }
free_vpnnet() {
    local n net used
    used=" $(used_vpnnets | tr '\n' ' ') "
    for n in $(seq 10 99); do
        net=10.10.$n.0/24
        [[ $used == *" $net "* ]] && continue
        [ "$(net_prefix "$net")" = "$(net_prefix "${V[lan_net]:-x.x.x.0/24}")" ] && continue
        ip route show 2>/dev/null | grep -q "^10\.10\.$n\." && continue
        echo "$net"; return
    done
}
bridge_exists()   { ip link show "$1" >/dev/null 2>&1 || grep -Eq "^(auto|iface)[[:space:]]+$1([[:space:]]|$)" "$IFACES_FILE" 2>/dev/null; }
free_bridge()     { local n; for n in $(seq 1 99); do bridge_exists "vmbr$n" || { echo "vmbr$n"; return; }; done; }
net_prefix()      { echo "${1%.*/*}"; }   # 10.10.10.0/24 → 10.10.10

v_newbridge() { VERR="use a free name like vmbr1"; [[ $1 =~ ^vmbr[0-9]{1,4}$ ]] && { [ "${V[gw.mode]}" = reconfig ] || ! bridge_exists "$1"; } && printf '%s' "$1"; }
v_vpnnet() {
    VERR="use a /24 like 10.10.10.0/24 that isn't your home network"
    [[ $1 =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.0/24$ ]] || return 1
    is_ip4 "${1%/*}" || return 1
    [ "$(net_prefix "$1")" = "$(net_prefix "${V[lan_net]:-x.x.x.0/24}")" ] && return 1
    [[ " $(used_vpnnets | tr '\n' ' ') " == *" $1 "* ]] && { VERR="another gateway already uses $1"; return 1; }
    printf '%s' "$1"
}
v_newct() { VERR="that ID is taken or isn't a number"; [[ $1 =~ ^[0-9]{3,9}$ ]] && ! ct_exists "$1" && printf '%s' "$1"; }
v_gwlan() {
    v_ip4len "$1" >/dev/null || return 1
    [ "$1" = dhcp ] && { printf dhcp; return 0; }
    VERR="${1%/*} already answers on your network, pick a free address"
    ping -c 1 -W 1 "${1%/*}" >/dev/null 2>&1 && return 1
    printf '%s' "$1"
}

# a free address near the top of the home network, for the gateway
suggest_gw_ip() {
    local pre i len=${V[lan_net]#*/}
    pre=$(net_prefix "${V[lan_net]}")
    local mine; mine=" $(for g in $(gateway_ids); do reg_get "$g" LAN_ADDR; done | sed 's#/.*##' | tr '\n' ' ') "
    for i in 250 249 248 247 246 245 240 230 220 210 200; do
        [[ $mine == *" $pre.$i "* ]] && continue
        ping -c 1 -W 1 "$pre.$i" >/dev/null 2>&1 || { echo "$pre.$i/$len"; return; }
    done
    echo dhcp
}

# auto_publish CT : sets AP_OUT to "outside:inside ..." for the container's listening ports, avoiding clashes (AP_TAKEN = outside ports used)
AP_OUT=""; AP_TAKEN=" 53 67 "
auto_publish() {
    local c=$1 p out
    AP_OUT=""
    for p in ${D[c$c.LISTEN_TCP]:-}; do
        [ "$p" = "${D[c$c.QBIT_LISTEN_PORT]:-}" ] && continue
        out=$p
        while [[ $AP_TAKEN == *" $out "* ]]; do out=$((out + 10000)); [ "$out" -gt 65535 ] && out=$((out - 20000)); done
        AP_TAKEN="$AP_TAKEN$out "
        AP_OUT="$AP_OUT $out:$p"
    done
    AP_OUT=${AP_OUT# }
}

gw_diagram() {
    local gwn=${V[gw.name]:-vpn-gateway} br=${V[gw.bridge]:-vmbr1} net=${V[gw.net]:-10.10.10.0/24} lan=${V[lan_net]:-your LAN}
    printf '    %shome LAN %s%s\n' "$GR" "$lan" "$R"
    printf '    %s━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$CY" "$R"
    printf '           %s┃%s\n' "$CY" "$R"
    printf '    %s╭──────┸─────────────╮%s       %s╭─────────╮%s\n' "$PK" "$R" "$VI" "$R"
    printf '    %s│%s %s%-18s%s %s│%s%s═══════%s%s│%s  VPN    %s│%s%s═══ internet%s\n' "$PK" "$R" "$B" "$gwn" "$R" "$PK" "$R" "$OK" "$R" "$VI" "$R" "$VI" "$R" "$OK" "$R"
    printf '    %s│%s %skill switch · NAT%s  %s│%s %stunnel%s%s╰─────────╯%s\n' "$PK" "$R" "$GR" "$R" "$PK" "$R" "$GR" "$R" "$VI" "$R"
    printf '    %s╰──────┰─────────────╯%s\n' "$PK" "$R"
    printf '           %s┃%s  %s%s %s · no way out except the tunnel%s\n' "$WA" "$R" "$GR" "$br" "$net" "$R"
    printf '    %s━━━━━━━┻━━━━━━━━┳━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━%s\n' "$WA" "$R"
    printf '              %scontainer%s      %scontainer%s     %s…%s\n' "$B" "$R" "$B" "$R" "$GR" "$R"
}

gw_intro() {
    FLOW="VPN gateway"; CONTEXT=""
    local g="" gids; gids=$(gateway_ids)
    if [ -n "$gids" ]; then
        page "VPN gateways" "Each gateway is its own VPN connection with its own name, private bridge and containers. Pick one to change, or make another."
        local -a gi=(); local x
        for x in $gids; do gi+=("$x|$(reg_get "$x" NAME)|$(reg_get "$x" PROVIDER) · $(gateway_clients_of "$x" | wc -l) containers · $(reg_get "$x" BRIDGE) · $(reg_get "$x" LAN_ADDR)"); done
        gi+=("new|New gateway|another VPN connection with its own name and bridge")
        pick g "Which gateway?" "${V[pick_gw]:-new}" "${gi[@]}" || return
        [ "$g" = new ] && g=""
        V[pick_gw]=${g:-new}
    fi
    for x in name ct bridge net lanaddr; do unset "V[gw.$x]"; done
    if [ -n "$g" ]; then
        V[gw.mode]=reconfig; V[gw.ct]=$g; V[gw.name]=$(reg_get "$g" NAME); V[gw.name]=${V[gw.name]:-$(ct_name "$g")}
        V[gw.bridge]=$(reg_get "$g" BRIDGE); V[gw.net]=$(reg_get "$g" VPN_NET); V[gw.lanaddr]=$(reg_get "$g" LAN_ADDR)
        page "Gateway ${V[gw.name]}" "CT $g. You can change its VPN, which containers sit behind it, and what's published to your home network."
    else
        V[gw.mode]=create
        page "New VPN gateway" "A small container becomes a VPN router. Every container you plug into its private bridge goes through the VPN, with the kill switch outside the apps, so nothing inside them can route around it."
    fi
    [ -z "${V[lan_net]:-}" ] && V[lan_net]=$(ip -4 route show dev "$(ip -4 route show default | awk '{print $5; exit}')" scope link 2>/dev/null | awk '{print $1; exit}')
    gw_diagram
    echo
    local mode
    pick mode "How much do you want to decide?" "${V[mode]:-express}" \
        "express|Express (recommended)|only asks for the gateway's address and the VPN config" \
        "custom|Custom|choose the bridge, network, ports and storage yourself" || return
    V[mode]=$mode
    echo
    if [ "${V[gw.mode]}" = reconfig ]; then
        local newname
        field newname "Name of this gateway" "${V[gw.name]}" v_gwname || return
        V[gw.newname]=$newname
    else
        local newname
        field newname "Name for the new gateway (this is also its hostname)" "${V[gw.name]:-$(suggest_gw_name)}" v_gwname || return
        V[gw.name]=$newname
    fi
    if [ "${V[gw.mode]}" = reconfig ]; then
        if [ "$(ct_status "$g")" != running ]; then run_task "starting CT $g" pct start "$g" || { pause; return 1; }; sleep 3; fi
        detect_task "looking inside the gateway" gw "$g" || { bad "could not read the gateway's setup"; pause; return 1; }
        local c
        V[gw.clients]=""
        for c in $(reg_ids); do
            [ "$(reg_get "$c" ROLE)" = client ] && [ "$(reg_get "$c" GATEWAY)" = "$g" ] && V[gw.clients]="${V[gw.clients]} $c"
        done
        V[gw.clients]=${V[gw.clients]# }
        V[gw.old_clients]=${V[gw.clients]}
        [ -n "${D[gw.CUR_LAN_OUT]:-}" ] && V[gw.lan_out]=${D[gw.CUR_LAN_OUT]}
    fi
    local net
    if is_express && [ -n "${V[lan_net]:-}" ]; then return 0; fi
    field net "Your home network" "${V[lan_net]}" v_cidr4 || return
    V[lan_net]=$net
}

gw_bridge() {
    [ "${V[gw.mode]}" = reconfig ] && return 3
    if is_express; then
        local xbr=${V[gw.bridge]:-$(free_bridge)} xnet=${V[gw.net]:-$(free_vpnnet)}
        V[gw.bridge]=$xbr; V[gw.net]=$xnet; V[gw.ip]="$(net_prefix "$xnet").1"
        return 3
    fi
    FLOW="VPN gateway"; ctx gw
    page "Private bridge" "A new Proxmox bridge with no physical port. Containers on it can only reach the internet through the gateway's tunnel."
    local br net
    field br "Bridge name" "${V[gw.bridge]:-$(free_bridge)}" v_newbridge || return
    field net "VPN network" "${V[gw.net]:-$(free_vpnnet)}" v_vpnnet || return
    V[gw.bridge]=$br; V[gw.net]=$net; V[gw.ip]="$(net_prefix "$net").1"
    echo
    note "the gateway gets ${V[gw.ip]}, containers get .10 and up, DHCP hands out .100–.199"
    note "this host stays off the bridge, so nothing there can reach Proxmox itself"
    pause
}

gw_container() {
    [ "${V[gw.mode]}" = reconfig ] && return 3
    is_express && gw_bridge
    FLOW="VPN gateway"; ctx gw
    page "Gateway container" "A tiny Debian container (256 MB RAM, 2 GB disk) that runs the tunnel. It needs a fixed address on your home network: that's where you'll open qBittorrent, Prowlarr and so on."
    local id name lan store
    if is_express; then
        id=${V[gw.ct]:-$(pvesh get /cluster/nextid 2>/dev/null)}; name=${V[gw.name]:-$(suggest_gw_name)}
        if ! { [[ $id =~ ^[0-9]{3,9}$ ]] && ! ct_exists "$id"; }; then bad "container ID $id is not free"; pause; return 1; fi
        note "found a free address on ${V[lan_net]}; reserve it in your router's DHCP if you can"
        field lan "LAN address for the gateway (or dhcp)" "${V[gw.lanaddr]:-$(suggest_gw_ip)}" v_gwlan || return
    else
        field id "Container ID" "${V[gw.ct]:-$(pvesh get /cluster/nextid 2>/dev/null)}" v_newct || return
        name=${V[gw.name]:-$(suggest_gw_name)}
        note "pick a free address on ${V[lan_net]}; reserve it in your router's DHCP if you can"
        field lan "LAN address for the gateway (or dhcp)" "${V[gw.lanaddr]:-$(suggest_gw_ip)}" v_gwlan || return
    fi
    V[gw.ct]=$id; V[gw.name]=$name; V[gw.lanaddr]=$lan
    V[gw.lan_gw]=$(host_lan_gw)
    V[gw.lan_bridge]=$(ip -4 -o addr show scope global 2>/dev/null | awk '$2 ~ /^vmbr/ {print $2; exit}')
    echo
    local -a items=()
    local s
    while read -r s; do items+=("$s|$s|$(pvesm status --storage "$s" 2>/dev/null | awk 'NR == 2 {printf "%.0f GB free", $6 / 1048576}')"); done \
        < <(pvesm status --content rootdir 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1}')
    [ ${#items[@]} -gt 0 ] || { bad "no storage for container disks found"; pause; return 1; }
    local defs=${V[gw.storage]:-}
    [ -z "$defs" ] && { printf '%s\n' "${items[@]}" | grep -q '^local-lvm|' && defs=local-lvm || defs=${items[0]%%|*}; }
    if is_express; then store=$defs; else pick store "Storage for its disk" "$defs" "${items[@]}" || return; fi
    V[gw.storage]=$store
    V[gw.tstore]=$(pvesm status --content vztmpl 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1; exit}')
    V[gw.tstore]=${V[gw.tstore]:-local}
}

gw_clients() {
    FLOW="VPN gateway"; ctx gw
    page "Containers behind the gateway" "Ticked containers move to ${V[gw.bridge]}. Their old network card is replaced, so they get a new address; apps that talk to them (Lidarr → qBittorrent, say) need the gateway's address afterwards."
    local -a items=()
    local id name role on desc
    for id in $(ct_ids); do
        [ "$id" = "${V[gw.ct]}" ] && continue
        role=$(reg_get "$id" ROLE)
        name=$(ct_name "$id")
        on=0; case " ${V[gw.clients]:-} " in *" $id "*) on=1 ;; esac
        case $role in
            client) [ "$(reg_get "$id" GATEWAY)" = "${V[gw.ct]}" ] || continue
                    desc="behind this gateway · $(reg_get "$id" IP)" ;;
            tunnel) desc="has its own VPN now → gets converted" ;;
            gateway) continue ;;
            *) desc=$(ct_status "$id") ;;
        esac
        items+=("$id|$id $name|$desc|$on")
    done
    [ ${#items[@]} -gt 0 ] || { warn "no other containers yet: create them later and re-run this"; pause; V[gw.clients]=""; return 0; }
    local chosen
    checklist chosen "Containers" "${items[@]}" || return
    V[gw.clients]=$chosen
}

next_client_ip() {
    local pre i ip used=" ${V[gw.ip]:-} " c
    pre=$(net_prefix "${V[gw.net]}")
    for c in $(reg_ids); do used="$used $(reg_get "$c" IP)"; done
    for c in ${V[gw.clients]}; do used="$used ${V[c$c.ip]:-}"; done
    for i in $(seq 10 99); do
        ip="$pre.$i"
        case " $used " in *" $ip "*) ;; *) echo "$ip"; return ;; esac
    done
}

gw_client_detect() {
    FLOW="VPN gateway"; ctx gw
    [ -z "${V[gw.clients]}" ] && return 3
    [ "$DIR" = back ] && return 3
    page "Looking inside" "Checking the containers that go behind the gateway. Nothing is changed yet."
    local c ok_list=""
    for c in ${V[gw.clients]}; do
        V[c$c.name]=$(ct_name "$c")
        if [ "$(ct_status "$c")" != running ]; then run_task "starting CT $c" pct start "$c" || continue; sleep 3; fi
        if detect_task "CT $c ${V[c$c.name]}" "c$c" "$c"; then ok_list="$ok_list $c"
        else warn "skipping CT $c"; fi
    done
    V[gw.clients]=${ok_list# }
    echo
    for c in ${V[gw.clients]}; do
        [ -z "${V[c$c.ip]:-}" ] && V[c$c.ip]=$(reg_get "$c" IP)
        [ -z "${V[c$c.ip]:-}" ] && V[c$c.ip]=$(next_client_ip)
        local nics
        nics=$(pct config "$c" | grep -E '^net[0-9]+:' | wc -l)
        V[c$c.netkey]=$(pct config "$c" | grep -E '^net[0-9]+:' | grep -m 1 "name=${D[c$c.LAN_IF]:-eth0}," | cut -d: -f1)
        V[c$c.netkey]=${V[c$c.netkey]:-net0}
        local extra=""
        [ "$nics" -gt 1 ] && extra=" · $((nics - 1)) extra network card(s) get removed (they'd bypass the gateway)"
        ok "CT $c ${V[c$c.name]} → ${V[c$c.ip]}$extra"
    done
    pause
}

gw_publish() {
    FLOW="VPN gateway"; ctx gw
    [ -z "${V[gw.clients]}" ] && return 3
    local gwaddr=${V[gw.lanaddr]%/*}
    [ "$gwaddr" = dhcp ] && gwaddr="the gateway"
    local c pub sugg e ok_all
    AP_TAKEN=" 53 67 "
    # suggestions: what was published before, else every port the container listens on
    for c in ${V[gw.clients]}; do
        if [ -n "${V[c$c.publish]+x}" ]; then sugg=${V[c$c.publish]}
        else
            sugg=$(reg_get "$c" PUBLISH)
            if [ -z "$sugg" ]; then auto_publish "$c"; sugg=$AP_OUT; fi
        fi
        V[c$c.sugg]=$sugg
        for e in $sugg; do AP_TAKEN="$AP_TAKEN${e%%:*} "; done
    done
    V[gw.lan_mode]=${V[gw.lan_mode]:-open}
    if is_express; then
        for c in ${V[gw.clients]}; do V[c$c.publish]=${V[c$c.sugg]}; done
        V[gw.lan_mode]=open; V[gw.lan_out]=""
        return 3
    fi
    page "Published to your home network" "Your home network reaches each container through the gateway's address ($gwaddr:port). Pick the ports to publish; use outside:inside (2222:22) when two containers use the same port."
    local taken=" 53 67 "
    for c in ${V[gw.clients]}; do
        sugg=${V[c$c.sugg]}
        [ -n "${D[c$c.LISTEN_TCP]:-}" ] && note "CT $c ${V[c$c.name]} listens on: tcp ${D[c$c.LISTEN_TCP]}"
        while true; do
            field pub "CT $c ${V[c$c.name]}: ports to publish (- for none)" "$sugg" v_publish || return
            ok_all=1
            for e in $pub; do
                case "$taken" in *" ${e%%:*} "*) bad "outside port ${e%%:*} is already used, try $((${e%%:*} + 10000)):${e#*:}"; ok_all=0 ;; esac
            done
            [ "$ok_all" = 1 ] && break
        done
        for e in $pub; do taken="$taken${e%%:*} "; done
        V[c$c.publish]=$pub
    done
    echo
    local full
    yn full "Let the containers reach your whole home network? (recommended)" "$([ "${V[gw.lan_mode]}" = open ] && echo y || echo n)" || return
    if [ "$full" = y ]; then V[gw.lan_mode]=open; V[gw.lan_out]=""; return 0; fi
    V[gw.lan_mode]=ports
    note "locked-down mode: only the services you list can be reached"
    note "e.g. Prowlarr → Lidarr 192.168.1.23:8686"
    local out
    field out "LAN services they may connect to, ip:port (- for none)" "${V[gw.lan_out]:-}" v_lanout || return
    V[gw.lan_out]=$out
}

gw_review() {
    FLOW="VPN gateway"; CONTEXT=""
    is_express && gw_publish
    page "Review" "Nothing has changed yet. This is what will happen:"
    local gwaddr=${V[gw.lanaddr]} pf c
    case ${V[gw.pf_mode]:-none} in
        none)   pf="off" ;;
        static) pf="port ${V[gw.pf_port]} → CT ${V[gw.pf_target]}" ;;
        natpmp) pf="NAT-PMP → CT ${V[gw.pf_target]}$([ "${V[gw.qbit_sync]:-0}" = 1 ] && echo ' · synced to qBittorrent')" ;;
    esac
    if [ "${V[gw.mode]}" = create ]; then
        box_top "On this Proxmox host"
        box_row "${GR}New bridge${R}     ${V[gw.bridge]} (${V[gw.net]}), added to $IFACES_FILE (backed up) + ifreload"
        box_row "${GR}New container${R}  CT ${V[gw.ct]} ${V[gw.name]} · Debian · 256 MB · 2 GB on ${V[gw.storage]}"
        box_bot
    fi
    box_top "Gateway · CT ${V[gw.ct]} ${V[gw.name]}"
    box_row "${GR}LAN address${R}    ${gwaddr:-unchanged} on ${V[gw.lan_bridge]:-vmbr0}"
    box_row "${GR}VPN network${R}    ${V[gw.bridge]} ${V[gw.net]} · gateway ${V[gw.ip]:-$(net_prefix "${V[gw.net]}").1}"
    box_row "${GR}VPN${R}            $(provider_label "${V[gw.provider]}") · ${V[gw.primary.label]}"
    [ -n "${V[gw.backup.kind]:-}" ] && box_row "${GR}Backup${R}         ${V[gw.backup.label]}"
    box_row "${GR}Port forward${R}   $pf"
    if [ "${V[gw.lan_mode]:-open}" = open ]; then box_row "${GR}Home network${R}   ${V[lan_net]} · ${OK}containers can reach all of it${R}"
    else box_row "${GR}LAN out${R}        ${V[gw.lan_out]:-none}"; fi
    box_row "${GR}Kill switch${R}    ${OK}the VPN network can only leave through the tunnel${R}"
    box_bot
    for c in ${V[gw.clients]}; do
        local conv=""
        [ "$(reg_get "$c" ROLE)" = tunnel ] && conv=" · its own VPN gets removed"
        [ -n "${D[c$c.QBIT_IFACE]:-}" ] && conv="$conv · qBittorrent unbound from ${D[c$c.QBIT_IFACE]}"
        box_top "CT $c · ${V[c$c.name]}"
        box_row "${GR}New address${R}    ${V[c$c.ip]} on ${V[gw.bridge]} · DNS via the gateway$conv"
        local e pubs=""
        for e in ${V[c$c.publish]}; do pubs="$pubs ${gwaddr%/*}:${e%%:*}→${e#*:}"; done
        box_row "${GR}Published${R}     ${pubs:-nothing}"
        box_row "${GR}Restarts${R}       once, to switch networks"
        box_bot
    done
    for c in ${V[gw.old_clients]:-}; do
        case " ${V[gw.clients]} " in *" $c "*) ;; *) note "CT $c leaves the gateway and goes back to its old network" ;; esac
    done
    echo
    local snap go
    yn snap "Take Proxmox snapshots of existing containers first?" "${V[snap]:-y}" || return
    V[snap]=$snap
    yn go "Apply now?" y || return
    [ "$go" = y ] || return 1
}

gateway_wizard() {
    new_stage
    write_payload "$STAGE/payload"
    NT=0
    local rc
    while true; do
        PB=0; PAGE_TOTAL=7; DIR=fwd
        run_pages gw_intro; rc=$?
        [ "$rc" = 0 ] || return "$rc"
        local -a pages
        if is_express; then
            # the bridge, network and published ports are filled in by the pages that need them
            pages=(gw_container "pg_config gw")
            [ "${D[gw.HAS_BACKUP]:-}" = 1 ] && pages+=("pg_backup gw")
            pages+=(gw_clients gw_client_detect "pg_pf gw" gw_review)
        else
            pages=(gw_bridge gw_container "pg_provider gw" "pg_config gw" "pg_backup gw" gw_clients gw_client_detect gw_publish "pg_pf gw" gw_review)
        fi
        PB=1; PAGE_TOTAL=$((1 + ${#pages[@]}))
        run_pages "${pages[@]}"; rc=$?
        case $rc in
            0) break ;;
            1) continue ;;
            *) return 2 ;;
        esac
    done
    gateway_apply
}
