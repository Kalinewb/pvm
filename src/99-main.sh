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

# vpn-lxc update [--check] [ref] : fetch the latest release, verify its checksum, install it
update_self() {
    local check=0 ref=main tmp want have newv oldv dest=/usr/local/sbin/vpn-lxc
    for a in "$@"; do case $a in --check) check=1 ;; *) ref=$a ;; esac; done
    command -v curl >/dev/null 2>&1 || die "curl is needed"
    tmp=$(mktemp -d) || die "could not create a temp dir"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN
    curl -fsSL -m 60 "$REPO_RAW/$ref/dist/vpn-lxc.sh" -o "$tmp/s" || die "could not download the latest version (no internet, or no such version: $ref)"
    curl -fsSL -m 30 "$REPO_RAW/$ref/dist/vpn-lxc.sh.sha256" -o "$tmp/s.sha" || die "could not download the checksum"
    want=$(cut -d' ' -f1 "$tmp/s.sha"); have=$(sha256sum "$tmp/s" | cut -d' ' -f1)
    [ "$want" = "$have" ] || die "checksum mismatch, nothing was changed"
    head -n 1 "$tmp/s" | grep -q '^#!/bin/bash' && bash -n "$tmp/s" || die "the download is not a valid script, nothing was changed"
    newv=$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$tmp/s" | head -n 1); oldv=$VERSION
    if [ -f "$dest" ] && cmp -s "$tmp/s" "$dest"; then
        printf '\n    %s✔%s already up to date (version %s)\n\n' "$OK" "$R" "$oldv"; return 0
    fi
    if [ "$check" = 1 ]; then
        printf '\n    %s▲%s version %s is available (you have %s). Run: vpn-lxc update\n\n' "$WA" "$R" "$newv" "$oldv"; return 0
    fi
    install -m 755 "$tmp/s" "$dest.new" && mv -f "$dest.new" "$dest"
    printf '\n    %s✔%s updated %s → %s at %s\n' "$OK" "$R" "$oldv" "$newv" "$dest"
    note "the watchdog uses the new version from its next round"
    note "containers keep their current setup; open vpn-lxc and re-run Protect containers on one to refresh its in-container tools"
    echo
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
  bash vpn-lxc.sh update                install the latest version (update --check only looks)
  bash vpn-lxc.sh version
EOF
}

main() {
    case ${1:-} in -h|--help|help) usage; exit 0 ;; version|--version) echo "vpn-lxc $VERSION"; exit 0 ;; esac
    [ "$(id -u)" -eq 0 ] || die "run this as root on the Proxmox host"
    command -v pct >/dev/null 2>&1 || die "pct not found: run this on the Proxmox host, not inside a container"
    install -d -m 700 "$ETC" "$REG" "$LIB"
    case ${1:-menu} in
        menu)     main_menu ;;
        update)   shift; update_self "$@" ;;
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

