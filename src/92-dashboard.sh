# ════════════════════════════════════════════════════════════
#  Dashboard
# ════════════════════════════════════════════════════════════
probe_all() {   # probe_all DIR : brief status of every managed container, in parallel
    local d=$1 id role
    mkdir -p "$d"; rm -f "$d"/*
    for id in $(reg_ids); do
        [ "$(ct_status "$id")" = running ] || continue
        role=$(reg_get "$id" ROLE)
        case $role in
            tunnel|gateway) cexec "$id" /usr/local/sbin/vpn-status --brief > "$d/$id" 2>/dev/null & ;;
            client) cexec "$id" sh -c 'command -v curl >/dev/null && curl -4 -s -m 6 https://ipinfo.io/ip || wget -qO- -T 6 https://ipinfo.io/ip' > "$d/$id.ip" 2>/dev/null & ;;
        esac
    done
    wait
    return 0
}

ago() { local s=$1; if [ "$s" -lt 0 ]; then echo "—"; elif [ "$s" -lt 120 ]; then echo "${s}s"; else echo "$((s / 60))m"; fi; }

hb() { awk -v b="${1:-0}" 'BEGIN { split("B KiB MiB GiB TiB", u); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf "%.1f%s", b, u[i] }'; }

dash_row() {   # dash_row ID [indent]
    local id=$1 d="$STAGE/dash" name role st dot line nw=12 more=""
    [ "$W" -ge 100 ] && nw=18; [ "$W" -ge 130 ] && nw=24
    name=$(reg_get "$id" NAME); role=$(reg_get "$id" ROLE); st=$(ct_status "$id")
    local -A BR=()
    [ -f "$d/$id" ] && read_kv_into BR "" < "$d/$id"
    if [ "$st" != running ]; then
        DASH_OFF=$((DASH_OFF + 1))
        dot="$DG○$R"; line=$(printf '%s %-4s %-*.*s %s%-7s%s %s%s%s' "$dot" "$id" "$nw" "$nw" "$name" "$GR" "$role" "$R" "$DG" "$st" "$R")
    elif [ "$role" = client ]; then
        local ip gwexit
        ip=$(cat "$d/$id.ip" 2>/dev/null)
        gwexit=$(kvfile_get "$d/$(reg_get "$id" GATEWAY)" EXIT_IP)
        if [ -n "$ip" ] && [ "$ip" = "$gwexit" ]; then dot="$OK●$R"; DASH_OK=$((DASH_OK + 1)); else dot="$WA●$R"; DASH_BAD=$((DASH_BAD + 1)); fi
        line=$(printf '  %s└%s %s %-4s %-*.*s %s%-13s%s %s' "$DG" "$R" "$dot" "$id" "$((nw - 1))" "$((nw - 1))" "$name" "$GR" "$(reg_get "$id" IP)" "$R" \
            "$([ -n "$ip" ] && [ "$ip" = "$gwexit" ] && echo "${OK}via gateway${R}" || echo "${WA}${ip:-no answer}${R}")")
    else
        local prov proto exit extra=""
        prov=$(provider_label "${BR[PROVIDER]:-$(reg_get "$id" PROVIDER)}"); proto=${BR[PROTO]:-$(reg_get "$id" PROTO)}
        [ "$proto" = wireguard ] && proto=wg || proto=ovpn
        if [ "${BR[TUNNEL]:-}" = up ] && [ -n "${BR[EXIT_IP]:-}" ]; then dot="$OK●$R"; exit="${BR[EXIT_IP]} ${GR}${BR[COUNTRY]:-}${R}"; DASH_OK=$((DASH_OK + 1))
        elif [ "${BR[TUNNEL]:-}" = up ]; then dot="$WA●$R"; exit="${WA}no traffic${R}"; DASH_BAD=$((DASH_BAD + 1))
        else dot="$ER●$R"; exit="${ER}tunnel down${R}"; DASH_BAD=$((DASH_BAD + 1)); fi
        [ -n "${BR[PF_PORT]:-}" ] && extra="$extra ${CY}⇅${BR[PF_PORT]}${R}"
        [ "${BR[ACTIVE]:-}" = backup ] && extra="$extra ${WA}⟲backup${R}"
        [ "${BR[PROTO]:-}" = wireguard ] && [ "${BR[HS_AGE]:--1}" -ge 0 ] && extra="$extra ${DG}$(ago "${BR[HS_AGE]}")${R}"
        if [ "$W" -ge 100 ]; then
            [ "$role" = gateway ] && more="  ${DG}$(reg_get "$id" BRIDGE) · $(reg_get "$id" LAN_ADDR)${R}"
            [ "$W" -ge 130 ] && [ -n "${BR[RX]:-}" ] && more="$more  ${DG}▼$(hb "${BR[RX]}") ▲$(hb "${BR[TX]:-0}")${R}"
        fi
        line=$(printf '%s %-4s %-*.*s %s%-7s%s %s %s%s%s' "$dot" "$id" "$nw" "$nw" "$name" "$GR" "$role" "$R" "$(padr "${prov%% *} · $proto" 14)" "$exit" "$extra" "$more")
    fi
    box_row "$line"
}

DASH_OK=0; DASH_BAD=0; DASH_OFF=0
dashboard() {   # dashboard [cached] : "cached" draws what probe_all already collected
    local ids gw id
    ids=$(reg_ids)
    if [ -z "$ids" ]; then
        box_top "Your containers"
        box_row "${GR}Nothing is protected yet. Choose ${R}${B}Protect containers${R}${GR} or ${R}${B}VPN gateways${R}${GR}: Express takes about a minute.${R}"
        box_bot
        return
    fi
    if [ "${1:-}" != cached ]; then
        run_task "checking $(wc -w <<<"$ids") containers" probe_all "$STAGE/dash"
        [ "$FANCY" = 1 ] && printf '\e[1A\e[2K'
    fi
    DASH_OK=0; DASH_BAD=0; DASH_OFF=0
    box_top "Your containers"
    for id in $ids; do [ "$(reg_get "$id" ROLE)" = tunnel ] && dash_row "$id"; done
    for gw in $ids; do
        [ "$(reg_get "$gw" ROLE)" = gateway ] || continue
        dash_row "$gw"
        for id in $ids; do [ "$(reg_get "$id" ROLE)" = client ] && [ "$(reg_get "$id" GATEWAY)" = "$gw" ] && dash_row "$id"; done
    done
    for id in $ids; do
        [ "$(reg_get "$id" ROLE)" = client ] || continue
        gw=$(reg_get "$id" GATEWAY)
        [ "$(reg_get "$gw" ROLE)" = gateway ] && continue
        box_row "${WA}▲${R} CT $id $(reg_get "$id" NAME) is set to gateway CT $gw, which isn't set up (use Remove)"
    done
    local wd="${ER}off${R}"
    systemctl is-active --quiet vpn-lxc-watchdog.timer 2>/dev/null && wd="${OK}on${R}"
    local nk; nk=$(set_get NOTIFY_KIND); nk=${nk:-none}
    box_row "${DG}$(rep ─ $((W - 4)))${R}"
    local sum="${OK}✔ $DASH_OK protected${R}"
    [ "$DASH_BAD" -gt 0 ] && sum="$sum   ${WA}▲ $DASH_BAD need attention${R}"
    [ "$DASH_OFF" -gt 0 ] && sum="$sum   ${DG}○ $DASH_OFF stopped${R}"
    box_row "$sum"
    box_row "${GR}watchdog${R} $wd   ${GR}notifications${R} $nk   ${GR}library${R} $(lib_names | wc -l) configs"
    box_bot
}

# live view: refreshes every 10 s, any key goes back
live_screen() {
    local k
    new_stage
    if [ "$INTERACTIVE" != 1 ]; then dashboard; return 0; fi
    cls; printf '\n    %sgathering the first reading...%s\n' "$GR" "$R"
    while true; do
        probe_all "$STAGE/dash"
        FLOW="live dashboard"; PAGE_TOTAL=0; CONTEXT=""
        page "Live dashboard" "Refreshes every 10 seconds. Press any key to go back."
        dashboard cached
        printf '\n    %s%s%s\n' "$GR" "updated $(date +%H:%M:%S)" "$R"
        cur_hide
        if IFS= read -rsn1 -t 10 k; then cur_show; return 0; fi
    done
}

