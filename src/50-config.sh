# ════════════════════════════════════════════════════════════
#  VPN configs: parse, clean up, pin endpoints, library
# ════════════════════════════════════════════════════════════

declare -A V=()     # wizard state, keys like "1.primary.kind" or "gw.pf_mode"
declare -A D=()     # detection results per target, keys like "1.LAN_IF"

# Pasting through some terminals drags escape sequences along (bracketed paste, Shift+Enter...).
# They look like part of a value and make the VPN refuse the file, so strip them on the way in.
clean_cfg() {   # clean_cfg FILE : in place
    local f=$1 tmp
    tmp=$(mktemp) || return 0
    sed -E $'s/\x1b\\[[0-9;?<>=]*[ -\\/]*[@-~]//g; s/\x1b[()][A-Za-z0-9]//g; s/\x1b.?//g' "$f" \
        | tr -d '\000-\010\013\014\016-\037\177' > "$tmp" && cat "$tmp" > "$f"
    rm -f "$tmp"
}

cfg_kind() {
    if grep -qiE '^[[:space:]]*\[interface\]' "$1"; then echo wireguard
    elif grep -qiE '^[[:space:]]*(client|remote)([[:space:]]|$)' "$1"; then echo openvpn
    else echo unknown; fi
}

wg_info() {
    awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^[ \t]*\[[Pp]eer\][ \t]*$/      { peers++ }
    /^[ \t]*\[[Ii]nterface\][ \t]*$/ { ifaces++ }
    index($0, "=") && $0 !~ /^[ \t]*#/ {
        k = tolower(trim(substr($0, 1, index($0, "=") - 1)))
        v = trim(substr($0, index($0, "=") + 1))
        if (k == "privatekey" && v != "") pk = 1
        if (k == "endpoint")   ep = v
        if (k == "dns")        dns  = (dns  == "" ? v : dns  "," v)
        # a config we rendered earlier carries its DNS in our PostUp hook
        if (k == "postup" && v ~ /vpnguard-dns[ \t]/) {
            w = v; sub(/.*vpnguard-dns[ \t]+/, "", w); n = split(w, dd, /[ \t]+/)
            for (i = 1; i <= n; i++) if (dd[i] != "") dns = (dns == "" ? dd[i] : dns "," dd[i])
        }
        if (k == "address")    addr = (addr == "" ? v : addr "," v)
        if (k ~ /^(postup|postdown|preup|predown)$/ && v !~ /vpnguard-dns/) hooks++
    }
    END {
        printf "PEERS=%d\nIFACES=%d\nPK=%d\nEP=%s\nDNS=%s\nADDR=%s\nHOOKS=%d\n", peers, ifaces, pk, ep, dns, addr, hooks
    }' "$1"
}

# wg_render SRC DST "pinned ip:port or empty" "dns servers"
wg_render() {
    awk -v ep="$3" -v dns="$4" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function v4only(v,   n, a, i, x, out) {
        n = split(v, a, ","); out = ""
        for (i = 1; i <= n; i++) { x = trim(a[i]); if (x == "" || index(x, ":")) continue; out = out (out == "" ? "" : ", ") x }
        return out
    }
    /^[ \t]*\[[Ii]nterface\][ \t]*$/ {
        print
        print "# DNS is handled by PVM: only ever through the tunnel"
        if (dns != "") print "PostUp = /usr/local/sbin/vpnguard-dns " dns
        next
    }
    /^# DNS is handled by (PVM|vpn-lxc.sh)/ { next }
    index($0, "=") && $0 !~ /^[ \t]*#/ {
        k = tolower(trim(substr($0, 1, index($0, "=") - 1)))
        v = trim(substr($0, index($0, "=") + 1))
        if (k ~ /^(dns|postup|postdown|preup|predown|saveconfig|table)$/) next
        if (k == "address" || k == "allowedips") {
            f = v4only(v)
            if (f == "") { bad = 1; next }
            print (k == "address" ? "Address" : "AllowedIPs") " = " f
            next
        }
        if (k == "endpoint" && ep != "") { print "Endpoint = " ep; next }
    }
    { print }
    END { exit bad }' "$1" > "$2"
}

ovpn_info() {
    awk '
    BEGIN { proto = "udp"; port = "1194" }
    /^[ \t]*<\/[A-Za-z-]+>/ { inblk = 0; next }
    /^[ \t]*<[A-Za-z-]+>/   { inblk = 1; if ($0 ~ /<auth-user-pass>/) inline_auth = 1; next }
    inblk { next }
    /^# --- (PVM|vpn-lxc.sh) ---/ { ours = 1 }
    /^[ \t]*[#;]/ { next }
    $1 == "remote"         { nr++; rh[nr] = $2; rp[nr] = $3; rt[nr] = $4 }
    $1 == "proto"          { proto = $2 }
    $1 == "port"           { port = $2 }
    $1 == "auth-user-pass" { auth = 1 }
    $1 ~ /^(up|down|route-up|ipchange|route-pre-down)$/ && $2 !~ /vpnguard/ { hooks++ }
    END {
        out = ""
        for (i = 1; i <= nr; i++) {
            p = (rp[i] == "" ? port : rp[i]); t = tolower(rt[i] == "" ? proto : rt[i])
            t = (t ~ /^tcp/ ? "tcp" : "udp")
            e = rh[i] ":" p "/" t
            if (index(" " out " ", " " e " ") == 0) out = out (out == "" ? "" : " ") e
        }
        printf "REMOTES=%s\nAUTH=%d\nINLINE_AUTH=%d\nHOOKS=%d\n", out, auth, inline_auth, hooks
    }' "$1"
}

# ovpn_render SRC DST "ip:port/proto ..." "auth file path or empty"
ovpn_render() {
    awk -v rem="$3" -v authf="$4" '
    /^# --- (PVM|vpn-lxc.sh) ---/ { exit }
    /^[ \t]*<auth-user-pass>/   { skip = 1; next }
    /^[ \t]*<\/auth-user-pass>/ { skip = 0; next }
    skip { next }
    /^[ \t]*<\/[A-Za-z-]+>/ { inblk = 0; print; next }
    /^[ \t]*<[A-Za-z-]+>/   { inblk = 1; print; next }
    inblk { print; next }
    $1 ~ /^(remote|up|down|route-up|ipchange|route-pre-down|script-security|auth-user-pass|auth-nocache|dev|dev-type|persist-tun|resolv-retry|redirect-gateway|remote-random-hostname)$/ { next }
    { print }
    END {
        print "# --- PVM ---"
        print "# Below is managed by PVM. Servers are pinned to IPs because DNS only works inside the tunnel."
        n = split(rem, R, " ")
        for (i = 1; i <= n; i++) { split(R[i], a, /[:\/]/); print "remote " a[1] " " a[2] " " a[3] }
        print "dev tun0"
        print "dev-type tun"
        if (authf != "") { print "auth-user-pass " authf; print "auth-nocache" }
        print "script-security 2"
        print "route-up /usr/local/sbin/vpnguard-ovpn-up"
        print "persist-tun"
        print "resolv-retry infinite"
        print "redirect-gateway def1"
        print "pull-filter ignore \"ifconfig-ipv6\""
        print "pull-filter ignore \"route-ipv6\""
        print "pull-filter ignore \"block-outside-dns\""
    }' "$1" > "$2"
}

# pin_endpoints "host:port/proto ..." → PINNED (all IPs), PIN_NOTE
pin_endpoints() {
    local e host rest ip out=""
    PIN_NOTE=""
    for e in $1; do
        host=${e%%:*}; rest=${e#*:}
        if is_ip4 "$host"; then
            out="$out $host:$rest"
        else
            [[ $host =~ ^[A-Za-z0-9.-]+$ ]] || { VERR="only IPv4 or hostname servers are supported ($host)"; return 1; }
            ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR == 1 {print $1}')
            is_ip4 "$ip" || { VERR="could not look up the server $host"; return 1; }
            out="$out $ip:$rest"
            PIN_NOTE="$PIN_NOTE $host→$ip"
        fi
    done
    PINNED=${out# }
    PIN_NOTE=${PIN_NOTE# }
}

# analyze_config TARGET SLOT FILE : fills V[TARGET.SLOT.*]
analyze_config() {
    local t=$1 s=$2 f=$3 kind
    clean_cfg "$f"
    kind=$(cfg_kind "$f")
    case $kind in
        wireguard)
            local -A WI=()
            read_kv_into WI "" < <(wg_info "$f")
            [ "${WI[IFACES]:-0}" = 1 ] && [ "${WI[PK]:-0}" = 1 ] || { VERR="no [Interface] with a PrivateKey in it"; return 1; }
            [ "${WI[PEERS]:-0}" = 1 ] || { VERR="it has ${WI[PEERS]:-0} [Peer] sections, exactly one is supported"; return 1; }
            local ep=${WI[EP]} host port
            [[ $ep =~ ^([A-Za-z0-9.-]+):([0-9]+)$ ]] || { VERR="can't read the Endpoint '${ep:-missing}' (IPv4 or hostname servers only)"; return 1; }
            host=${BASH_REMATCH[1]}; port=${BASH_REMATCH[2]}
            pin_endpoints "$host:$port/udp" || return 1
            local dns="" d
            for d in ${WI[DNS]//,/ }; do is_ip4 "$d" && dns="$dns $d"; done
            V[$t.$s.kind]=wireguard
            V[$t.$s.endpoints]=$PINNED
            V[$t.$s.pin]=$([ -n "$PIN_NOTE" ] && echo "${PINNED%/udp}")
            V[$t.$s.dns]=${dns# }
            V[$t.$s.addr]=$(printf '%s' "${WI[ADDR]}" | tr ',' '\n' | grep -v ':' | tr -d ' ' | head -n 1)
            V[$t.$s.hooks]=${WI[HOOKS]}
            V[$t.$s.auth]=0
            V[$t.$s.pinnote]=$PIN_NOTE
            V[$t.$s.label]="WireGuard · ${PINNED%/udp} · ${V[$t.$s.addr]:-?}"
            ;;
        openvpn)
            local -A OI=()
            read_kv_into OI "" < <(ovpn_info "$f")
            [ -n "${OI[REMOTES]}" ] || { VERR="the OpenVPN config has no remote lines"; return 1; }
            pin_endpoints "${OI[REMOTES]}" || return 1
            local n; n=$(wc -w <<<"$PINNED")
            V[$t.$s.kind]=openvpn
            V[$t.$s.endpoints]=$PINNED
            V[$t.$s.dns]=""
            V[$t.$s.addr]=""
            V[$t.$s.hooks]=${OI[HOOKS]}
            V[$t.$s.auth]=$(( ${OI[AUTH]:-0} || ${OI[INLINE_AUTH]:-0} ))
            V[$t.$s.pinnote]=$PIN_NOTE
            V[$t.$s.label]="OpenVPN · $n server$([ "$n" -gt 1 ] && echo s) · $(echo "$PINNED" | awk '{print $1}')$([ "${V[$t.$s.auth]}" = 1 ] && echo ' · login')"
            ;;
        *)
            VERR="that's neither a WireGuard nor an OpenVPN config"
            return 1 ;;
    esac
    V[$t.$s.file]=$f
    return 0
}

# summary card for an imported config
config_card() {
    local t=$1 s=$2
    box_top "$([ "$s" = backup ] && echo "Backup config" || echo "VPN config")"
    box_row "${B}${V[$t.$s.label]}${R}"
    if [ "${V[$t.$s.kind]}" = wireguard ]; then
        box_row "${GR}PrivateKey${R}  ●●●●●●●●●●●●●●●●  ${GR}(never shown)${R}"
        box_row "${GR}DNS${R}         ${V[$t.$s.dns]:-${WA}none in the config${R}}"
    else
        box_row "${GR}Servers${R}     $(echo "${V[$t.$s.endpoints]}" | wc -w) pinned to IPs, all allowed by the kill switch"
        box_row "${GR}DNS${R}         whatever the server pushes, only through the tunnel"
    fi
    [ -n "${V[$t.$s.pinnote]}" ] && box_row "${GR}Pinned${R}      ${V[$t.$s.pinnote]}"
    [ "${V[$t.$s.hooks]:-0}" -gt 0 ] && box_row "${WA}▲${R} removed ${V[$t.$s.hooks]} up/down hook lines (the firewall replaces them)"
    box_row "${GR}IPv6${R}        stripped; the firewall blocks IPv6 anyway"
    box_bot
}

# ── library ─────────────────────────────────────────────────
lib_names() { local f; for f in "$LIB"/*.conf; do [ -e "$f" ] && basename "$f" .conf; done; }
lib_meta()  { kvfile_get "$LIB/$1.meta" "$2"; }
lib_save() {   # lib_save NAME SRCFILE KIND PROVIDER ENDPOINTS USER PASS
    install -d -m 700 "$LIB"
    install -m 600 "$2" "$LIB/$1.conf"
    {
        echo "KIND=$3"; echo "PROVIDER=$4"; echo "ENDPOINTS=$5"; echo "ADDED=$(date '+%F %H:%M')"
    } > "$LIB/$1.meta"
    chmod 600 "$LIB/$1.meta"
    if [ -n "${6:-}" ]; then printf '%s\n%s\n' "$6" "$7" > "$LIB/$1.auth"; chmod 600 "$LIB/$1.auth"
    else rm -f "$LIB/$1.auth"; fi
}
lib_delete() { rm -f "$LIB/$1.conf" "$LIB/$1.meta" "$LIB/$1.auth"; }

key_fp() {   # key_fp FILE : short fingerprint of a WireGuard PrivateKey (never the key itself)
    awk 'tolower($1) == "privatekey" {sub(/^[^=]*=[ \t]*/, ""); print; exit}' "$1" 2>/dev/null | sha256sum | cut -c1-16
}

# One connection per config: a WireGuard key can hold a single session, and "different container, different
# connection" is the point of per-container tunnels. A config's identity is its key (WireGuard) or its
# server list (OpenVPN). Setups remember theirs in the registry (FPS) so a later session can refuse a repeat.
cfg_fp_of() {   # cfg_fp_of TARGET SLOT : identity of the config that was just analysed
    local t=$1 s=$2
    if [ "${V[$t.$s.kind]}" = wireguard ]; then key_fp "${V[$t.$s.file]}"
    else printf '%s' "${V[$t.$s.endpoints]}" | tr ' ' '\n' | sort | sha256sum | cut -c1-16; fi
}
lib_fp() {   # lib_fp NAME : same identity for a saved config
    if [ "$(lib_meta "$1" KIND)" = wireguard ]; then key_fp "$LIB/$1.conf"
    else lib_meta "$1" ENDPOINTS | tr ' ' '\n' | sort | sha256sum | cut -c1-16; fi
}
fp_owner() {   # fp_owner FP [EXCEPT_ID] : prints "ID NAME" of the setup that already uses it
    local fp=$1 ex=${2:-} id
    [ -n "$fp" ] || return 1
    for id in $(reg_ids); do
        [ "$id" = "$ex" ] && continue
        case " $(reg_get "$id" FPS) " in *" $fp "*) echo "$id $(reg_get "$id" NAME)"; return 0 ;; esac
    done
    return 1
}
fp_conflict() {   # fp_conflict TARGET SLOT FP EXCEPT_ID : prints who has it, returns 0 if somebody does
    local t=$1 s=$2 fp=$3 ex=$4 o other i
    [ -n "$fp" ] || return 1
    if o=$(fp_owner "$fp" "$ex"); then echo "CT ${o%% *} ${o#* }"; return 0; fi
    [ "$s" = primary ] && other=backup || other=primary
    if [ "${V[$t.$other.fp]:-}" = "$fp" ]; then echo "the $other config of this same setup"; return 0; fi
    for ((i = 1; i <= NT; i++)); do
        [ "$t" = "$i" ] && continue
        if [ "${V[$i.primary.fp]:-}" = "$fp" ] || [ "${V[$i.backup.fp]:-}" = "$fp" ]; then
            echo "CT ${V[$i.ct]} ${V[$i.name]} (in this same setup)"; return 0
        fi
    done
    return 1
}

guess_provider() {   # guess_provider TARGET SLOT : look at the tunnel addresses
    local d=" ${V[$1.$2.dns]} ${V[$1.$2.addr]} ${V[$1.$2.endpoints]} "
    if   [[ $d =~ \ 10\.2\.0\. ]]; then echo proton
    elif [[ $d =~ \ 10\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; then echo mullvad
    elif [[ $d =~ \ 10\.(12[89]|13[01])\. ]]; then echo airvpn
    else echo other; fi
}

provider_label() {
    case $1 in
        mullvad) echo "Mullvad" ;;
        proton)  echo "Proton VPN" ;;
        airvpn)  echo "AirVPN" ;;
        *)       echo "Other provider" ;;
    esac
}
provider_dns() {
    case $1 in
        mullvad) echo 10.64.0.1 ;;
        proton)  echo 10.2.0.1 ;;
        airvpn)  echo 10.128.0.1 ;;
    esac
}
provider_hint() {
    case $1:$2 in
        mullvad:*)        echo "mullvad.net → Account → WireGuard configuration → Linux" ;;
        proton:openvpn)   echo "account.protonvpn.com → Downloads → OpenVPN. The login is the OpenVPN username/password from that page, not your account password." ;;
        proton:*)         echo "account.protonvpn.com → Downloads → WireGuard. For port forwarding pick a P2P server (⇄) and turn NAT-PMP on." ;;
        airvpn:*)         echo "airvpn.org → Client Area → Config Generator → Linux" ;;
        *)                echo "download a WireGuard (.conf) or OpenVPN (.ovpn) file from your provider" ;;
    esac
}
