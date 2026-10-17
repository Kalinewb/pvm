#!/bin/bash
# vpn-lxc installer. Run as root on the Proxmox host:
#   curl -fsSL https://raw.githubusercontent.com/Kalinewb/vpn-lxc/main/install.sh | bash
# Options (environment): VPNLXC_REF=<branch|tag>  install another version
#   bash install.sh --uninstall                    remove the command (containers keep their setup)
set -euo pipefail
REPO=Kalinewb/vpn-lxc
REF=${VPNLXC_REF:-main}
DEST=/usr/local/sbin/vpn-lxc
RAW=https://raw.githubusercontent.com/$REPO/$REF/dist

die() { printf '\n  ✘ %s\n\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this as root on the Proxmox host"

if [ "${1:-}" = --uninstall ]; then
    systemctl disable --now vpn-lxc-watchdog.timer >/dev/null 2>&1 || true
    rm -f "$DEST" /etc/systemd/system/vpn-lxc-watchdog.service /etc/systemd/system/vpn-lxc-watchdog.timer
    systemctl daemon-reload 2>/dev/null || true
    echo "  ✔ removed $DEST and the watchdog timer. Containers keep their VPN until you remove it in the app."
    exit 0
fi

command -v pct >/dev/null 2>&1 || die "pct not found: run this on the Proxmox host, not inside a container"
command -v curl >/dev/null 2>&1 || die "curl is needed"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$RAW/vpn-lxc.sh?t=$(date +%s)" -o "$tmp/vpn-lxc.sh" || die "could not download $RAW/vpn-lxc.sh"
curl -fsSL "$RAW/vpn-lxc.sh.sha256?t=$(date +%s)" -o "$tmp/vpn-lxc.sh.sha256" || die "could not download the checksum"

want=$(cut -d' ' -f1 "$tmp/vpn-lxc.sh.sha256")
have=$(sha256sum "$tmp/vpn-lxc.sh" | cut -d' ' -f1)
[ "$want" = "$have" ] || die "checksum mismatch, nothing was installed"
head -n 1 "$tmp/vpn-lxc.sh" | grep -q '^#!/bin/bash' || die "the download is not the script"
bash -n "$tmp/vpn-lxc.sh" || die "the download has a syntax error"

install -m 755 "$tmp/vpn-lxc.sh" "$DEST"
printf '\n  ✔ installed %s (%s)\n\n  Start it with:   vpn-lxc\n  Dashboard only:  vpn-lxc dashboard\n\n' "$DEST" "$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$DEST" | head -n 1)"
