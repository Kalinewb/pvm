# ════════════════════════════════════════════════════════════
#  Watchdog (runs from the systemd timer, no screen)
# ════════════════════════════════════════════════════════════
watchdog_round() {
    [ "$(set_get WATCHDOG)" = 0 ] && return 0
    local ra fa id role out sf fails down lastpf name
    ra=$(set_get WD_RESTART_AFTER); ra=${ra:-2}
    fa=$(set_get WD_FAILOVER_AFTER); fa=${fa:-4}
    install -d -m 700 "$VARD"
    for id in $(reg_ids); do
        role=$(reg_get "$id" ROLE)
        case $role in tunnel|gateway) ;; *) continue ;; esac
        [ "$(ct_status "$id")" = running ] || continue
        name=$(reg_get "$id" NAME); name=${name:-CT $id}
        out=$(timeout 60 pct exec "$id" -- /usr/local/sbin/vpn-status --health 2>/dev/null)
        [ -n "$out" ] || { echo "CT $id: no answer from vpn-status"; continue; }
        local -A H=()
        read_kv_into H "" <<<"$out"
        sf="$VARD/$id.state"
        fails=$(kvfile_get "$sf" FAILS); fails=${fails:-0}
        down=$(kvfile_get "$sf" DOWN); down=${down:-0}
        lastpf=$(kvfile_get "$sf" LAST_PF)
        if [ "${H[HEALTH]:-}" = ok ]; then
            if [ "$down" = 1 ]; then
                echo "CT $id: healthy again (${H[ACTIVE]} config)"
                notify "$name: VPN is back" "The tunnel works again, on the ${H[ACTIVE]} config." 3 white_check_mark
            fi
            fails=0; down=0
            if [ -n "${H[APPS_DOWN]:-}" ]; then
                echo "CT $id: starting ${H[APPS_DOWN]}"
                # shellcheck disable=SC2086
                pct exec "$id" -- systemctl start ${H[APPS_DOWN]}
            fi
            if [ -n "${H[PF_PORT]:-}" ]; then
                if [ -n "$lastpf" ] && [ "${H[PF_PORT]}" != "$lastpf" ]; then
                    echo "CT $id: forwarded port $lastpf → ${H[PF_PORT]}"
                    notify "$name: new forwarded port" "The VPN gave a new port: ${H[PF_PORT]} (was $lastpf). qBittorrent is updated automatically if it's synced." 2 arrows_counterclockwise
                fi
                lastpf=${H[PF_PORT]}
            fi
        else
            fails=$((fails + 1))
            echo "CT $id: unhealthy ($fails): ${H[REASON]:-?}"
            if [ "$fails" -eq "$ra" ]; then
                down=1
                notify "$name: VPN down" "${H[REASON]:-The tunnel stopped working}. Restarting it. Nothing leaks: the kill switch keeps traffic blocked." 4 warning
                pct exec "$id" -- systemctl restart "${H[UNIT]}"
            elif [ "$fails" -ge "$fa" ] && [ "${H[HAS_BACKUP]:-0}" = 1 ] && [ "${H[ACTIVE]:-primary}" = primary ]; then
                notify "$name: switching to the backup config" "The primary config still fails (${H[REASON]:-?}) after a restart." 4 repeat
                pct exec "$id" -- /usr/local/sbin/vpnguard-switch backup
                fails=0
            elif [ "$fails" -gt "$ra" ] && [ $(( (fails - ra) % ra )) -eq 0 ]; then
                pct exec "$id" -- systemctl restart "${H[UNIT]}"
            fi
        fi
        { echo "FAILS=$fails"; echo "DOWN=$down"; echo "LAST_PF=$lastpf"; echo "CHECKED=$(date +%s)"; } > "$sf"
        unset H
    done
}

