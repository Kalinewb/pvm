# ════════════════════════════════════════════════════════════
#  Host plumbing: pct, registry, settings, notifications
# ════════════════════════════════════════════════════════════
STAGE=""
cleanup() { cur_show; rm -f "$CT_CACHE" "$CT_CACHE.tmp"; [ -n "$STAGE" ] && rm -rf "$STAGE"; return 0; }
trap cleanup EXIT
trap 'exit 130' INT TERM
new_stage() { [ -n "$STAGE" ] && return 0; STAGE=$(mktemp -d /tmp/vpn-lxc.XXXXXX) || die "could not create a temp dir"; }

cexec()      { local ct=$1; shift; pct exec "$ct" -- "$@"; }
cpush()      { pct push "$1" "$2" "$3" --perms "${4:-600}" --user 0 --group 0 >/dev/null; }
# One `pct list` serves every status/name lookup for 2 seconds. Asking pct per
# container costs ~0.5s each, which made the pickers hang for half a minute.
CT_CACHE=/tmp/.vpn-lxc-ct.$$
ct_table() {
    local now mt
    now=$(printf '%(%s)T' -1)
    mt=$(stat -c %Y "$CT_CACHE" 2>/dev/null || echo 0)
    if [ "$((now - mt))" -ge 2 ]; then
        pct list 2>/dev/null > "$CT_CACHE.tmp" && mv -f "$CT_CACHE.tmp" "$CT_CACHE"
    fi
    cat "$CT_CACHE" 2>/dev/null
}
ct_forget()  { rm -f "$CT_CACHE"; }
ct_status()  { ct_table | awk -v id="$1" '$1 == id {print $2}'; }
ct_name()    { ct_table | awk -v id="$1" '$1 == id {print $NF}'; }
ct_exists()  { pct config "$1" >/dev/null 2>&1; }
ct_ids()     { ct_table | awk 'NR > 1 {print $1}'; }

kvfile_get() { [ -f "$1" ] && sed -n "s/^$2=//p" "$1" | head -n 1; }
kvfile_set() {   # kvfile_set FILE KEY VALUE
    local f=$1 k=$2 v=$3
    install -d -m 700 "$(dirname "$f")"
    touch "$f"; chmod 600 "$f"
    if grep -q "^$k=" "$f"; then
        local tmp; tmp=$(mktemp)
        awk -v k="$k" -v v="$v" 'BEGIN { FS = OFS = "=" } $1 == k { print k "=" v; next } { print }' "$f" > "$tmp" && cat "$tmp" > "$f"
        rm -f "$tmp"
    else
        printf '%s=%s\n' "$k" "$v" >> "$f"
    fi
}
kvfile_del() { [ -f "$1" ] && sed -i "/^$2=/d" "$1"; return 0; }
reg_get()  { kvfile_get "$REG/$1.env" "$2"; }
reg_set()  { kvfile_set "$REG/$1.env" "$2" "$3"; }
reg_del()  { rm -f "$REG/$1.env"; }
reg_ids()  { local f; for f in "$REG"/*.env; do [ -e "$f" ] && basename "$f" .env; done | sort -n; }
set_get()  { kvfile_get "$SETTINGS" "$1"; }
set_set()  { kvfile_set "$SETTINGS" "$1" "$2"; }

# notify "title" "message" [priority 1-5] [tags]
notify() {
    local title=$1 msg=$2 prio=${3:-3} tags=${4:-}
    local kind url topic token
    kind=$(set_get NOTIFY_KIND); url=$(set_get NOTIFY_URL); topic=$(set_get NOTIFY_TOPIC); token=$(set_get NOTIFY_TOKEN)
    case $kind in
        ntfy)
            local -a h=(-H "Title: $title" -H "Priority: $prio")
            [ -n "$tags" ] && h+=(-H "Tags: $tags")
            [ -n "$token" ] && h+=(-H "Authorization: Bearer $token")
            curl -s -m 10 -o /dev/null -w '%{http_code}' "${h[@]}" -d "$msg" "$url/$topic" | grep -q '^2' ;;
        gotify)
            curl -s -m 10 -o /dev/null -w '%{http_code}' -F "title=$title" -F "message=$msg" -F "priority=$((prio * 2))" \
                "$url/message?token=$token" | grep -q '^2' ;;
        *) return 0 ;;
    esac
}

host_lan_ip()  { ip -4 -o addr show scope global 2>/dev/null | awk '$2 ~ /^vmbr/ {split($4, a, "/"); print a[1]; exit}'; }
host_lan_gw()  { ip -4 route show default 2>/dev/null | awk '{print $3; exit}'; }
home_ip()      { local ip; ip=$(curl -4 -s -m 8 https://ifconfig.me/ip 2>/dev/null); is_ip4 "$ip" && printf '%s' "$ip"; }
