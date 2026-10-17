#!/bin/bash
# Lints the shell sections and every container-side script, then builds.
cd "$(dirname "$0")"
rc=0
for f in src/*.sh src/payload/{detect.sh,apply.sh,remove.sh,client.sh,vpn-status,vpnguard-dns,vpnguard-switch,vpnguard-ovpn-up,vpnguard-qbit-port,vpnguard-natpmp}; do
    bash -n "$f" || rc=1
done
command -v shellcheck >/dev/null && shellcheck -S warning -s bash -e SC2319,SC2034,SC2154,SC2155,SC2086,SC2016,SC2209,SC2048 \
    src/payload/{detect.sh,apply.sh,remove.sh,client.sh,vpn-status,vpnguard-dns,vpnguard-switch,vpnguard-ovpn-up,vpnguard-qbit-port,vpnguard-natpmp} || rc=1
./build.sh >/dev/null && echo "build ok" || rc=1
exit $rc
