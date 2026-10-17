#!/bin/bash
# Function-level tests for PVM. Changes nothing outside a temp dir.
#   bash tests/unit.sh [path/to/PVM]       (needs nft for the firewall checks; run it on the Proxmox host)
SCRIPT=${1:-$(dirname "$0")/../dist/pvm.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export NO_COLOR=1 PVM_ETC=$T/etc PVM_VAR=$T/var
grep -v '^main "\$@"$' "$SCRIPT" > "$T/lib.sh"
# shellcheck disable=SC1091
source "$T/lib.sh"
mkdir -p "$T"/etc/{library,registry}
pass=0; failn=0
ok()   { pass=$((pass + 1)); }
bad()  { failn=$((failn + 1)); echo "FAIL  $*"; }
yes_() { local n=$1; shift; if out=$("$@" 2>&1); then ok; else bad "$n -> $out"; fi; }
no_()  { local n=$1; shift; if out=$("$@" 2>&1); then bad "$n should be rejected -> $out"; else ok; fi; }
eq()   { [ "$2" = "$3" ] && ok || bad "$1: expected [$3] got [$2]"; }
has()  { grep -qF -- "$3" <<<"$2" && ok || bad "$1: missing [$3]"; }
lacks(){ grep -qF -- "$3" <<<"$2" && bad "$1: should not contain [$3]" || ok; }

# ── validators ──
eq "port zero-pad" "$(v_port 0051)" 51;  no_ port0 v_port 0;  no_ port70000 v_port 70000
yes_ cidr v_cidr4 192.168.1.0/24;       no_ cidr_bad v_cidr4 999.1.1.0/24
yes_ ip4len v_ip4len 192.168.1.5/24;    yes_ dhcp v_ip4len dhcp;  no_ ip4len_31 v_ip4len 10.0.0.1/31
eq "ports dedupe" "$(v_ports '22,8090 22')" "22 8090";  no_ ports_bad v_ports "22 abc"
eq "publish" "$(v_publish '8090 2222:22')" "8090:8090 2222:22"
yes_ lanout v_lanout 192.168.1.23:8686; no_ lanout_bad v_lanout 192.168.1.23
eq "url slash" "$(v_url https://ntfy.sh/)" https://ntfy.sh; no_ url_bad v_url ntfy.sh
no_ name_space v_name "a b"

# ── pasted-text cleanup ──
printf 'Endpoint = 1.2.3.4:51820\nPersistentKeepalive = 25\e[13;2u\n\e[200~Address = 10.0.0.2/32\e[201~\n' > "$T/c.txt"
clean_cfg "$T/c.txt"; eq "escape strip" "$(cat "$T/c.txt")" $'Endpoint = 1.2.3.4:51820\nPersistentKeepalive = 25\nAddress = 10.0.0.2/32'

# ── WireGuard config ──
cat > "$T/wg.conf" <<'EOF'
[Interface]
PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=
Address = 10.2.0.2/32, fd00::2/128
DNS = 10.2.0.1
PostUp = iptables -A FORWARD
[Peer]
PublicKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.9:51820
PersistentKeepalive = 25
EOF
declare -A V=() D=()
analyze_config 1 primary "$T/wg.conf" && ok || bad "analyze wg: $VERR"
eq "wg dns" "${V[1.primary.dns]}" 10.2.0.1;  eq "wg hooks stripped" "${V[1.primary.hooks]}" 1
eq "provider guess proton" "$(guess_provider 1 primary)" proton
wg_render "$T/wg.conf" "$T/wg.out" "" "10.2.0.1" && ok || bad "wg_render"
out=$(cat "$T/wg.out"); lacks "wg ipv6 gone" "$out" "fd00"; lacks "wg foreign hook gone" "$out" iptables; has "wg dns hook" "$out" "vpnguard-dns 10.2.0.1"
analyze_config 2 primary "$T/wg.out" && ok || bad "re-analyze rendered: $VERR"
eq "rendered config keeps its DNS" "${V[2.primary.dns]}" 10.2.0.1; eq "rendered config has no foreign hooks" "${V[2.primary.hooks]}" 0
eq "key fingerprint stable" "$(key_fp "$T/wg.conf")" "$(key_fp "$T/wg.out")"
no_ not_a_config analyze_config 3 primary /etc/hostname

# ── OpenVPN config ──
printf 'client\ndev tun\nproto udp\nremote 1.2.3.4 1194\nremote 5.6.7.8 443 tcp\nauth-user-pass\n<ca>\n-----BEGIN CERTIFICATE-----\nxx\n-----END CERTIFICATE-----\n</ca>\n' > "$T/o.ovpn"
analyze_config 4 primary "$T/o.ovpn" && ok || bad "analyze ovpn: $VERR"
eq "ovpn login detected" "${V[4.primary.auth]}" 1
ovpn_render "$T/o.ovpn" "$T/o1" "${V[4.primary.endpoints]}" /etc/vpnguard/slots/primary.auth
ovpn_render "$T/o1" "$T/o2" "${V[4.primary.endpoints]}" /etc/vpnguard/slots/primary.auth
cmp -s "$T/o1" "$T/o2" && ok || bad "ovpn render is not idempotent"

# ── generated firewalls ──
STAGE=$T/stage; mkdir -p "$STAGE"; write_payload "$STAGE/payload"
for f in "$STAGE"/payload/*; do case $f in *.service|*.conf|*dhclient-vpnguard) ;; *) bash -n "$f" && ok || bad "syntax $f" ;; esac; done
[ -f "$STAGE/payload/dhclient-vpnguard" ] && ok || bad "dhclient hook missing from payload"
ct_exists() { return 0; }; pct() { echo "net0: name=eth0,bridge=vmbr0,ip=dhcp"; }
V[1.ct]=999; V[1.name]=t; V[1.provider]=proton; V[lan_net]=192.168.1.0/24; D[1.LAN_IF]=eth0; V[1.pf_mode]=none
V[1.lan_mode]=open;  stage_tunnel 1 "$T/o_open";  open=$(cat "$T/o_open/vpnguard.nft")
V[1.lan_mode]=ports; V[1.lan_tcp]="22 8090"; V[1.lan_out]="192.168.1.23:8686"; stage_tunnel 1 "$T/o_ports"; ports=$(cat "$T/o_ports/vpnguard.nft")
has "open: LAN in"  "$open" 'iifname "eth0" ip saddr 192.168.1.0/24 accept'
has "open: LAN out" "$open" 'oifname "eth0" ip daddr 192.168.1.0/24 accept'
has "open: DNS to LAN dropped" "$open" 'th dport { 53, 853 } drop'
lacks "ports: no blanket LAN accept" "$ports" 'oifname "eth0" ip daddr 192.168.1.0/24 accept'
has "ports: listed ports" "$ports" '@lan_tcp accept'
has "env LAN_MODE" "$(cat "$T/o_open/vpnguard.env")" LAN_MODE=open
if command -v nft >/dev/null && nft -c -f /dev/null 2>/dev/null; then
    for f in "$T/o_open" "$T/o_ports"; do nft -c -f "$f/vpnguard.nft" && ok || bad "nft check $f"; done
fi
V[gw.provider]=proton; V[gw.net]=10.10.10.0/24; V[gw.lanaddr]=192.168.1.250/24; V[gw.mode]=create
V[gw.clients]="201 202"; V[c201.ip]=10.10.10.10; V[c202.ip]=10.10.10.11; V[c201.publish]="8090:8090 2222:22"; V[c202.publish]="9696:9696"
V[gw.pf_mode]=natpmp; V[gw.pf_target]=201; V[gw.lan_mode]=open
analyze_config gw primary "$T/wg.conf"; stage_gateway "$T/o_gw"; gw=$(cat "$T/o_gw/vpnguard.nft")
has "gw dnat" "$gw" 'tcp dport 2222 dnat ip to 10.10.10.10:22'
has "gw forward LAN" "$gw" 'iifname "eth1" oifname "eth0" ip daddr 192.168.1.0/24 accept'
has "gw forward drops LAN DNS" "$gw" 'meta l4proto { tcp, udp } th dport { 53, 853 } drop'
if command -v nft >/dev/null && nft -c -f /dev/null 2>/dev/null; then nft -c -f "$T/o_gw/vpnguard.nft" && ok || bad "nft check gateway"; fi

# ── gateway helpers ──
AP_TAKEN=" 53 67 "; D[c1.LISTEN_TCP]="22 80"; D[c2.LISTEN_TCP]="22 8080"
auto_publish 1; eq "auto publish c1" "$AP_OUT" "22:22 80:80"
auto_publish 2; eq "auto publish avoids clash" "$AP_OUT" "10022:22 8080:8080"

# ── template architecture (never pick another CPU's build) ──
list=$'system  debian-13-standard_13.6-1_amd64.tar.zst  amd64\nsystem  debian-13-standard_13.6-1_arm64.tar.zst  arm64'
pick=$(awk '{print $2}' <<<"$list" | grep -E "^debian-13-standard_.*_amd64\.tar" | sort -V | tail -n 1)
eq "template pick" "$pick" debian-13-standard_13.6-1_amd64.tar.zst


# ── one config, one connection ──
reg_set 501 NAME alpha; reg_set 501 ROLE tunnel; reg_set 501 FPS "$(key_fp "$T/wg.conf") deadbeef00000000"
eq "owner found" "$(fp_owner "$(key_fp "$T/wg.conf")")" "501 alpha"
eq "own config is not a conflict" "$(fp_owner "$(key_fp "$T/wg.conf")" 501 || echo none)" none
eq "backup fp also counts" "$(fp_owner deadbeef00000000)" "501 alpha"
declare -A V=(); NT=0
V[gw.primary.fp]=aaaa
eq "same setup, other slot" "$(fp_conflict gw backup aaaa x)" "the primary config of this same setup"
NT=2; V[1.ct]=201; V[1.name]=a; V[1.primary.fp]=bbbb; V[2.ct]=202; V[2.name]=b
eq "other target in the same run" "$(fp_conflict 2 primary bbbb x)" "CT 201 a (in this same setup)"
fp_conflict 1 primary bbbb x >/dev/null && bad "a target conflicts with itself" || ok
mkdir -p "$LIB"; cp "$T/wg.conf" "$LIB/one.conf"; printf 'KIND=wireguard\nPROVIDER=proton\nENDPOINTS=203.0.113.9:51820/udp\n' > "$LIB/one.meta"
eq "library fp = key fp" "$(lib_fp one)" "$(key_fp "$T/wg.conf")"


# ── several named gateways ──
ct_ids() { echo "100 101"; }; ct_name() { case $1 in 100) echo web;; 101) echo vpn-gateway;; esac; }
reg_set 601 ROLE gateway; reg_set 601 NAME media; reg_set 601 VPN_NET 10.10.10.0/24
reg_set 602 ROLE gateway; reg_set 602 NAME private; reg_set 602 VPN_NET 10.10.11.0/24
reg_set 603 ROLE client; reg_set 603 GATEWAY 601; reg_set 604 ROLE client; reg_set 604 GATEWAY 602
eq "gateway list" "$(gateway_ids | tr '\n' ' ')" "601 602 "
eq "clients of a gateway" "$(gateway_clients_of 601 | tr '\n' ' ')" "603 "
name_taken media && ok || bad "registered gateway name should be taken"
name_taken web && ok || bad "container hostname should be taken"
name_taken fresh && bad "unused name reported taken" || ok
eq "next free gateway name" "$(suggest_gw_name)" "vpn-gateway-2"
declare -A V=([lan_net]=192.168.1.0/24)
eq "next free vpn network" "$(free_vpnnet)" "10.10.12.0/24"
v_vpnnet 10.10.10.0/24 >/dev/null 2>&1 && bad "network of another gateway accepted" || ok
eq "free network accepted" "$(v_vpnnet 10.10.12.0/24)" "10.10.12.0/24"


# ── commands: pvm and vpn in any capitals ──
eq "pvm spellings" "$(case_variants pvm | sort | tr '\n' ' ')" "PVM PVm PvM Pvm pVM pVm pvM pvm "
eq "vpn spellings" "$(case_variants vpn | wc -l)" 8
BIN=$T/bin; mkdir -p "$BIN"; BIN_DIR=$BIN
printf '#!/bin/bash\necho real\n' > "$BIN/pvm"; chmod +x "$BIN/pvm"
printf 'someone else' > "$BIN/Vpn"                     # a different program that happens to be called Vpn
printf 'old command' > "$BIN/vpn-lxc"                  # the old name: ours to replace
install_links 2>/dev/null
for n in vpn VPN vPn pvm PVM Pvm; do [ -e "$BIN/$n" ] && ok || bad "missing command $n"; done
eq "all spellings run the same file" "$(readlink -f "$BIN/VPN")" "$(readlink -f "$BIN/pvm")"
eq "someone else's Vpn is untouched" "$(cat "$BIN/Vpn")" "someone else"
[ -L "$BIN/vpn-lxc" ] && ok || bad "old vpn-lxc command should now be a link"


# ── deleting a saved config keeps a copy ──
cp "$T/wg.conf" "$LIB/gone.conf"; printf 'KIND=wireguard\n' > "$LIB/gone.meta"
lib_delete gone
[ ! -e "$LIB/gone.conf" ] && ok || bad "config still listed after delete"
ls "$LIB/.trash"/gone.*.conf >/dev/null 2>&1 && ok || bad "deleted config was not kept in the trash"
lib_names | grep -q '^gone$' && bad "trash entry shows up as a saved config" || ok

echo "passed $pass, failed $failn"
[ "$failn" = 0 ]
