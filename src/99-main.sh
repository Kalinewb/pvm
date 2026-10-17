# ════════════════════════════════════════════════════════════
#  Main
# ════════════════════════════════════════════════════════════
main_menu() {
    local m rc
    while true; do
        FLOW=""; PAGE_TOTAL=0; CONTEXT=""; DIR=fwd
        new_stage
        cls
        big_logo
        echo
        dashboard
        echo
        pick m "What now?" "${LAST_CHOICE:-tunnel}" \
            "tunnel|Protect containers|each one gets its own VPN" \
            "gateway|VPN gateway|one VPN for many containers, on a private bridge" \
            "live|Live dashboard|auto-refreshing view of everything" \
            "status|Check a container|full leak and kill-switch test" \
            "switch|Switch config|move a tunnel to its backup (or back)" \
            "settings|Settings|watchdog, alerts, saved configs" \
            "remove|Remove|take the VPN off a container" \
            "quit|Quit|"
        rc=$?
        [ "$rc" = 2 ] && break
        [ "$rc" = 1 ] && continue
        LAST_CHOICE=$m
        case $m in
            tunnel)   V=(); D=(); tunnel_wizard ;;
            gateway)  V=(); D=(); gateway_wizard ;;
            status)   status_screen ;;
            live)     live_screen ;;
            switch)   switch_screen ;;
            settings) settings_screen ;;
            remove)   remove_screen ;;
            quit)     break ;;
        esac
    done
    cls
    printf '\n  %s  %sbye%s\n\n' "$(grad '◆ VPN·LXC')" "$GR" "$R"
}

usage() {
    cat <<EOF
vpn-lxc.sh $VERSION: VPN for Proxmox containers (per-container tunnels or a VPN gateway)

  bash vpn-lxc.sh                       the full-screen app (dashboard + menu)
  bash vpn-lxc.sh dashboard             print the dashboard once
  bash vpn-lxc.sh live                  auto-refreshing dashboard
  bash vpn-lxc.sh status CTID           status screen for one container
  bash vpn-lxc.sh switch CTID primary|backup
  bash vpn-lxc.sh watchdog              one watchdog round (the systemd timer runs this)
EOF
}

main() {
    case ${1:-} in -h|--help|help) usage; exit 0 ;; esac
    [ "$(id -u)" -eq 0 ] || die "run this as root on the Proxmox host"
    command -v pct >/dev/null 2>&1 || die "pct not found: run this on the Proxmox host, not inside a container"
    install -d -m 700 "$ETC" "$REG" "$LIB"
    case ${1:-menu} in
        menu)     main_menu ;;
        watchdog) watchdog_round ;;
        dashboard|list) new_stage; dashboard ;;
        live)     live_screen ;;
        status)   [[ ${2:-} =~ ^[0-9]+$ ]] || die "usage: vpn-lxc.sh status CTID"
                  cexec "$2" env FORCE_COLOR="$FANCY" /usr/local/sbin/vpn-status ;;
        switch)   [[ ${2:-} =~ ^[0-9]+$ ]] && [[ ${3:-} =~ ^(primary|backup)$ ]] || die "usage: vpn-lxc.sh switch CTID primary|backup"
                  cexec "$2" /usr/local/sbin/vpnguard-switch "$3" ;;
        *)        usage; exit 1 ;;
    esac
}

main "$@"

