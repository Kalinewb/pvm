# ════════════════════════════════════════════════════════════
#  Smaller screens
# ════════════════════════════════════════════════════════════
pick_managed() {   # pick_managed VAR "roles" "prompt"
    local -n __o=$1
    local __roles=" $2 " __id
    local -a __items=()
    for __id in $(reg_ids); do
        case "$__roles" in *" $(reg_get "$__id" ROLE) "*) ;; *) continue ;; esac
        __items+=("$__id|$__id $(reg_get "$__id" NAME)|$(reg_get "$__id" ROLE) · $(ct_status "$__id")")
    done
    [ ${#__items[@]} -gt 0 ] || { warn "nothing to pick here yet"; pause; return 1; }
    pick __o "${3:-Which container?}" "" "${__items[@]}"
}

status_screen() {
    FLOW="status"; PAGE_TOTAL=0; CONTEXT=""
    page "Status screen" "The full check, run inside the container."
    local id
    pick_managed id "tunnel gateway client" || return 0
    if [ "$(reg_get "$id" ROLE)" = client ]; then
        local g ip; g=$(reg_get "$id" GATEWAY)
        ip=$(cexec "$id" sh -c 'command -v curl >/dev/null && curl -4 -s -m 6 https://ipinfo.io/ip' 2>/dev/null)
        echo
        note "CT $id sits behind gateway CT $g; it has no tunnel of its own. It exits as: ${ip:-no answer}"
        note "showing the gateway's status:"
        pause
        id=$g
    fi
    cls
    cexec "$id" env FORCE_COLOR="$FANCY" /usr/local/sbin/vpn-status
    pause
}

switch_screen() {
    FLOW="primary ⇄ backup"; PAGE_TOTAL=0; CONTEXT=""
    page "Primary ⇄ backup" "Switch a tunnel to its other config by hand. The watchdog does this by itself when the primary keeps failing."
    local id act other a
    pick_managed id "tunnel gateway" || return 0
    act=$(cexec "$id" cat /etc/vpnguard/active-slot 2>/dev/null); act=${act:-primary}
    cexec "$id" test -f /etc/vpnguard/slots/backup.conf || { warn "CT $id has no backup config (add one with the setup)"; pause; return 0; }
    [ "$act" = primary ] && other=backup || other=primary
    echo
    note "CT $id is using its $act config"
    yn a "Switch to the $other config?" y || return 0
    [ "$a" = y ] || return 0
    run_task "switching CT $id to $other" cexec "$id" /usr/local/sbin/vpnguard-switch "$other" \
        && notify "$(reg_get "$id" NAME): switched to $other" "Switched by hand from the pvm menu." 2 repeat
    pause
}

library_screen() {
    while true; do
        FLOW="config library"; PAGE_TOTAL=0; CONTEXT=""
        page "Config library" "Saved VPN configs on this host ($LIB, root-only). Pick one during setup instead of pasting again."
        local n any=0
        box_top "Saved configs"
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            any=1
            box_row "$(printf '%s%-24.24s%s %-9s %-8s %s%-15s %s%s' "$B" "$n" "$R" "$(lib_meta "$n" KIND)" "$(provider_label "$(lib_meta "$n" PROVIDER)" | cut -d' ' -f1)" "$GR" "$(lib_meta "$n" ENDPOINTS | awk '{print $1}' | cut -d: -f1)" "$(lib_meta "$n" ADDED | cut -d' ' -f1)" "$R")"
        done < <(lib_names)
        [ "$any" = 0 ] && box_row "${GR}empty${R}"
        box_bot
        echo
        local a
        pick a "What now?" back "add|Add a config|paste it or point to a file" "delete|Delete one|" "back|Back|" || return 0
        case $a in
            add) library_add || [ $? != 2 ] || return 0 ;;
            delete)
                local -a items=()
                while IFS= read -r n; do [ -n "$n" ] && items+=("$n|$n|$(lib_meta "$n" KIND)"); done < <(lib_names)
                [ ${#items[@]} -gt 0 ] || continue
                local del sure
                echo; pick del "Delete which?" "" "${items[@]}" || continue
                yn sure "Delete $del? (it is kept in $LIB/.trash)" n || continue
                [ "$sure" = y ] && lib_delete "$del" && ok "deleted $del" && nap 0.6 ;;
            back) return 0 ;;
        esac
    done
}

library_add() {
    new_stage
    local t=lib how f="$STAGE/lib-new.conf" p user="" pass="" name path
    page "Add to the library"
    pick how "How?" paste "paste|Paste it|" "file|A file on this host|" || return
    if [ "$how" = paste ]; then echo; paste_block "$f.raw" || return 1; tr -d '\r' < "$f.raw" > "$f"
    else echo; field path "Path" "" v_path || return; tr -d '\r' < "$path" > "$f"; fi
    analyze_config lib primary "$f" || { bad "$VERR"; pause; return 1; }
    echo; config_card lib primary; echo
    pick p "Provider" proton "mullvad|Mullvad|" "proton|Proton VPN|" "airvpn|AirVPN|" "other|Other|" || return
    if [ "${V[lib.primary.auth]}" = 1 ]; then
        field user "OpenVPN username" "" v_req || return
        secret pass "OpenVPN password"
    fi
    field name "Name" "$p-$(echo "${V[lib.primary.endpoints]}" | awk '{print $1}' | cut -d: -f1 | tr . -)" v_name || return
    lib_save "$name" "$f" "${V[lib.primary.kind]}" "$p" "${V[lib.primary.endpoints]}" "$user" "$pass"
    ok "saved as $name"
    if [ "$how" = file ]; then
        local del; yn del "Delete $path now? (the library has a copy)" y && [ "$del" = y ] && rm -f "$path" && ok "deleted $path"
    fi
    pause
}

settings_screen() {
    while true; do
        FLOW="watchdog & notifications"; PAGE_TOTAL=0; CONTEXT=""
        page "Watchdog & notifications" "Every 2 minutes this host checks each tunnel. When one stops working it restarts it, then switches to the backup config if there is one, and tells you."
        local wd ra fa nk timer
        wd=$(set_get WATCHDOG); wd=${wd:-1}
        ra=$(set_get WD_RESTART_AFTER); ra=${ra:-2}
        fa=$(set_get WD_FAILOVER_AFTER); fa=${fa:-4}
        nk=$(set_get NOTIFY_KIND); nk=${nk:-none}
        timer="${ER}not installed${R}"
        systemctl is-active --quiet pvm-watchdog.timer 2>/dev/null && timer="${OK}running${R}"
        box_top "Now"
        box_row "${GR}Watchdog${R}         $([ "$wd" = 1 ] && echo "${OK}on${R}" || echo "${ER}off${R}") · timer $timer"
        box_row "${GR}Restart after${R}    $ra failed checks ($((ra * 2)) min)"
        box_row "${GR}Failover after${R}   $fa failed checks ($((fa * 2)) min), if a backup config exists"
        box_row "${GR}Notifications${R}    $nk $(set_get NOTIFY_URL)$([ "$nk" = ntfy ] && echo "/$(set_get NOTIFY_TOPIC)")"
        box_bot
        echo
        local a
        pick a "Change" back \
            "toggle|Watchdog on/off|" \
            "timing|Restart / failover timing|" \
            "notify|Notifications|ntfy or Gotify" \
            "test|Send a test notification|" \
            "library|Saved VPN configs|add, list or delete" \
            "back|Back|" || return 0
        case $a in
            toggle)
                if [ "$wd" = 1 ]; then
                    set_set WATCHDOG 0; systemctl disable --now pvm-watchdog.timer >/dev/null 2>&1; ok "watchdog off"
                else
                    set_set WATCHDOG 1; run_task "installing the watchdog timer" install_watchdog
                fi
                nap 0.8 ;;
            timing)
                local x y
                field x "Restart the tunnel after how many failed checks" "$ra" v_port || continue
                field y "Switch to the backup after how many failed checks" "$fa" v_port || continue
                [ "$y" -gt "$x" ] || { bad "failover has to come after the restart"; pause; continue; }
                set_set WD_RESTART_AFTER "$x"; set_set WD_FAILOVER_AFTER "$y" ;;
            notify)
                local nkind url topic token
                echo
                pick nkind "Send notifications with" "$nk" \
                    "none|Nothing|" \
                    "ntfy|ntfy|ntfy.sh or your own ntfy server" \
                    "gotify|Gotify|your Gotify server" || continue
                case $nkind in
                    ntfy)
                        field url "ntfy server" "$(set_get NOTIFY_URL | grep . || echo https://ntfy.sh)" v_url || continue
                        [ -z "$url" ] && url=https://ntfy.sh
                        set_set NOTIFY_KIND ntfy
                        field topic "Topic (long and random if you use ntfy.sh)" "$(set_get NOTIFY_TOPIC | grep . || echo "pvm-$(tr -dc a-z0-9 < /dev/urandom | head -c 10)")" v_name || continue
                        secret token "Access token (optional, ⏎ to skip)"
                        set_set NOTIFY_URL "$url"; set_set NOTIFY_TOPIC "$topic"; set_set NOTIFY_TOKEN "$token"
                        note "subscribe to $topic in the ntfy app" ;;
                    gotify)
                        field url "Gotify server" "$(set_get NOTIFY_URL)" v_url || continue
                        secret token "Application token"
                        set_set NOTIFY_KIND gotify; set_set NOTIFY_URL "$url"; set_set NOTIFY_TOKEN "$token" ;;
                    none) set_set NOTIFY_KIND none ;;
                esac
                pause ;;
            test)
                if [ "$nk" = none ]; then warn "notifications are off: pick ntfy or Gotify first"
                elif run_task "sending a test" notify "pvm test" "Notifications from $(hostname) work." 3 white_check_mark; then ok "check your phone"
                else bad "it didn't go through: check the server, topic and token"; fi
                pause ;;
            library) library_screen ;;
            back) return 0 ;;
        esac
    done
}

remove_screen() {
    FLOW="remove"; PAGE_TOTAL=0; CONTEXT=""
    page "Remove or detach" "Take the VPN off a container, move one out from behind the gateway, or take the gateway down."
    local id role a restore stop
    pick_managed id "tunnel gateway client" || return 0
    role=$(reg_get "$id" ROLE)
    new_stage; write_payload "$STAGE/payload"
    echo
    case $role in
        tunnel)
            warn "CT $id loses its kill switch: if the tunnel drops, traffic goes out unprotected"
            yn restore "Put back the iptables rules it had before the first setup?" y || return 0
            yn stop "Stop its VPN tunnel too?" n || return 0
            yn a "Remove now?" n || return 0
            [ "$a" = y ] || return 0
            cpush "$id" "$STAGE/payload/remove.sh" /tmp/vpnguard-remove.sh 700
            cexec "$id" bash /tmp/vpnguard-remove.sh "$([ "$restore" = y ] && echo 1 || echo 0)" "$([ "$stop" = y ] && echo 1 || echo 0)" 2>&1 | render_stream
            local ons; ons=$(reg_get "$id" ORIG_NS)
            pct set "$id" --revert nameserver >/dev/null 2>&1   # a running container keeps our change as "pending"
            if [ -n "$ons" ]; then pct set "$id" --nameserver "$ons" >/dev/null 2>&1
            else pct set "$id" --delete nameserver >/dev/null 2>&1; fi
            reg_del "$id"; ok "done · the container's own DNS setting is back" ;;
        client)
            yn a "Move CT $id back to the network it had before?" y || return 0
            [ "$a" = y ] && run_task "moving CT $id back" client_detach "$id" ;;
        gateway)
            local c clients=""
            for c in $(reg_ids); do [ "$(reg_get "$c" ROLE)" = client ] && [ "$(reg_get "$c" GATEWAY)" = "$id" ] && clients="$clients $c"; done
            [ -n "$clients" ] && warn "these move back to their old networks first:$clients"
            local destroy br
            yn destroy "Also delete the gateway container CT $id?" n || return 0
            br=$(reg_get "$id" BRIDGE)
            yn a "Take the gateway down now?" n || return 0
            [ "$a" = y ] || return 0
            for c in $clients; do run_task "moving CT $c back" client_detach "$c"; done
            if [ "$destroy" = y ]; then
                run_task "deleting CT $id" bash -c "pct stop $id >/dev/null 2>&1; pct destroy $id --purge"
                local rmbr
                yn rmbr "Remove the bridge $br from this host too?" y || true
                [ "${rmbr:-n}" = y ] && run_task "removing bridge $br" remove_bridge "$br"
            else
                cpush "$id" "$STAGE/payload/remove.sh" /tmp/vpnguard-remove.sh 700
                cexec "$id" bash /tmp/vpnguard-remove.sh 0 1 2>&1 | render_stream
            fi
            reg_del "$id" ;;
    esac
    pause
}

remove_bridge() {
    local br=$1 tmp
    cp -a "$IFACES_FILE" "$IFACES_FILE.pvm.$(date +%Y%m%d-%H%M%S)"
    tmp=$(mktemp)
    awk -v br="$br" '
        $1 == "auto" && $2 == br { skip = 1; if (held > 0) held--; next }   # also drops the blank line we added in front of it
        skip && /^#VPN-only network \((PVM|vpn-lxc.sh)\)/ { skip = 0; next }
        skip && ($0 ~ /^iface / || $0 ~ /^[ \t]/ || $0 == "") { next }
        $0 == "" { held++; next }
        { skip = 0; while (held > 0) { print ""; held-- } print }
        END { while (held > 0) { print ""; held-- } }' "$IFACES_FILE" > "$tmp" && cat "$tmp" > "$IFACES_FILE"
    rm -f "$tmp"
    # let ifupdown2 take the bridge down itself: deleting the link first leaves it with a stale state and every later ifreload fails
    ifreload -a
    ip link show "$br" >/dev/null 2>&1 && ip link delete "$br"
    return 0
}

