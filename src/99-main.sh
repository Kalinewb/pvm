# ════════════════════════════════════════════════════════════
#  Main
# ════════════════════════════════════════════════════════════
main_menu() {
    local m rc
    screen_enter
    while true; do
        FLOW=""; PAGE_TOTAL=0; CONTEXT=""; DIR=fwd
        new_stage; fit
        cls
        big_logo
        echo
        dashboard
        echo
        pick m "What now?" "${LAST_CHOICE:-tunnel}" \
            "tunnel|Protect containers|each one gets its own VPN" \
            "gateway|VPN gateways|named gateways: one VPN for many containers, on a private bridge" \
            "ports|Port forwarding|what the VPN forwards in, and what your home network can reach" \
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
            ports)    port_screen ;;
            live)     live_screen ;;
            switch)   switch_screen ;;
            settings) settings_screen ;;
            remove)   remove_screen ;;
            quit)     break ;;
        esac
    done
    screen_leave
    printf '\n  %s  %sbye%s\n\n' "$(grad '◆ VPN·LXC')" "$GR" "$R"
}

# The command is `pvm` or `vpn`, in any capitals (PVM, Vpn, ...): one real file plus a symlink per spelling.
case_variants() {   # case_variants pvm : every upper/lower mix, one per line
    local w=$1 out=("") n o i c u l
    for ((i = 0; i < ${#w}; i++)); do
        c=${w:i:1}; u=${c^^}; l=${c,,}; n=()
        for o in "${out[@]}"; do n+=("$o$l"); [ "$u" != "$l" ] && n+=("$o$u"); done
        out=("${n[@]}")
    done
    printf '%s\n' "${out[@]}"
}
install_links() {
    local real=$BIN_DIR/pvm name p
    [ -f "$real" ] || return 0
    for name in $(case_variants pvm) $(case_variants vpn) vpn-lxc; do
        [ "$name" = pvm ] && continue
        p=$BIN_DIR/$name
        if [ -e "$p" ] || [ -L "$p" ]; then
            if [ -L "$p" ] && [ "$(readlink "$p")" = pvm ]; then continue; fi          # already ours
            # a different program called vpn / Vpn / ...: leave it alone. The old vpn-lxc command is ours to replace.
            [ "$name" = vpn-lxc ] || { printf '    left %s alone (something else is installed there)\n' "$p" >&2; continue; }
        fi
        ln -sfn pvm "$p"
    done
}
# one-time move from the old name (vpn-lxc): settings, library, registry and the watchdog timer
migrate_old() {
    [ "$ETC" = /etc/pvm ] || return 0
    if [ -d /etc/vpn-lxc ] && [ ! -L /etc/vpn-lxc ] && [ ! -e /etc/pvm ]; then mv /etc/vpn-lxc /etc/pvm && ln -s /etc/pvm /etc/vpn-lxc; fi
    if [ -d /var/lib/vpn-lxc ] && [ ! -L /var/lib/vpn-lxc ] && [ ! -e /var/lib/pvm ]; then mv /var/lib/vpn-lxc /var/lib/pvm && ln -s /var/lib/pvm /var/lib/vpn-lxc; fi
    if [ -e /etc/systemd/system/vpn-lxc-watchdog.timer ]; then
        systemctl disable --now vpn-lxc-watchdog.timer >/dev/null 2>&1
        rm -f /etc/systemd/system/vpn-lxc-watchdog.service /etc/systemd/system/vpn-lxc-watchdog.timer
        install_watchdog
    fi
}

# pvm update [--check] [ref] : fetch the latest release, verify its checksum, install it
update_self() {
    local check=0 ref=main tmp want have newv oldv dest=$BIN_DIR/pvm
    for a in "$@"; do case $a in --check) check=1 ;; *) ref=$a ;; esac; done
    command -v curl >/dev/null 2>&1 || die "curl is needed"
    tmp=$(mktemp -d) || die "could not create a temp dir"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN
    # a changing query string keeps GitHub's cache from handing out an older copy
    local bust; bust="?t=$(date +%s)"
    curl -fsSL -m 60 "$REPO_RAW/$ref/dist/pvm.sh$bust" -o "$tmp/s" || die "could not download the latest version (no internet, or no such version: $ref)"
    curl -fsSL -m 30 "$REPO_RAW/$ref/dist/pvm.sh.sha256$bust" -o "$tmp/s.sha" || die "could not download the checksum"
    want=$(cut -d' ' -f1 "$tmp/s.sha"); have=$(sha256sum "$tmp/s" | cut -d' ' -f1)
    [ "$want" = "$have" ] || die "checksum mismatch, nothing was changed"
    head -n 1 "$tmp/s" | grep -q '^#!/bin/bash' && bash -n "$tmp/s" || die "the download is not a valid script, nothing was changed"
    newv=$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$tmp/s" | head -n 1); oldv=$VERSION
    if [ "$ref" = main ] && [ "$newv" != "$oldv" ] && [ "$(printf '%s\n%s\n' "$newv" "$oldv" | sort -V | head -n 1)" = "$newv" ]; then
        printf '\n    %s▲%s the published version (%s) is older than yours (%s), so nothing was changed\n\n' "$WA" "$R" "$newv" "$oldv"; return 0
    fi
    if [ -f "$dest" ] && cmp -s "$tmp/s" "$dest"; then
        printf '\n    %s✔%s already up to date (version %s)\n\n' "$OK" "$R" "$oldv"; return 0
    fi
    if [ "$check" = 1 ]; then
        printf '\n    %s▲%s version %s is available (you have %s). Run: pvm update\n\n' "$WA" "$R" "$newv" "$oldv"; return 0
    fi
    install -m 755 "$tmp/s" "$dest.new" && mv -f "$dest.new" "$dest"
    install_links
    printf '\n    %s✔%s updated %s → %s at %s\n' "$OK" "$R" "$oldv" "$newv" "$dest"
    note "the watchdog uses the new version from its next round"
    note "containers keep their current setup; open pvm and re-run Protect containers on one to refresh its in-container tools"
    echo
}

usage() {
    cat <<EOF
PVM $VERSION · Proxmox VPN Manager

  pvm                       the full-screen app (dashboard + menu); "vpn" works too, in any capitals
  pvm dashboard             print the dashboard once
  pvm live                  auto-refreshing dashboard
  pvm status CTID           status screen for one container
  pvm switch CTID primary|backup
  pvm watchdog              one watchdog round (the systemd timer runs this)
  pvm update                install the latest version (update --check only looks)
  pvm version
EOF
}

main() {
    local cmd=${1:-menu}; cmd=${cmd,,}
    case $cmd in -h|--help|help) usage; exit 0 ;; version|--version) echo "pvm $VERSION"; exit 0 ;; esac
    [ "$(id -u)" -eq 0 ] || die "run this as root on the Proxmox host"
    command -v pct >/dev/null 2>&1 || die "pct not found: run this on the Proxmox host, not inside a container"
    migrate_old
    # first run of a version that arrived under the old command name (vpn-lxc): become the pvm file
    if [ -f "$SELF" ] && [ "$(dirname "$SELF")" = "$BIN_DIR" ] && [ "$(basename "$SELF")" != pvm ] && [ ! -L "$BIN_DIR/pvm" ]; then
        install -m 755 "$SELF" "$BIN_DIR/pvm.new" && mv -f "$BIN_DIR/pvm.new" "$BIN_DIR/pvm" && install_links
    fi
    if [ -f "$BIN_DIR/pvm" ] && [ "$(readlink -f "$BIN_DIR/pvm")" = "$(readlink -f "$SELF")" ]; then install_links; fi
    install -d -m 700 "$ETC" "$REG" "$LIB"
    case $cmd in
        menu)     main_menu ;;
        links)    install_links ;;
        update)   shift; update_self "$@" ;;
        watchdog) watchdog_round ;;
        dashboard|list) new_stage; dashboard ;;
        live)     live_screen ;;
        status)   [[ ${2:-} =~ ^[0-9]+$ ]] || die "usage: pvm status CTID"
                  cexec "$2" env FORCE_COLOR="$FANCY" /usr/local/sbin/vpn-status ;;
        switch)   [[ ${2:-} =~ ^[0-9]+$ ]] && [[ ${3,,} =~ ^(primary|backup)$ ]] || die "usage: pvm switch CTID primary|backup"
                  cexec "$2" /usr/local/sbin/vpnguard-switch "${3,,}" ;;
        *)        usage; exit 1 ;;
    esac
}

main "$@"

