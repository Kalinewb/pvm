#!/bin/bash
# PVM (Proxmox VPN Manager) installer. Run as root on the Proxmox host:
#   curl -fsSL https://raw.githubusercontent.com/Kalinewb/pvm/main/install.sh | bash
# Then run it as `pvm` or `vpn`, in any capitals.
# Options: PVM_REF=<branch|tag>  install another version
#          bash -s -- --uninstall  remove the commands (containers keep their setup)
set -euo pipefail
REPO=Kalinewb/pvm
REF=${PVM_REF:-main}
BIN=/usr/local/sbin
DEST=$BIN/pvm
RAW=https://raw.githubusercontent.com/$REPO/$REF/dist
API=https://api.github.com/repos/$REPO/contents/dist

die() { printf '\n  ✘ %s\n\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this as root on the Proxmox host"

if [ "${1:-}" = --uninstall ]; then
    systemctl disable --now pvm-watchdog.timer vpn-lxc-watchdog.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/pvm-watchdog.service /etc/systemd/system/pvm-watchdog.timer \
          /etc/systemd/system/vpn-lxc-watchdog.service /etc/systemd/system/vpn-lxc-watchdog.timer
    # every spelling of the command is a symlink to pvm
    find "$BIN" -maxdepth 1 -type l -lname pvm -delete 2>/dev/null || true
    rm -f "$DEST" "$BIN/vpn-lxc"
    systemctl daemon-reload 2>/dev/null || true
    echo "  ✔ removed the pvm / vpn commands and the watchdog timer. Containers keep their VPN until you remove it in the app."
    exit 0
fi

command -v pct >/dev/null 2>&1 || die "pct not found: run this on the Proxmox host, not inside a container"
command -v curl >/dev/null 2>&1 || die "curl is needed"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# the API first: raw.githubusercontent.com caches for 5 minutes and could hand back the previous release
get() { curl -fsSL -H 'Accept: application/vnd.github.raw' "$API/$1?ref=$REF" -o "$2" 2>/dev/null || curl -fsSL "$RAW/$1" -o "$2"; }
get pvm.sh "$tmp/pvm.sh" || die "could not download pvm.sh"
get pvm.sh.sha256 "$tmp/pvm.sh.sha256" || die "could not download the checksum"

want=$(cut -d' ' -f1 "$tmp/pvm.sh.sha256")
have=$(sha256sum "$tmp/pvm.sh" | cut -d' ' -f1)
[ "$want" = "$have" ] || die "checksum mismatch, nothing was installed"
head -n 1 "$tmp/pvm.sh" | grep -q '^#!/bin/bash' || die "the download is not the script"
bash -n "$tmp/pvm.sh" || die "the download has a syntax error"

install -m 755 "$tmp/pvm.sh" "$DEST"
"$DEST" links    # pvm, vpn and every capitalisation of them
printf '\n  ✔ installed %s (%s)\n\n  Start it with:   pvm      (or vpn, PVM, Vpn ...)\n  Dashboard only:  pvm dashboard\n\n' "$DEST" "$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$DEST" | head -n 1)"
