# ════════════════════════════════════════════════════════════
#  Validation (each prints the clean value, or sets VERR and fails)
# ════════════════════════════════════════════════════════════
is_ip4() {
    local o
    [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local IFS=.
    for o in $1; do [ "$((10#$o))" -le 255 ] || return 1; done
}
is_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]; }
is_unit() { [[ $1 =~ ^[A-Za-z0-9@._-]+\.service$ ]]; }

v_any()   { printf '%s' "$1"; }
v_req()   { VERR="this can't be empty"; [ -n "$1" ] && printf '%s' "$1"; }
v_ip4()   { VERR="enter an IPv4 address like 10.2.0.1"; is_ip4 "$1" && printf '%s' "$1"; }
v_port()  { VERR="enter a port from 1 to 65535"; is_port "$1" && printf '%s' "$((10#$1))"; }
v_ctid()  { VERR="enter a container ID (a number)"; [[ $1 =~ ^[0-9]{3,9}$ ]] && printf '%s' "$1"; }
v_cidr4() {
    VERR="use the form 192.168.1.0/24"
    [[ $1 =~ ^([0-9.]+)/([0-9]{1,2})$ ]] || return 1
    local ip=${BASH_REMATCH[1]} len=${BASH_REMATCH[2]}
    is_ip4 "$ip" && [ "$((10#$len))" -le 32 ] && printf '%s' "$1"
}
v_ip4len() {   # 192.168.1.5/24 or dhcp
    VERR="use the form 192.168.1.5/24, or dhcp"
    [ "$1" = dhcp ] && { printf dhcp; return 0; }
    [[ $1 =~ ^([0-9.]+)/([0-9]{1,2})$ ]] || return 1
    local ip=${BASH_REMATCH[1]} len=${BASH_REMATCH[2]}
    is_ip4 "$ip" && [ "$((10#$len))" -ge 8 ] && [ "$((10#$len))" -le 30 ] && printf '%s' "$1"
}
v_ports() {
    VERR="list ports like: 22 8090"
    local -a list; local p out=""
    read -ra list <<<"${1//,/ }"
    for p in "${list[@]}"; do
        is_port "$p" || return 1
        p=$((10#$p))
        case " $out " in *" $p "*) ;; *) out="$out $p" ;; esac
    done
    printf '%s' "${out# }"
}
v_lanout() {
    VERR="list them like: 192.168.1.23:8686 192.168.1.24:8989"
    local -a list; local e ip port out=""
    read -ra list <<<"${1//,/ }"
    for e in "${list[@]}"; do
        [[ $e =~ ^([0-9.]+):([0-9]+)$ ]] || return 1
        ip=${BASH_REMATCH[1]}; port=${BASH_REMATCH[2]}
        is_ip4 "$ip" && is_port "$port" || return 1
        out="$out $ip:$((10#$port))"
    done
    printf '%s' "${out# }"
}
v_publish() {   # "8090 2222:22" → "8090:8090 2222:22"
    VERR="list ports like: 8090 9696, or outside:inside like 2222:22"
    local -a list; local e a b out=""
    read -ra list <<<"${1//,/ }"
    for e in "${list[@]}"; do
        if [[ $e =~ ^([0-9]+):([0-9]+)$ ]]; then a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
        elif [[ $e =~ ^[0-9]+$ ]]; then a=$e; b=$e
        else return 1; fi
        is_port "$a" && is_port "$b" || return 1
        out="$out $((10#$a)):$((10#$b))"
    done
    printf '%s' "${out# }"
}
v_name()  { VERR="use letters, digits, - and _ only"; [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,40}$ ]] && printf '%s' "$1"; }
v_host()  { VERR="use letters, digits and - only"; [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] && printf '%s' "$1"; }
v_url()   { VERR="enter a URL like https://ntfy.sh"; [[ $1 =~ ^https?://[^[:space:]]+$ ]] && printf '%s' "${1%/}"; }
v_path()  { VERR="can't read that file"; [ -f "$1" ] && [ -r "$1" ] && printf '%s' "$1"; }

# Read KEY=value lines from untrusted output into an associative array.
# Only plain keys and a safe character set get through; nothing is ever sourced.
SAFE_RE='^[][A-Za-z0-9._:/@ ,+=()#-]*$'
read_kv_into() {   # read_kv_into ARRAY prefix
    local -n __arr=$1
    local prefix=$2 line k v
    while IFS= read -r line; do
        line=${line%$'\r'}
        [[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || continue
        k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
        [[ $v =~ $SAFE_RE ]] || continue
        __arr["$prefix$k"]=$v
    done
}

