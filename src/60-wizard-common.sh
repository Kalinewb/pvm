# ════════════════════════════════════════════════════════════
#  Wizard pages shared by both modes
#  A "target" is a key into V/D: 1, 2, 3... (per-container) or gw.
# ════════════════════════════════════════════════════════════
NT=0   # number of per-container targets

is_express() { [ "${V[mode]:-express}" = express ]; }

# Express fills in everything it can detect, so only the VPN config is asked for.
express_fill() {   # express_fill TARGET   (per-container targets; the gateway has its own)
    local t=$1
    V[$t.lan_mode]=open; V[$t.lan_tcp]=""; V[$t.lan_out]=""
    V[$t.apps_all]=${V[$t.apps_all]:-${D[$t.CUR_APPS]:-${D[$t.APP_SERVICES]:-}}}
    # stopping apps with the tunnel is optional; if this container was set up before without them, keep it that way
    if [ -z "${V[$t.tie]:-}" ]; then
        if [ "${D[$t.HAS_SETUP]:-}" = 1 ] && [ -z "${D[$t.CUR_APPS]:-}" ]; then V[$t.tie]=n; else V[$t.tie]=y; fi
    fi
    if [ "${V[$t.tie]}" = y ]; then V[$t.apps]=${V[$t.apps_all]}; else V[$t.apps]=""; fi
}

ctx() {
    local t=$1
    if [ "$t" = gw ]; then
        CONTEXT="$(chip 'gateway' "$PK") ${B}${V[gw.name]:-vpn-gateway}${R} ${GR}· CT ${V[gw.ct]:-new}${R}"
    else
        CONTEXT="$(chip "CT ${V[$t.ct]}" "$CY") ${B}${V[$t.name]}${R} ${GR}· $t of $NT${R}"
    fi
}

# detect_raw runs inside run_task (a subshell), so it only writes a file;
# detect_task then loads that file into D in this shell.
detect_raw() {   # detect_raw TARGET CTID
    local t=$1 ct=$2
    cpush "$ct" "$STAGE/payload/detect.sh" /tmp/vpnguard-detect.sh 700 || return 1
    cexec "$ct" bash /tmp/vpnguard-detect.sh > "$STAGE/detect-$t.out" 2>/dev/null
    cexec "$ct" rm -f /tmp/vpnguard-detect.sh >/dev/null 2>&1
    grep -q '^OS_ID=' "$STAGE/detect-$t.out"
}
detect_task() {   # detect_task "label" TARGET CTID
    local k
    for k in "${!D[@]}"; do [[ $k == "$2."* ]] && unset "D[$k]"; done
    run_task "$1" detect_raw "$2" "$3" || return 1
    read_kv_into D "$2." < "$STAGE/detect-$2.out"
    [ -n "${D[$2.OS_ID]:-}" ]
}

pg_provider() {
    local t=$1 p def
    if is_express; then V[$t.provider]=${V[$t.provider]:-${D[$t.CUR_PROVIDER]:-}}; return 3; fi   # guessed from the config
    ctx "$t"
    page "VPN provider" "Which VPN service should ${V[$t.name]:-this} use? Containers can use different providers."
    def=${V[$t.provider]:-${D[$t.CUR_PROVIDER]:-proton}}
    pick p "Provider" "$def" \
        "mullvad|Mullvad|WireGuard · no port forwarding" \
        "proton|Proton VPN|WireGuard or OpenVPN · port forwarding via NAT-PMP" \
        "airvpn|AirVPN|WireGuard or OpenVPN · a port you reserve" \
        "other|Other|any WireGuard or OpenVPN provider" || return
    V[$t.provider]=$p
}

# where an existing config lives inside the target container
existing_conf_path() {
    local t=$1 s=$2
    if [ "$s" = backup ]; then [ "${D[$t.HAS_BACKUP]:-}" = 1 ] && echo /etc/vpnguard/slots/backup.conf; return; fi
    if [ "${D[$t.CUR_ROLE]:-}" != "" ]; then echo /etc/vpnguard/slots/primary.conf
    elif [ "${D[$t.HAS_WGCONF]:-}" = 1 ]; then echo /etc/wireguard/wg0.conf
    elif [ "${D[$t.HAS_OVPNCONF]:-}" = 1 ]; then echo /etc/openvpn/client/vpnguard.conf
    fi
}

pg_config() {   # pg_config TARGET [primary|backup]
    local t=$1 s=${2:-primary} want src f lname ct
    ct=${V[$t.ct]:-}
    if [ "$s" = backup ] && is_express && [ "${D[$t.HAS_BACKUP]:-}" != 1 ] && [ -z "${V[$t.backup.kind]:-}" ]; then return 3; fi
    while true; do
        ctx "$t"
        if [ "$s" = backup ]; then
            page "Backup config (failover)" "If the main server stops answering, the watchdog switches to this config by itself and tells you. Use a second server of the same type (${V[$t.primary.kind]:-WireGuard or OpenVPN}), from the same or another provider."
            local defb=n
            [ -n "${V[$t.backup.kind]:-}" ] || [ "${D[$t.HAS_BACKUP]:-}" = 1 ] && defb=y
            yn want "Add a backup config?" "$defb" || return
            if [ "$want" = n ]; then
                for k in kind file endpoints dns label src user pass fp lib; do unset "V[$t.backup.$k]"; done
                return 0
            fi
        else
            page "VPN config" "$(provider_hint "${V[$t.provider]}" "${V[$t.primary.kind]:-}")"
        fi

        local -a opts=()
        local have=""
        [ -n "$ct" ] && have=$(existing_conf_path "$t" "$s")
        [ -n "$have" ] && opts+=("keep|Keep the current one|already in the container")
        local nlib; nlib=$(lib_names | wc -l)
        [ "$nlib" -gt 0 ] && opts+=("lib|From your library|$nlib saved config$([ "$nlib" -gt 1 ] && echo s)")
        opts+=("paste|Paste it|copy the file's text and paste it here")
        opts+=("file|A file on this host|e.g. /root/proton.conf")
        local defsrc=${V[$t.$s.src]:-}
        if [ -z "$defsrc" ]; then
            if [ -n "$have" ]; then defsrc=keep; elif [ "$nlib" -gt 0 ]; then defsrc=lib; else defsrc=paste; fi
        fi
        pick src "Where's the config?" "$defsrc" "${opts[@]}" || return

        f="$STAGE/t$t.$s.src"
        local user="" pass="" hostfile=""
        case $src in
            keep)
                pct pull "$ct" "$have" "$f.raw" >/dev/null 2>&1 || { bad "could not read $have from CT $ct"; pause; continue; }
                tr -d '\r' < "$f.raw" > "$f"; rm -f "$f.raw"
                local authp="/etc/vpnguard/slots/$s.auth"
                if pct pull "$ct" "$authp" "$f.auth" >/dev/null 2>&1; then
                    user=$(sed -n 1p "$f.auth"); pass=$(sed -n 2p "$f.auth"); rm -f "$f.auth"
                fi ;;
            lib)
                echo
                local -a li=()
                local n who busy=""
                while IFS= read -r n; do
                    if who=$(fp_conflict "$t" "$s" "$(lib_fp "$n")" "${V[$t.ct]:-}"); then busy="$busy\n$n → $who"; continue; fi
                    li+=("$n|$n|$(lib_meta "$n" KIND) · $(provider_label "$(lib_meta "$n" PROVIDER)") · $(lib_meta "$n" ENDPOINTS | awk '{print $1}')")
                done < <(lib_names)
                if [ -n "$busy" ]; then
                    note "not offered, already in use (one connection per config):"
                    while IFS= read -r who; do [ -n "$who" ] && printf '        %s%s%s\n' "$GR" "$who" "$R"; done <<<"$(printf '%b' "$busy")"
                    echo
                fi
                if [ ${#li[@]} -eq 0 ]; then bad "every saved config is in use: paste a new one or add one in Settings"; pause; continue; fi
                pick lname "Which one?" "${V[$t.$s.lib]:-}" "${li[@]}" || { [ $? = 2 ] && return 2; continue; }
                tr -d '\r' < "$LIB/$lname.conf" > "$f"
                if [ -f "$LIB/$lname.auth" ]; then user=$(sed -n 1p "$LIB/$lname.auth"); pass=$(sed -n 2p "$LIB/$lname.auth"); fi
                V[$t.$s.lib]=$lname ;;
            paste)
                echo
                paste_block "$f.raw" || { bad "nothing was pasted"; pause; continue; }
                tr -d '\r' < "$f.raw" > "$f"; rm -f "$f.raw" ;;
            file)
                echo
                field hostfile "Path to the file" "${V[$t.$s.hostfile]:-}" v_path || { [ $? = 2 ] && return 2; continue; }
                tr -d '\r' < "$hostfile" > "$f" ;;
        esac

        if ! analyze_config "$t" "$s" "$f"; then
            bad "$VERR"; pause; continue
        fi
        V[$t.$s.fp]=$(cfg_fp_of "$t" "$s")
        local why
        if why=$(fp_conflict "$t" "$s" "${V[$t.$s.fp]}" "${V[$t.ct]:-}"); then
            bad "That config is already used by $why. Every connection needs its own config (a WireGuard key holds one session)."
            unset "V[$t.$s.fp]"; pause; continue
        fi
        if [ -z "${V[$t.provider]:-}" ]; then
            V[$t.provider]=""
            [ "$src" = lib ] && V[$t.provider]=$(lib_meta "$lname" PROVIDER)
            [ -n "${V[$t.provider]}" ] || V[$t.provider]=$(guess_provider "$t" "$s")
        fi
        if [ "$s" = backup ] && [ "${V[$t.backup.kind]}" != "${V[$t.primary.kind]}" ]; then
            bad "the backup has to be ${V[$t.primary.kind]} too (the main config is)"; pause; continue
        fi
        if [ "${V[$t.$s.kind]}" = wireguard ] && [ -z "${V[$t.$s.dns]}" ]; then
            local dns
            echo
            note "the config has no DNS line; DNS must go through the tunnel, so pick the VPN's resolver"
            field dns "DNS server inside the tunnel" "$(provider_dns "${V[$t.provider]}")" v_ip4 || { [ $? = 2 ] && return 2; continue; }
            V[$t.$s.dns]=$dns
        fi
        echo
        config_card "$t" "$s"
        echo

        if [ "${V[$t.$s.auth]}" = 1 ]; then
            if [ -z "$user" ]; then
                note "This OpenVPN config needs a login."
                field user "OpenVPN username" "${V[$t.$s.user]:-}" v_req || { [ $? = 2 ] && return 2; continue; }
                secret pass "OpenVPN password"
            else
                ok "login for $user is already stored"
            fi
        fi
        V[$t.$s.user]=$user; V[$t.$s.pass]=$pass; V[$t.$s.src]=$src; V[$t.$s.hostfile]=$hostfile

        if [ "$src" = paste ] || [ "$src" = file ]; then
            local save
            yn save "Save it to your config library (root-only, on this host)?" y || { [ $? = 2 ] && return 2; continue; }
            if [ "$save" = y ]; then
                local defname
                defname="${V[$t.provider]}-$(echo "${V[$t.$s.endpoints]}" | awk '{print $1}' | cut -d: -f1 | tr . -)"
                field lname "Name in the library" "$defname" v_name || { [ $? = 2 ] && return 2; continue; }
                lib_save "$lname" "$f" "${V[$t.$s.kind]}" "${V[$t.provider]}" "${V[$t.$s.endpoints]}" "$user" "$pass"
                ok "saved as $lname"
                V[$t.$s.lib]=$lname
            fi
        fi
        local use
        yn use "Use this config?" y || { [ $? = 2 ] && return 2; continue; }
        [ "$use" = y ] && return 0
    done
}

pg_backup() { pg_config "$1" backup; }

# Port forwarding. For a gateway, also which client gets the port.
pg_pf() {
    local t=$1
    if [ "$t" != gw ] && is_express; then express_fill "$t"; fi
    local prov=${V[$t.provider]} kind=${V[$t.primary.kind]} mode use
    ctx "$t"
    if [ "$prov" = mullvad ]; then V[$t.pf_mode]=none; return 3; fi
    page "Port forwarding" "Lets peers on the internet connect to your torrent client through the VPN, so you show as connectable. Prowlarr and similar apps don't need it."
    mode=${V[$t.pf_mode]:-${D[$t.CUR_PF_MODE]:-}}
    case $prov in
        proton)
            yn use "Use Proton's port forwarding? (paid plan, P2P server, NAT-PMP on)" "$([ "${mode:-natpmp}" = none ] && echo n || echo y)" || return
            if [ "$use" = y ]; then
                mode=natpmp
                if [ "$kind" = openvpn ]; then
                    note "for OpenVPN, +pmp gets added to your username automatically (that's how Proton turns it on)"
                    V[$t.pf_gw]=""
                else
                    V[$t.pf_gw]=10.2.0.1
                fi
            else mode=none; fi ;;
        airvpn)
            note "reserve a port first: Client Area → Ports"
            yn use "Use a forwarded port from AirVPN?" "$([ "${mode:-static}" = none ] && echo n || echo y)" || return
            if [ "$use" = y ]; then mode=static; else mode=none; fi ;;
        *)
            pick mode "Port forwarding" "${mode:-none}" \
                "none|None|peers can't connect in" \
                "static|A fixed port|the provider gave you a port number" \
                "natpmp|NAT-PMP|the port is requested and kept alive automatically" || return
            if [ "$mode" = natpmp ]; then
                local gw
                field gw "NAT-PMP gateway inside the tunnel (- = the one the server pushes)" "${V[$t.pf_gw]:-$([ "$kind" = openvpn ] && echo - || echo 10.2.0.1)}" v_any || return
                [ -n "$gw" ] && ! is_ip4 "$gw" && { bad "not an IPv4 address"; pause; return 1; }
                V[$t.pf_gw]=$gw
            fi ;;
    esac
    V[$t.pf_mode]=$mode
    if [ "$mode" = static ]; then
        local port
        field port "Forwarded port" "${V[$t.pf_port]:-${D[$t.CUR_PF_PORT]:-${D[$t.QBIT_LISTEN_PORT]:-}}}" v_port || return
        V[$t.pf_port]=$port
    fi
    [ "$mode" = none ] && return 0

    # which container gets the port, and is it qBittorrent?
    local qt="$t" qip="127.0.0.1"
    if [ "$t" = gw ]; then
        local -a items=() c
        for c in ${V[gw.clients]}; do items+=("$c|CT $c ${V[c$c.name]}|${V[c$c.ip]}"); done
        [ ${#items[@]} -gt 0 ] || { warn "no containers behind the gateway yet, so the port has nowhere to go"; V[$t.pf_mode]=none; pause; return 0; }
        local tgt
        echo
        pick tgt "Which container gets the forwarded port?" "${V[gw.pf_target]:-$(echo "${V[gw.clients]}" | awk '{print $1}')}" "${items[@]}" || return
        V[gw.pf_target]=$tgt
        qt="c$tgt"; qip=${V[c$tgt.ip]}
    fi
    V[$t.qbit_sync]=0
    if [ -n "${D[$qt.QBIT_CONF]:-}" ]; then
        local sync
        echo
        yn sync "Let the script set qBittorrent's listening port for you?" y || return
        if [ "$sync" = y ]; then
            V[$t.qbit_sync]=1
            local scheme=http url
            [ "${D[$qt.QBIT_HTTPS]:-0}" = 1 ] && scheme=https
            field url "qBittorrent WebUI address" "${V[$t.qbit_url]:-$scheme://$qip:${D[$qt.QBIT_WEBUI_PORT]:-8080}}" v_url || return
            V[$t.qbit_url]=$url
            if [ "$t" != gw ] && [ "${D[$qt.QBIT_LOCALAUTH]:-1}" = 0 ]; then
                note "qBittorrent skips the login for localhost, no password needed"
                V[$t.qbit_user]=""
            elif [ "$t" != gw ] && [ "${D[$t.HAS_QBIT_CRED]:-}" = 1 ] && [ -z "${V[$t.qbit_user]:-}" ]; then
                local keep
                yn keep "Keep the qBittorrent login that's already stored?" y || return
                [ "$keep" = y ] && V[$t.qbit_keep]=1
            fi
            if [ "${V[$t.qbit_keep]:-0}" != 1 ] && { [ "$t" = gw ] || [ "${D[$qt.QBIT_LOCALAUTH]:-1}" != 0 ]; }; then
                local u pw
                field u "qBittorrent WebUI username" "${V[$t.qbit_user]:-admin}" v_req || return
                secret pw "qBittorrent WebUI password"
                V[$t.qbit_user]=$u; V[$t.qbit_pass]=$pw
                note "stored root-only, used only to change the listening port"
            fi
        fi
    elif [ "$mode" = natpmp ]; then
        echo
        warn "the port changes over time and this isn't qBittorrent, so you'd update it by hand"
        pause
    fi
    return 0
}

