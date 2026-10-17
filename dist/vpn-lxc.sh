#!/bin/bash
# ╭──────────────────────────────────────────────────────────────╮
# │  vpn-lxc.sh · VPN for Proxmox containers                     │
# │                                                              │
# │  Two ways to put containers behind a VPN, with a kill switch │
# │    · per-container: each container runs its own tunnel      │
# │    · gateway: one VPN container + a private bridge; any      │
# │      container plugged into that bridge goes through it     │
# │                                                              │
# │  WireGuard or OpenVPN · Mullvad, Proton, AirVPN, any other   │
# │  port forwarding · dashboard · watchdog with failover ·      │
# │  saved config library · ntfy / Gotify notifications          │
# ╰──────────────────────────────────────────────────────────────╯
#
# Run on the PROXMOX HOST as root:
#   bash vpn-lxc.sh               the full-screen app
#   bash vpn-lxc.sh status CTID   status screen for one container
#   bash vpn-lxc.sh watchdog      one watchdog round (the timer runs this)
#   bash vpn-lxc.sh --help

[ -n "$BASH_VERSION" ] || exec bash "$0" "$@"
set -o pipefail
umask 077
export LC_ALL=C.UTF-8

VERSION="2.4.1"
REPO_RAW=${VPNLXC_RAW:-https://raw.githubusercontent.com/Kalinewb/vpn-lxc}
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
ETC=${VPNLXC_ETC:-/etc/vpn-lxc}
VARD=${VPNLXC_VAR:-/var/lib/vpn-lxc}
IFACES_FILE=${VPNLXC_IFACES:-/etc/network/interfaces}
LIB=$ETC/library
REG=$ETC/registry
SETTINGS=$ETC/settings.env
STAGE_CT=/root/.vpnguard-stage
ANIM=${VPNLXC_ANIM:-1}

# ════════════════════════════════════════════════════════════
#  Look & feel
# ════════════════════════════════════════════════════════════
FANCY=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then FANCY=1; fi
TRUECOLOR=0
case ${COLORTERM:-} in truecolor|24bit) TRUECOLOR=1 ;; esac

if [ "$FANCY" = 1 ]; then
    R=$'\e[0m'; B=$'\e[1m'; DIM=$'\e[2m'; IT=$'\e[3m'
    CY=$'\e[38;5;81m'; VI=$'\e[38;5;141m'; PK=$'\e[38;5;213m'
    OK=$'\e[38;5;84m'; ER=$'\e[38;5;203m'; WA=$'\e[38;5;221m'
    GR=$'\e[38;5;249m'; DG=$'\e[38;5;241m'; WH=$'\e[38;5;255m'
    CHIPBG=$'\e[48;5;236m'; SELBG=$'\e[48;5;24m'; BARBG=$'\e[48;5;235m'; F0=$'\e[39;22m'
else
    R=""; B=""; DIM=""; IT=""; CY=""; VI=""; PK=""; OK=""; ER=""; WA=""; GR=""; DG=""; WH=""; CHIPBG=""; SELBG=""; BARBG=""; F0=""
    ANIM=0
fi

# The layout follows the terminal: re-read the size whenever a screen is drawn, so a resize shows on the next screen.
fit() {
    COLS=$(tput cols 2>/dev/null || echo 80)
    [[ $COLS =~ ^[0-9]+$ ]] || COLS=80
    W=$((COLS - 4)); [ "$W" -gt 240 ] && W=240; [ "$W" -lt 50 ] && W=50
}
fit

# statusbar "hints" : a full-width bar on the last row (keys on the left, host and time on the right)
statusbar() {
    [ "$INTERACTIVE" = 1 ] || return 0
    local rows left right pad
    rows=$(tput lines 2>/dev/null || echo 24); [[ $rows =~ ^[0-9]+$ ]] || return 0
    [ "$rows" -ge 22 ] || return 0
    left=" vpn-lxc $VERSION   ${1:-}"
    right="$(hostname) · $(date +%H:%M) "
    pad=$((COLS - ${#left} - ${#right})); [ "$pad" -lt 1 ] && pad=1
    printf '\e7\e[%d;1H%s%s%s%*s%s%s\e8' "$rows" "$BARBG" "$WH" "$left" "$pad" "" "$right" "$R"
}

# full-screen mode: the app draws on the terminal's alternate screen and leaves your scrollback as it was
ALT=0
screen_enter() { if [ "$INTERACTIVE" = 1 ] && [ "$ALT" = 0 ]; then printf '\e[?1049h\e[H\e[2J'; ALT=1; fi; return 0; }
screen_leave() { if [ "$ALT" = 1 ]; then printf '\e[?1049l'; ALT=0; fi; return 0; }

GRAD256=(51 45 39 33 63 99 135 171 207)

vislen() { local s; s=$(printf '%s' "$1" | sed $'s/\x1b\\[[0-9;]*m//g'); printf '%s' "${#s}"; }
rep()    { local n=$2 s=""; while [ "$n" -gt 0 ]; do s+=$1; n=$((n - 1)); done; printf '%s' "$s"; }
nap()    { [ "$ANIM" = 1 ] && sleep "$1"; return 0; }
padr()   { local l; l=$(vislen "$1"); printf '%s%*s' "$1" "$(( $2 > l ? $2 - l : 0 ))" ''; }   # pad by characters, not bytes

# gradient across a string: cyan → violet → pink
grad() {
    local text=$1 n=${#1} i ch out=""
    [ "$FANCY" = 1 ] || { printf '%s' "$text"; return; }
    [ "$n" -gt 1 ] || n=2
    for ((i = 0; i < ${#text}; i++)); do
        ch=${text:i:1}
        if [ "$ch" = " " ]; then out+=" "; continue; fi
        if [ "$TRUECOLOR" = 1 ]; then
            local t=$((i * 1000 / (n - 1))) r g b
            if [ "$t" -lt 500 ]; then r=$((80 + t * 190 / 500)); g=$((230 - t * 130 / 500)); b=255
            else r=$((255)); g=$((100 + (t - 500) * 20 / 500)); b=$((255 - (t - 500) * 55 / 500)); fi
            out+=$'\e[38;2;'"$r;$g;$b"'m'"$ch"
        else
            out+=$'\e[38;5;'"${GRAD256[$((i * (${#GRAD256[@]} - 1) / (n - 1)))]}"'m'"$ch"
        fi
    done
    printf '%s%s' "$out" "$R"
}

clr()       { [ "$FANCY" = 1 ] && printf '\r\e[K'; return 0; }
cls()       { [ "$FANCY" = 1 ] && printf '\e[H\e[2J'; return 0; }
cur_hide()  { [ "$FANCY" = 1 ] && printf '\e[?25l'; return 0; }
cur_show()  { [ "$FANCY" = 1 ] && printf '\e[?25h'; return 0; }
rule()      { printf '  %s%s%s\n' "$DG" "$(rep ─ "$W")" "$R"; }
chip()      { printf '%s%s %s %s' "$CHIPBG" "${2:-$WH}" "$1" "$R"; }
keyhint()   { printf '%s%s %s %s %s%s%s' "$CHIPBG" "$WH" "$1" "$R" "$GR" "$2" "$R"; }

ok()   { printf '    %s✔%s %s\n' "$OK" "$R" "$*"; }
warn() { printf '    %s▲%s %s\n' "$WA" "$R" "$*"; }
bad()  { printf '    %s✘%s %s\n' "$ER" "$R" "$*"; }
note() { printf '    %s%s%s\n' "$GR" "$*" "$R"; }
kv()   { printf '    %s%-20s%s %s\n' "$GR" "$1" "$R" "$2"; }
para() { printf '%s\n' "$*" | fold -s -w "$((W - 2))" | sed "s/^/    ${GR//\\/\\\\}/; s/\$/${R//\\/\\\\}/"; }
die()  { cur_show; printf '\n    %s✘ %s%s\n\n' "$ER" "$*" "$R" >&2; exit 1; }

box_top() {
    local t=" $1 " n
    n=$((W - 3 - $(vislen "$t")))
    [ "$n" -lt 0 ] && n=0
    printf '  %s╭─%s%s%s╮%s\n' "$DG" "$R$B$t$R" "$DG" "$(rep ─ "$n")" "$R"
}
box_row() {
    local text=$1 n plain line first=1
    n=$((W - 4 - $(vislen "$text")))
    if [ "$n" -ge 0 ]; then
        printf '  %s│%s %s%*s %s│%s\n' "$DG" "$R" "$text" "$n" "" "$DG" "$R"
        return
    fi
    # too long: drop the colours and wrap. A "label   value" row keeps its
    # continuation lines under the value; anything else wraps flush left.
    plain=$(printf '%s' "$text" | sed $'s/\x1b\\[[0-9;]*m//g')
    local pad=0 room=$((W - 4)) label="" ind
    if [[ $plain =~ ^([^[:space:]]+([[:space:]][^[:space:]]+)?[[:space:]]{2,}) ]] && [ "${#BASH_REMATCH[1]}" -le 20 ]; then
        pad=${#BASH_REMATCH[1]}
        label=${plain:0:pad}; plain=${plain:pad}
    fi
    ind=$(printf '%*s' "$pad" '')
    while IFS= read -r line; do
        if [ "$first" = 1 ]; then line="$label$line"; else line="$ind$line"; fi
        first=0
        n=$((W - 4 - ${#line})); [ "$n" -lt 0 ] && n=0
        printf '  %s│%s %s%*s %s│%s\n' "$DG" "$R" "$line" "$n" "" "$DG" "$R"
    done < <(printf '%s\n' "$plain" | fold -s -w "$((room - pad))" | awk 'NR == 1 {print; next} {sub(/^ +/, ""); print}')
}
box_bot() { printf '  %s╰%s╯%s\n' "$DG" "$(rep ─ "$((W - 2))")" "$R"; }

LOGO=(
'██╗   ██╗██████╗ ███╗   ██╗   ██╗     ██╗  ██╗ ██████╗'
'██║   ██║██╔══██╗████╗  ██║   ██║     ╚██╗██╔╝██╔════╝'
'██║   ██║██████╔╝██╔██╗ ██║   ██║      ╚███╔╝ ██║     '
'╚██╗ ██╔╝██╔═══╝ ██║╚██╗██║   ██║      ██╔██╗ ██║     '
' ╚████╔╝ ██║     ██║ ╚████║   ███████╗██╔╝ ██╗╚██████╗'
'  ╚═══╝  ╚═╝     ╚═╝  ╚═══╝   ╚══════╝╚═╝  ╚═╝ ╚═════╝'
)
LOGO_SHOWN=0
big_logo() {
    local l
    echo
    for l in "${LOGO[@]}"; do
        printf '   %s\n' "$(grad "$l")"
        [ "$LOGO_SHOWN" = 0 ] && nap 0.035
    done
    printf '   %s%s%s\n' "$GR" "w i r e g u a r d  ·  o p e n v p n  ·  k i l l   s w i t c h  ·  g a t e w a y" "$R"
    LOGO_SHOWN=1
}

# ════════════════════════════════════════════════════════════
#  Pages
# ════════════════════════════════════════════════════════════
FLOW=""; PAGE_NO=0; PAGE_TOTAL=0; CONTEXT=""

pbar() {   # pbar <done> <total> <width>
    local d=$1 t=$2 w=$3 f i s=""
    [ "$t" -gt 0 ] || t=1
    f=$((d * w / t))
    local filled; filled=$(rep ━ "$f")
    s+=$(grad "$filled")
    s+="$DG$(rep ━ $((w - f)))$R"
    printf '%s' "$s"
}

page() {   # page "Title" ["subtitle"]
    fit; cls
    local head right n
    head="$(grad '◆ VPN·LXC')  ${GR}v$VERSION$R"
    right="$GR$FLOW$R"
    n=$((W - $(vislen "$head") - $(vislen "$right")))
    [ "$n" -lt 1 ] && n=1
    printf '\n  %s%*s%s\n' "$head" "$n" "" "$right"
    if [ "$PAGE_TOTAL" -gt 0 ]; then
        printf '  %s  %sstep %s of %s%s\n' "$(pbar "$PAGE_NO" "$PAGE_TOTAL" $((W - 14)))" "$GR" "$PAGE_NO" "$PAGE_TOTAL" "$R"
    else
        printf '  %s\n' "$(pbar 1 1 "$W")"
    fi
    local keys
    keys="$(keyhint '⏎' next)  $(keyhint b back)  $(keyhint q quit)"
    # the status bar at the bottom already shows the keys on a real terminal
    [ "$INTERACTIVE" = 1 ] && [ "$(tput lines 2>/dev/null || echo 0)" -ge 22 ] && keys=""
    if [ -n "$CONTEXT" ] && [ -z "$keys" ]; then printf '  %s\n' "$CONTEXT"
    elif [ -n "$CONTEXT" ]; then
        n=$((W - $(vislen "$CONTEXT") - $(vislen "$keys")))
        [ "$n" -lt 1 ] && n=1
        printf '  %s%*s%s\n' "$CONTEXT" "$n" "" "$keys"
    elif [ "$PAGE_TOTAL" -gt 0 ] && [ -n "$keys" ]; then
        n=$((W - $(vislen "$keys")))
        printf '  %*s%s\n' "$n" "" "$keys"
    fi
    echo
    statusbar "$([ "$PAGE_TOTAL" -gt 0 ] && echo "⏎ next   b back   q quit" || echo "b back   q quit")"
    printf '  %s▍%s %s%s%s\n' "$VI" "$R" "$B$WH" "$1" "$R"
    [ -n "${2:-}" ] && para "$2"
    echo
}

footer() {
    echo
    rule
    printf '  %s   %s   %s\n' "$(keyhint '⏎' next)" "$(keyhint b back)" "$(keyhint q quit)"
    echo
}

# ════════════════════════════════════════════════════════════
#  Widgets. All return 0 = ok, 1 = back, 2 = quit.
# ════════════════════════════════════════════════════════════
trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }

readline() {   # readline VAR   (EOF on stdin = quit)
    local __l
    cur_show
    IFS= read -r __l || { printf -v "$1" '%s' "q"; return 0; }
    printf -v "$1" '%s' "$(trim "$__l")"
}

confirm_quit() {
    local a
    printf '    %s?%s Leave without applying anything? %s[y/N]%s ' "$WA" "$R" "$GR" "$R"
    if [ "$INTERACTIVE" = 1 ]; then
        read_key; clr
        case $KEY in y|Y) return 0 ;; *) return 1 ;; esac
    fi
    readline a
    case $a in y|Y|yes|q|Q) return 0 ;; *) return 1 ;; esac
}

# field VAR "Label" "default" [validator]   validator prints the clean value or fails
field() {
    local __var=$1 __label=$2 __def=${3-} __vf=${4:-v_any} __a __out
    while true; do
        statusbar "type a value   ⏎ accept the suggestion   b back   q quit"
        if [ -n "$__def" ]; then
            printf '    %s›%s %s %s[%s]%s ' "$CY" "$R" "$__label" "$GR" "$__def" "$R"
        else
            printf '    %s›%s %s ' "$CY" "$R" "$__label"
        fi
        readline __a
        case $__a in
            b|B|'<') return 1 ;;
            q|Q) confirm_quit && return 2; continue ;;
        esac
        [ -z "$__a" ] && __a=$__def
        [ "$__a" = "-" ] && __a=""
        if __out=$("$__vf" "$__a"); then
            printf -v "$__var" '%s' "$__out"
            return 0
        fi
        # the check above ran in a subshell, so its message was lost: run it again here to get it
        VERR=""; "$__vf" "$__a" >/dev/null 2>&1
        printf '      %s✘ %s%s\n' "$ER" "${VERR:-that does not look right}" "$R"
    done
}

# yn VAR "Question" [y|n]
yn_text() {
    local __var=$1 __q=$2 __def=${3:-y} __a __hint="Y/n"
    [ "$__def" = n ] && __hint="y/N"
    while true; do
        printf '    %s?%s %s %s[%s]%s ' "$CY" "$R" "$__q" "$GR" "$__hint" "$R"
        readline __a
        case ${__a:-$__def} in
            y|Y|yes) printf -v "$__var" y; return 0 ;;
            n|N|no)  printf -v "$__var" n; return 0 ;;
            b|B|'<') return 1 ;;
            q|Q) confirm_quit && return 2 ;;
        esac
    done
}

secret() {   # secret VAR "Label"
    local __a
    printf '    %s›%s %s %s(hidden)%s ' "$CY" "$R" "$2" "$GR" "$R"
    cur_show
    IFS= read -rs __a || __a=""
    echo
    printf -v "$1" '%s' "$__a"
}

NUMS=(① ② ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨ ⑩ ⑪ ⑫ ⑬ ⑭ ⑮ ⑯ ⑰ ⑱ ⑲ ⑳)
num() { if [ "$1" -le 20 ]; then printf '%s  ' "${NUMS[$(($1 - 1))]}"; else printf '%-3s' "$1"; fi; }   # always 3 columns wide

# pick VAR "Prompt" default "key|Label|description" ...     sets VAR to the key
pick_text() {
    local __var=$1 __q=$2 __def=$3 i=1 it k l d __a
    shift 3
    local -a keys=()
    for it in "$@"; do
        IFS='|' read -r k l d <<<"$it"
        keys+=("$k")
        printf '    %s%s%s%s%s%s %s%s%s\n' "$CY" "$(num "$i")" "$R" "$B" "$(padr "$l" 22)" "$R" "$GR" "$d" "$R"
        i=$((i + 1))
    done
    echo
    local defn=""
    for ((i = 0; i < ${#keys[@]}; i++)); do [ "${keys[i]}" = "$__def" ] && defn=$((i + 1)); done
    while true; do
        if [ -n "$defn" ]; then printf '    %s›%s %s %s[%s]%s ' "$CY" "$R" "$__q" "$GR" "$defn" "$R"
        else printf '    %s›%s %s ' "$CY" "$R" "$__q"; fi
        readline __a
        case $__a in
            b|B|'<') return 1 ;;
            q|Q) confirm_quit && return 2; continue ;;
        esac
        [ -z "$__a" ] && __a=$defn
        if [[ $__a =~ ^[0-9]+$ ]] && [ "$__a" -ge 1 ] && [ "$__a" -le ${#keys[@]} ]; then
            printf -v "$__var" '%s' "${keys[$((__a - 1))]}"
            return 0
        fi
        for k in "${keys[@]}"; do
            [ "$k" = "$__a" ] && { printf -v "$__var" '%s' "$k"; return 0; }
        done
        if [ "${#keys[@]}" = 1 ]; then printf '      %s✘ pick 1%s\n' "$ER" "$R"
        else printf '      %s✘ pick 1 to %s%s\n' "$ER" "${#keys[@]}" "$R"; fi
    done
}

# checklist VAR "Prompt" "id|Label|description|1 or 0" ...   sets VAR to the chosen ids
checklist_text() {
    local __var=$1 __q=$2 it id l d on i n __a
    shift 2
    local -a ids=() labels=() descs=() state=()
    for it in "$@"; do
        IFS='|' read -r id l d on <<<"$it"
        ids+=("$id"); labels+=("$l"); descs+=("$d"); state+=("${on:-0}")
    done
    n=${#ids[@]}
    [ "$FANCY" = 1 ] && printf '\e7'
    while true; do
        [ "$FANCY" = 1 ] && printf '\e8\e[J'
        for ((i = 0; i < n; i++)); do
            if [ "${state[i]}" = 1 ]; then
                printf '    %s%s%s%s◉%s %s%s%s %s%s%s\n' "$CY" "$(num $((i + 1)))" "$R" "$OK" "$R" "$B" "$(padr "${labels[i]}" 24)" "$R" "$GR" "${descs[i]}" "$R"
            else
                printf '    %s%s%s%s○%s %s %s%s%s\n' "$CY" "$(num $((i + 1)))" "$R" "$DG" "$R" "$(padr "${labels[i]}" 24)" "$GR" "${descs[i]}" "$R"
            fi
        done
        echo
        printf '    %stype numbers or IDs to toggle (e.g. 1 3), a = all, n = none, ⏎ = done%s\n' "$GR" "$R"
        printf '    %s›%s %s ' "$CY" "$R" "$__q"
        readline __a
        case $__a in
            b|B|'<') return 1 ;;
            q|Q) confirm_quit && return 2; continue ;;
            a|A) for ((i = 0; i < n; i++)); do state[i]=1; done; continue ;;
            n|N) for ((i = 0; i < n; i++)); do state[i]=0; done; continue ;;
            "")
                local out=""
                for ((i = 0; i < n; i++)); do [ "${state[i]}" = 1 ] && out="$out ${ids[i]}"; done
                printf -v "$__var" '%s' "${out# }"
                return 0 ;;
        esac
        local t
        for t in ${__a//,/ }; do
            local hit=0 j
            for ((j = 0; j < n; j++)); do
                if [ "${ids[j]}" = "$t" ]; then state[j]=$((1 - state[j])); hit=1; break; fi
            done
            if [ "$hit" = 0 ] && [[ $t =~ ^[0-9]+$ ]] && [ "$t" -ge 1 ] && [ "$t" -le "$n" ]; then
                state[t - 1]=$((1 - state[t - 1]))
            fi
        done
    done
}


# ════════════════════════════════════════════════════════════
#  Arrow-key widgets. On a real terminal pick / checklist / yn use these;
#  piped input (scripts, tests) falls back to the numbered text prompts above.
# ════════════════════════════════════════════════════════════
INTERACTIVE=0
if [ "$FANCY" = 1 ] && [ -t 0 ]; then INTERACTIVE=1; fi

# bar_row TEXT : one list row drawn as a highlighted bar the width of the layout
bar_row() {
    local text=$1 pad
    pad=$((W - 1 - $(vislen "$text"))); [ "$pad" -lt 0 ] && pad=0
    printf '  %s%s%*s%s\n' "$SELBG" "$text" "$pad" "" "$R"
}

# read_key : sets KEY to up down left right home end pgup pgdn enter space esc bksp eof, or the character
KEY=""
read_key() {
    local k rest="" x
    IFS= read -rsn1 k || { KEY=eof; return 0; }
    case $k in
        $'\e')
            IFS= read -rsn2 -t 0.05 rest || true
            case $rest in
                '[A'|'OA') KEY=up ;;   '[B'|'OB') KEY=down ;;
                '[C'|'OC') KEY=right ;; '[D'|'OD') KEY=left ;;
                '[H'|'OH') KEY=home ;;  '[F'|'OF') KEY=end ;;
                '[5') IFS= read -rsn1 -t 0.05 x || true; KEY=pgup ;;
                '[6') IFS= read -rsn1 -t 0.05 x || true; KEY=pgdn ;;
                '[1'|'[4'|'[3'|'[2') IFS= read -rsn1 -t 0.05 x || true; KEY=other ;;
                '') KEY=esc ;;
                *) KEY=other ;;
            esac ;;
        '') KEY=enter ;;
        ' ') KEY=space ;;
        $'\t') KEY=tab ;;
        $'\x7f'|$'\b') KEY=bksp ;;
        $'\x03') KEY=q ;;
        *) KEY=$k ;;
    esac
    return 0
}

list_rows() {   # how many list rows fit on this screen
    local r v
    r=$(tput lines 2>/dev/null || echo 24); [[ $r =~ ^[0-9]+$ ]] || r=24
    v=$((r - 15)); [ "$v" -lt 5 ] && v=5
    echo "$v"
}

# move the highlight; keeps the window scrolled so it stays visible
list_move() {   # list_move DELTA  (uses cur top vis n of the caller)
    case $1 in
        up)    cur=$(( (cur + n - 1) % n )) ;;
        down)  cur=$(( (cur + 1) % n )) ;;
        home)  cur=0 ;;
        end)   cur=$((n - 1)) ;;
        pgup)  cur=$((cur - vis)); [ "$cur" -lt 0 ] && cur=0 ;;
        pgdn)  cur=$((cur + vis)); [ "$cur" -ge "$n" ] && cur=$((n - 1)) ;;
    esac
    [ "$cur" -lt "$top" ] && top=$cur
    [ "$cur" -ge $((top + vis)) ] && top=$((cur - vis + 1))
    return 0
}

# typing digits jumps to that number
list_digits() {   # list_digits CHAR : returns 0 if it moved the highlight
    [[ $1 =~ ^[0-9]$ ]] || return 1
    local t="${numbuf}$1" j prefix=0
    for ((j = 0; j < n; j++)); do
        local key=${ids[j]:-${keys[j]:-}}
        # a typed container ID (or any item key) wins over a list position
        if [ "$key" = "$t" ]; then numbuf=$t; cur=$j; prefix=2; break; fi
        [[ $key == "$t"* ]] && prefix=1
    done
    if [ "$prefix" = 1 ]; then numbuf=$t; return 0; fi            # still typing an ID: wait for the next digit
    if [ "$prefix" = 0 ]; then
        if [ "$t" -ge 1 ] && [ "$t" -le "$n" ]; then numbuf=$t; cur=$((t - 1))
        elif [ "$1" -ge 1 ] && [ "$1" -le "$n" ]; then numbuf=$1; cur=$(($1 - 1))
        else numbuf=""; return 0; fi
    fi
    [ "$cur" -lt "$top" ] && top=$cur
    [ "$cur" -ge $((top + vis)) ] && top=$((cur - vis + 1))
    return 0
}

# pick VAR "Prompt" default "key|Label|description" ...   (arrow keys, Enter)
pick() {
    [ "$INTERACTIVE" = 1 ] || { pick_text "$@"; return; }
    local __var=$1 __q=$2 __def=$3 it k l d i
    shift 3
    local -a keys=() labels=() descs=()
    for it in "$@"; do
        IFS='|' read -r k l d <<<"$it"
        keys+=("$k"); labels+=("$l"); descs+=("$d")
    done
    local n=${#keys[@]} cur=0 top=0 numbuf="" vis drawn gap=0 rows
    rows=$(tput lines 2>/dev/null || echo 24); [[ $rows =~ ^[0-9]+$ ]] || rows=24
    [ "$rows" -ge 36 ] && [ "$n" -le 10 ] && gap=1          # a tall terminal: a blank line between choices
    for ((i = 0; i < n; i++)); do [ "${keys[i]}" = "$__def" ] && cur=$i; done
    vis=$(( $(list_rows) / (1 + gap) )); [ "$vis" -lt 3 ] && vis=3; [ "$vis" -gt "$n" ] && vis=$n
    [ "$cur" -ge "$vis" ] && top=$((cur - vis + 1))
    drawn=$((vis * (1 + gap) + 2))
    if [ "$rows" -ge 22 ]; then printf '    %s›%s %s\n' "$CY" "$R" "$__q"      # the status bar shows the keys
    else printf '    %s›%s %s  %s↑↓ move · ⏎ choose · b back · q quit%s\n' "$CY" "$R" "$__q" "$GR" "$R"; fi
    [ "$gap" = 1 ] && printf '\n'
    cur_hide
    local first=1
    while true; do
        [ "$first" = 1 ] || printf '\e[%dA\e[J' "$((drawn - 1))"
        first=0
        for ((i = top; i < top + vis; i++)); do
            if [ "$i" = "$cur" ]; then
                bar_row "$(printf '%s❯%s %s%s%s%s%s%s %s%s%s' "$PK" "$F0" "$CY" "$(num $((i + 1)))" "$F0" "$B$WH" "$(padr "${labels[i]}" 22)" "$F0" "$GR" "${descs[i]}" "$F0")"
            else
                printf '    %s%s%s%s %s%s%s\n' "$CY" "$(num $((i + 1)))" "$R" "$(padr "${labels[i]}" 22)" "$GR" "${descs[i]}" "$R"
            fi
            [ "$gap" = 1 ] && printf '\n'
        done
        if [ "$n" -gt "$vis" ]; then printf '    %s%s of %s%s\n' "$DG" "$((cur + 1))" "$n" "$R"; else printf '\n'; fi
        statusbar "↑↓ move   ⏎ choose   b back   q quit"
        read_key
        [[ $KEY =~ ^[0-9]$ ]] || numbuf=""
        case $KEY in
            up|down|home|end|pgup|pgdn) list_move "$KEY" ;;
            k) list_move up ;;
            j) list_move down ;;
            enter|right)
                printf -v "$__var" '%s' "${keys[cur]}"
                cur_show; return 0 ;;
            left|esc|b|B) cur_show; return 1 ;;
            q|Q) if confirm_quit; then cur_show; return 2; fi ;;
            eof) cur_show; return 2 ;;
            *) list_digits "$KEY" || true ;;
        esac
    done
}

# checklist VAR "Prompt" "id|Label|description|1 or 0" ...   (Space toggles, Enter confirms)
checklist() {
    [ "$INTERACTIVE" = 1 ] || { checklist_text "$@"; return; }
    local __var=$1 __q=$2 it id l d on i
    shift 2
    local -a ids=() labels=() descs=() state=()
    for it in "$@"; do
        IFS='|' read -r id l d on <<<"$it"
        ids+=("$id"); labels+=("$l"); descs+=("$d"); state+=("${on:-0}")
    done
    local n=${#ids[@]} cur=0 top=0 numbuf="" vis drawn
    vis=$(list_rows); [ "$vis" -gt "$n" ] && vis=$n
    drawn=$((vis + 2))
    local crow; crow=$(tput lines 2>/dev/null || echo 24)
    if [ "${crow:-24}" -ge 22 ]; then printf '    %s›%s %s\n' "$CY" "$R" "$__q"
    else printf '    %s›%s %s  %s↑↓ move · space tick · a all · n none · ⏎ done · b back · q quit%s\n' "$CY" "$R" "$__q" "$GR" "$R"; fi
    cur_hide
    local first=1 mark
    while true; do
        [ "$first" = 1 ] || printf '\e[%dA\e[J' "$((drawn - 1))"
        first=0
        for ((i = top; i < top + vis; i++)); do
            if [ "${state[i]}" = 1 ]; then mark="${OK}◉${R}"; else mark="${DG}○${R}"; fi
            if [ "$i" = "$cur" ]; then
                bar_row "$(printf '%s❯%s %s%s%s %s %s%s%s %s%s%s' "$PK" "$F0" "$CY" "$(num $((i + 1)))" "$F0" "${mark//$R/$F0}" "$B$WH" "$(padr "${labels[i]}" 24)" "$F0" "$GR" "${descs[i]}" "$F0")"
            else
                printf '    %s%s%s %s %s %s%s%s\n' "$CY" "$(num $((i + 1)))" "$R" "$mark" "$(padr "${labels[i]}" 24)" "$GR" "${descs[i]}" "$R"
            fi
        done
        if [ "$n" -gt "$vis" ]; then printf '    %s%s of %s%s\n' "$DG" "$((cur + 1))" "$n" "$R"; else printf '\n'; fi
        statusbar "↑↓ move   space tick   a all   n none   ⏎ done   b back"
        read_key
        [[ $KEY =~ ^[0-9]$ ]] || numbuf=""
        case $KEY in
            up|down|home|end|pgup|pgdn) list_move "$KEY" ;;
            k) list_move up ;;
            j) list_move down ;;
            space|right) state[cur]=$((1 - state[cur])) ;;
            a|A) for ((i = 0; i < n; i++)); do state[i]=1; done ;;
            n|N) for ((i = 0; i < n; i++)); do state[i]=0; done ;;
            enter)
                local out=""
                for ((i = 0; i < n; i++)); do [ "${state[i]}" = 1 ] && out="$out ${ids[i]}"; done
                printf -v "$__var" '%s' "${out# }"
                cur_show; return 0 ;;
            left|esc|b|B) cur_show; return 1 ;;
            q|Q) if confirm_quit; then cur_show; return 2; fi ;;
            eof) cur_show; return 2 ;;
            *) list_digits "$KEY" || true ;;
        esac
    done
}

# yn VAR "Question" [y|n]   (←/→ or y/n, Enter takes the highlighted answer)
yn() {
    [ "$INTERACTIVE" = 1 ] || { yn_text "$@"; return; }
    local __var=$1 __q=$2 __def=${3:-y} cur=0 yes no
    [ "$__def" = n ] && cur=1
    cur_hide
    while true; do
        if [ "$cur" = 0 ]; then yes="$CHIPBG$B$WH  Yes  $R"; no="$GR  No  $R"; else yes="$GR  Yes  $R"; no="$CHIPBG$B$WH  No  $R"; fi
        printf '\r\e[K    %s?%s %s  %s %s  %s←→ · y/n · ⏎ · b back%s' "$CY" "$R" "$__q" "$yes" "$no" "$DG" "$R"
        read_key
        case $KEY in
            left|right|tab|h|l|space) cur=$((1 - cur)) ;;
            y|Y) cur=0; KEY=enter ;;
            n|N) cur=1; KEY=enter ;;
        esac
        case $KEY in
            enter)
                local ans=y; [ "$cur" = 1 ] && ans=n
                printf '\r\e[K    %s?%s %s  %s%s%s\n' "$CY" "$R" "$__q" "$B" "$([ "$ans" = y ] && echo Yes || echo No)" "$R"
                printf -v "$__var" '%s' "$ans"; cur_show; return 0 ;;
            esc|b|B) clr; cur_show; return 1 ;;
            q|Q) if confirm_quit; then clr; cur_show; return 2; fi ;;
            eof) cur_show; return 2 ;;
        esac
    done
}

# paste_block FILE : read a pasted block silently until a line "END" or Ctrl-D
paste_block() {
    local f=$1 line count=0
    : > "$f"
    printf '    %sPaste the whole config now, then type %sEND%s%s on its own line (or press Ctrl-D).%s\n' "$GR" "$WH$B" "$R" "$GR" "$R"
    printf '    %sNothing is shown on screen while you paste, so the key never sits in your scrollback.%s\n\n' "$GR" "$R"
    cur_hide
    while IFS= read -rs line; do
        line=${line//$'\e[200~'/}; line=${line//$'\e[201~'/}; line=${line%$'\r'}
        [ "$(trim "$line")" = END ] && break
        printf '%s\n' "$line" >> "$f"
        count=$((count + 1))
        printf '\r    %s◉%s receiving… %s%d lines%s ' "$PK" "$R" "$B" "$count" "$R"
    done
    clr
    cur_show
    printf '    %s✔%s received %s lines\n' "$OK" "$R" "$count"
    [ "$count" -gt 0 ]
}

# run_task "label" cmd...  : spinner while it runs, ✔/✘ with timing after
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
TASK_LOG=""
run_task() {
    local label=$1; shift
    TASK_LOG=$(mktemp "${STAGE:-/tmp}/task.XXXXXX")
    local start=$SECONDS i=0
    "$@" >"$TASK_LOG" 2>&1 &
    local pid=$!
    cur_hide
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$FANCY" = 1 ]; then
            printf '\r    %s%s%s %s' "$PK" "${SPIN[i % 10]}" "$R" "$label"
            i=$((i + 1)); sleep 0.08
        else
            sleep 0.2
        fi
    done
    wait "$pid"; local rc=$?
    local took=$((SECONDS - start))
    clr
    if [ "$rc" = 0 ]; then printf '    %s✔%s %s %s%ss%s\n' "$OK" "$R" "$label" "$DG" "$took" "$R"
    else
        printf '    %s✘%s %s\n' "$ER" "$R" "$label"
        tail -n 6 "$TASK_LOG" | sed "s/^/        ${GR//\\/\\\\}/; s/\$/${R//\\/\\\\}/"
    fi
    cur_show
    return "$rc"
}

# render_stream : draws STEP/WARN/FAIL lines from apply.sh, keeps RESULT k=v in RESULTS[]
declare -A RESULTS=()
render_stream() {
    local line i=0 rc
    cur_hide
    while true; do
        IFS= read -r -t 0.1 line; rc=$?
        if [ "$rc" = 0 ]; then
            clr
            case $line in
                "STEP "*)   printf '    %s✔%s %s\n' "$OK" "$R" "${line#STEP }"; nap 0.04 ;;
                "WARN "*)   printf '    %s▲%s %s\n' "$WA" "$R" "${line#WARN }" ;;
                "FAIL "*)   printf '    %s✘%s %s\n' "$ER" "$R" "${line#FAIL }" ;;
                "RESULT "*) local kvp=${line#RESULT }; RESULTS[${kvp%%=*}]=${kvp#*=} ;;
                *)          [ -n "$line" ] && printf '      %s%s%s\n' "$DG" "$line" "$R" ;;
            esac
        elif [ "$rc" -gt 128 ]; then
            [ "$FANCY" = 1 ] && printf '\r    %s%s%s %sworking…%s' "$PK" "${SPIN[i % 10]}" "$R" "$GR" "$R"
            i=$((i + 1))
        else
            break
        fi
    done
    clr
    cur_show
}

pause() {
    local a
    printf '\n    %s%s%s ' "$GR" "${1:-press any key to continue}" "$R"
    if [ "$INTERACTIVE" = 1 ]; then read_key; printf '\n'; return 0; fi
    readline a
}

# run_pages "func arg" ... : the wizard engine, with back navigation
# Pages return 0 = next, 1 = back, 2 = quit, 3 = "doesn't apply, skip me".
# run_pages returns 1 when you go back past its first page.
# PB = page number offset, PAGE_TOTAL = total pages (set by the caller).
DIR=fwd; PB=0
run_pages() {
    local -a P=("$@")
    local i=0 rc
    [ "$DIR" = back ] && i=$((${#P[@]} - 1))
    while [ "$i" -lt "${#P[@]}" ]; do
        PAGE_NO=$((PB + i + 1))
        # shellcheck disable=SC2086
        set -- ${P[i]}
        "$@"; rc=$?
        case $rc in
            0) DIR=fwd; i=$((i + 1)) ;;
            1) DIR=back; [ "$i" -eq 0 ] && return 1; i=$((i - 1)) ;;
            3) if [ "$DIR" = back ]; then [ "$i" -eq 0 ] && return 1; i=$((i - 1))
               else i=$((i + 1)); fi ;;
            *) return 2 ;;
        esac
    done
    DIR=fwd
    return 0
}

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

# ════════════════════════════════════════════════════════════
#  Host plumbing: pct, registry, settings, notifications
# ════════════════════════════════════════════════════════════
STAGE=""
cleanup() { screen_leave; cur_show; rm -f "$CT_CACHE" "$CT_CACHE.tmp"; [ -n "$STAGE" ] && rm -rf "$STAGE"; return 0; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP   # closing the terminal must still clean the temp dir (it can hold configs)
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
# ════════════════════════════════════════════════════════════
#  Container-side files. Written to the stage on the host and
#  pushed into containers with pct. Nothing here runs on the host.
#  (generated by build.sh from src/payload/)
# ════════════════════════════════════════════════════════════

write_payload() {   # write_payload <dir>
local d=$1
mkdir -p "$d"

cat > "$d/detect.sh" <<'VPNLXC_PAYLOAD_EOF'
#!/bin/bash
umask 022   # the host script runs with 077 and pct exec passes it on
export LC_ALL=C
have() { command -v "$1" >/dev/null 2>&1; }
. /etc/os-release 2>/dev/null
echo "OS_ID=${ID:-unknown}"
echo "OS_LIKE=${ID_LIKE:-}"
echo "OS_NAME=${PRETTY_NAME:-unknown}"
missing=""
for c in wg wg-quick openvpn nft curl ip ss natpmpc dnsmasq; do have "$c" || missing="$missing $c"; done
echo "MISSING=${missing# }"
if have ip; then
    lan_if=$(ip -4 route show default table main 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i+1); exit}}')
    [ -z "$lan_if" ] && lan_if=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2; exit}')
    echo "LAN_IF=$lan_if"
    if [ -n "$lan_if" ]; then
        echo "LAN_IP=$(ip -4 -o addr show dev "$lan_if" 2>/dev/null | awk '{print $4; exit}')"
        echo "LAN_NET=$(ip -4 route show dev "$lan_if" scope link 2>/dev/null | awk '{print $1; exit}')"
    fi
    if ip link add vgtest0 type wireguard 2>/dev/null; then ip link del vgtest0; echo "WG_KERNEL=1"; else echo "WG_KERNEL=0"; fi
fi
[ -c /dev/net/tun ] && echo "HAS_TUN=1"
[ -f /etc/wireguard/wg0.conf ] && echo "HAS_WGCONF=1"
[ -f /etc/openvpn/client/vpnguard.conf ] && echo "HAS_OVPNCONF=1"
if have ss; then
    ports=$(ss -Htln 2>/dev/null | awk '{print $4}' | grep -v '%' | grep -Ev '^(127\.|\[::1\])' | sed -E 's/.*:([0-9]+)$/\1/' | sort -un | tr '\n' ' ')
    echo "LISTEN_TCP=${ports% }"
fi
if have systemctl; then
    svcs=$(systemctl list-units --type=service --all --plain --no-legend --no-pager 2>/dev/null | awk '{print $1}' \
        | grep -Ei '^(qbittorrent|transmission|deluge|rtorrent|sabnzbd|nzbget|prowlarr|jackett|flaresolverr|sonarr|radarr|lidarr|readarr|bazarr|autobrr|aria2)' \
        | tr '\n' ' ')
    echo "APP_SERVICES=${svcs% }"
fi
for f in /root/.config/qBittorrent/qBittorrent.conf /home/*/.config/qBittorrent/qBittorrent.conf /var/lib/qbittorrent*/.config/qBittorrent/qBittorrent.conf; do
    [ -f "$f" ] || continue
    echo "QBIT_CONF=$f"
    echo "QBIT_WEBUI_PORT=$(sed -n 's/^WebUI\\Port=//p' "$f" | head -n 1)"
    echo "QBIT_LISTEN_PORT=$(sed -n 's/^Session\\Port=//p' "$f" | head -n 1)"
    echo "QBIT_IFACE=$(sed -n 's/^Session\\Interface=//p' "$f" | head -n 1)"
    if grep -qi '^WebUI\\HTTPS\\Enabled=true' "$f"; then echo "QBIT_HTTPS=1"; else echo "QBIT_HTTPS=0"; fi
    if grep -qi '^WebUI\\LocalHostAuth=false' "$f"; then echo "QBIT_LOCALAUTH=0"; else echo "QBIT_LOCALAUTH=1"; fi
    break
done
have iptables  && echo "LEGACY_RULES=$(iptables -S 2>/dev/null | grep -c '^-A')"
have ip6tables && echo "LEGACY6_RULES=$(ip6tables -S 2>/dev/null | grep -c '^-A')"
[ -f /etc/vpnguard/qbit.env ] && echo "HAS_QBIT_CRED=1"
[ -f /etc/vpnguard/slots/backup.conf ] && echo "HAS_BACKUP=1"
if [ -f /etc/vpnguard/vpnguard.env ]; then
    echo "HAS_SETUP=1"
    sed -n 's/^\([A-Z][A-Z0-9_]*=\)/CUR_\1/p' /etc/vpnguard/vpnguard.env
fi
VPNLXC_PAYLOAD_EOF

cat > "$d/vpnguard-dns" <<'VPNLXC_PAYLOAD_EOF'
#!/bin/bash
# vpnguard-dns <ip>...  Called when a tunnel comes up (WireGuard PostUp,
# OpenVPN route-up). Tunnel role: rewrites resolv.conf. Gateway role:
# points dnsmasq at the VPN's resolvers. Always exits 0.
ENV=/etc/vpnguard/vpnguard.env
cfg() { sed -n "s/^$1=//p" "$ENV" 2>/dev/null | head -n 1; }
ROLE=$(cfg ROLE)
OVERRIDE=$(cfg DNS_OVERRIDE)
# shellcheck disable=SC2086
[ -n "$OVERRIDE" ] && set -- $OVERRIDE
[ $# -gt 0 ] || exit 0
printf '%s\n' "$@" > /run/vpnguard-dns
if [ "$ROLE" = gateway ]; then
    { for d in "$@"; do echo "server=$d"; done; } > /etc/vpnguard-upstream.conf
    chmod 644 /etc/vpnguard-upstream.conf   # dnsmasq reads it after dropping root
    systemctl --no-block reload-or-restart dnsmasq >/dev/null 2>&1
else
    search=$(awk '$1 == "search" {$1 = ""; sub(/^ /, ""); print; exit}' /etc/resolv.conf 2>/dev/null)
    {
        echo "# --- BEGIN PVE ---"
        [ -n "$search" ] && echo "search $search"
        for d in "$@"; do echo "nameserver $d"; done
        echo "# --- END PVE ---"
    } > /etc/resolv.conf.vpnguard
    [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
    mv -f /etc/resolv.conf.vpnguard /etc/resolv.conf
    chmod 644 /etc/resolv.conf
fi
exit 0
VPNLXC_PAYLOAD_EOF

cat > "$d/vpnguard-ovpn-up" <<'VPNLXC_PAYLOAD_EOF'
#!/bin/bash
# OpenVPN route-up hook: use the DNS servers and gateway the server pushed.
dns=""
for v in $(compgen -v foreign_option_); do
    o=${!v}
    case $o in "dhcp-option DNS "*) dns="$dns ${o#dhcp-option DNS }" ;; esac
done
[ -n "${route_vpn_gateway:-}" ] && echo "$route_vpn_gateway" > /run/vpnguard-gw
# shellcheck disable=SC2086
/usr/local/sbin/vpnguard-dns $dns
exit 0
VPNLXC_PAYLOAD_EOF

cat > "$d/vpnguard-switch" <<'VPNLXC_PAYLOAD_EOF'
#!/bin/bash
# vpnguard-switch primary|backup: change which VPN config is active.
set -u
slot=${1:-}
case $slot in primary|backup) ;; *) echo "usage: vpnguard-switch primary|backup" >&2; exit 2 ;; esac
cfg() { sed -n "s/^$1=//p" /etc/vpnguard/vpnguard.env 2>/dev/null | head -n 1; }
PROTO=$(cfg PROTO); VPN_IF=$(cfg VPN_IF); UNIT=$(cfg TUNNEL_UNIT)
src=/etc/vpnguard/slots/$slot.conf
[ -f "$src" ] || { echo "there is no $slot config" >&2; exit 1; }
if [ "$PROTO" = openvpn ]; then
    install -d -m 700 /etc/openvpn/client
    install -m 600 "$src" /etc/openvpn/client/vpnguard.conf
else
    install -d -m 700 /etc/wireguard
    install -m 600 "$src" "/etc/wireguard/${VPN_IF:-wg0}.conf"
fi
echo "$slot" > /etc/vpnguard/active-slot
rm -f /run/vpnguard-pf-port
if timeout 75 systemctl restart "$UNIT"; then echo "now using the $slot config"
else echo "the $slot config did not come up: journalctl -u $UNIT" >&2; exit 1; fi
VPNLXC_PAYLOAD_EOF

cat > "$d/vpnguard-qbit-port" <<'VPNLXC_PAYLOAD_EOF'
#!/bin/bash
# vpnguard-qbit-port <port>: set qBittorrent's listening port through its WebUI API.
set -u
port=${1:-}
[[ $port =~ ^[0-9]+$ ]] || { echo "usage: vpnguard-qbit-port <port>" >&2; exit 2; }
CRED=/etc/vpnguard/qbit.env
val() { sed -n "s/^$1=//p" "$CRED" 2>/dev/null | head -n 1; }
URL=$(val QBIT_URL); URL=${URL:-http://127.0.0.1:8080}
QUSER=$(val QBIT_USER); QPASS=$(val QBIT_PASS)
jar=$(mktemp) || exit 1
trap 'rm -f "$jar"' EXIT
opts=(-s -k -m 10 -c "$jar" -b "$jar")
if [ -n "$QUSER" ]; then
    r=$(curl "${opts[@]}" --data-urlencode "username=$QUSER" --data-urlencode "password=$QPASS" "$URL/api/v2/auth/login")
    [ "$r" = "Ok." ] || { echo "qBittorrent login failed (${r:-no answer})" >&2; exit 1; }
fi
code=$(curl "${opts[@]}" -o /dev/null -w '%{http_code}' \
    --data-urlencode "json={\"listen_port\":$port,\"upnp\":false,\"random_port\":false}" \
    "$URL/api/v2/app/setPreferences")
[ "$code" = 200 ] || { echo "qBittorrent refused the new port (HTTP $code)" >&2; exit 1; }
echo "qBittorrent now listens on port $port"
VPNLXC_PAYLOAD_EOF

cat > "$d/vpnguard-natpmp" <<'VPNLXC_PAYLOAD_EOF'
#!/bin/bash
# vpnguard-natpmp: keeps a NAT-PMP port mapping alive (Proton VPN style),
# opens it in the firewall and tells qBittorrent when it changes.
set -u
cfg() { sed -n "s/^$1=//p" /etc/vpnguard/vpnguard.env 2>/dev/null | head -n 1; }
STATE=/run/vpnguard-pf-port
last=""; synced=""
rm -f "$STATE"
while true; do
    GW=$(cfg PF_GATEWAY)
    [ -z "$GW" ] && GW=$(cat /run/vpnguard-gw 2>/dev/null)
    GW=${GW:-10.2.0.1}
    if udp=$(natpmpc -a 1 0 udp 60 -g "$GW" 2>&1) && tcp=$(natpmpc -a 1 0 tcp 60 -g "$GW" 2>&1); then
        port=$(sed -nE 's/.*Mapped public port ([0-9]+).*/\1/p' <<<"$udp" | head -n 1)
        tport=$(sed -nE 's/.*Mapped public port ([0-9]+).*/\1/p' <<<"$tcp" | head -n 1)
        if [ -n "$port" ]; then
            [ -n "$tport" ] && [ "$tport" != "$port" ] && echo "note: TCP got port $tport, UDP got $port; using $port"
            nft add element inet vpnguard pf_ports "{ $port }" 2>/dev/null
            if [ "$port" != "$last" ]; then
                [ -n "$last" ] && nft delete element inet vpnguard pf_ports "{ $last }" 2>/dev/null
                echo "$port" > "$STATE"
                echo "forwarded port is now $port"
                last=$port
            fi
            if [ "$synced" != "$port" ] && [ -f /etc/vpnguard/qbit.env ]; then
                /usr/local/sbin/vpnguard-qbit-port "$port" && synced=$port
            fi
        else
            echo "unexpected NAT-PMP answer: $udp" >&2
        fi
    else
        echo "NAT-PMP request to $GW failed (tunnel down, or not a port forwarding server?)" >&2
        sleep 10
        continue
    fi
    sleep 45
done
VPNLXC_PAYLOAD_EOF

cat > "$d/vpnguard-natpmp.service" <<'VPNLXC_PAYLOAD_EOF'
[Unit]
Description=VPN port forwarding keepalive (NAT-PMP, vpn-lxc.sh)
BindsTo=vpnguard-tunnel.target
After=vpnguard-tunnel.target
PartOf=vpnguard-tunnel.target

[Service]
ExecStart=/usr/local/sbin/vpnguard-natpmp
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
VPNLXC_PAYLOAD_EOF

cat > "$d/vpnguard-openvpn.service" <<'VPNLXC_PAYLOAD_EOF'
[Unit]
Description=OpenVPN tunnel (vpn-lxc.sh)
Wants=network-online.target
After=network-online.target nftables.service
Requires=nftables.service
Wants=vpnguard-tunnel.target

[Service]
Type=notify
WorkingDirectory=/etc/openvpn/client
ExecStart=/usr/sbin/openvpn --suppress-timestamps --config /etc/openvpn/client/vpnguard.conf
Restart=on-failure
RestartSec=5
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
VPNLXC_PAYLOAD_EOF

cat > "$d/nftables.conf" <<'VPNLXC_PAYLOAD_EOF'
#!/usr/sbin/nft -f
# Managed by vpn-lxc.sh. The VPN kill switch lives in /etc/vpnguard/vpnguard.nft.
# There's no "flush ruleset" on purpose: reloading must not wipe the tunnel's own tables.
include "/etc/vpnguard/vpnguard.nft"
VPNLXC_PAYLOAD_EOF

cat > "$d/dropin-nftables.conf" <<'VPNLXC_PAYLOAD_EOF'
# vpn-lxc.sh: stopping nftables must never remove the kill switch.
[Service]
ExecStop=
VPNLXC_PAYLOAD_EOF

cat > "$d/apply.sh" <<'VPNLXC_PAYLOAD_EOF'
#!/bin/bash
# Runs inside the container, started by vpn-lxc.sh on the Proxmox host.
# Prints "STEP/WARN/FAIL/RESULT text" lines that the host draws as a checklist.
umask 022   # the host script runs with 077 and pct exec passes it on
set -uo pipefail
S=/root/.vpnguard-stage
cfg()  { sed -n "s/^$1=//p" "$S/vpnguard.env" "$S/apply.env" 2>/dev/null | head -n 1; }
step() { printf 'STEP %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; exit 1; }

ROLE=$(cfg ROLE); PROTO=$(cfg PROTO); VPN_IF=$(cfg VPN_IF); UNIT=$(cfg TUNNEL_UNIT)
APPS=$(cfg APPS); PF_MODE=$(cfg PF_MODE); PF_PORT=$(cfg PF_PORT)
DNS_PRIMARY=$(cfg DNS_PRIMARY); RETIRE=$(cfg RETIRE_LEGACY)
QBIT_SYNC=$(cfg QBIT_SYNC); KEEP_CRED=$(cfg KEEP_QBIT_CRED); VPNNET_IF=$(cfg VPNNET_IF)
FW_ONLY=$(cfg FW_ONLY)   # 1 = only reload the firewall / port forwarding, leave the tunnel running
BK=/etc/vpnguard/backup/$(date +%Y%m%d-%H%M%S)

nft -c -f "$S/vpnguard.nft" || fail "the generated firewall failed nft's check, nothing was changed"

# backups
install -d -m 700 /etc/vpnguard /etc/vpnguard/backup "$BK"
for f in /etc/wireguard/wg0.conf /etc/openvpn/client/vpnguard.conf /etc/nftables.conf /etc/resolv.conf \
         /etc/vpnguard/vpnguard.env /etc/vpnguard/vpnguard.nft /etc/dnsmasq.d/vpnguard.conf \
         /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
    [ -e "$f" ] && cp -aL "$f" "$BK/"
done
command -v iptables-save  >/dev/null 2>&1 && iptables-save  > "$BK/iptables.save"  2>/dev/null
command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > "$BK/ip6tables.save" 2>/dev/null
step "backed up the current setup"

# files
install -m 600 "$S/vpnguard.env" /etc/vpnguard/vpnguard.env
install -m 600 "$S/vpnguard.nft" /etc/vpnguard/vpnguard.nft
install -m 755 "$S/nftables.conf" /etc/nftables.conf
install -d -m 755 /etc/dhcp/dhclient-enter-hooks.d
install -m 644 "$S/dhclient-vpnguard" /etc/dhcp/dhclient-enter-hooks.d/vpnguard
install -d -m 755 /etc/systemd/system/nftables.service.d
install -m 644 "$S/dropin-nftables.conf" /etc/systemd/system/nftables.service.d/vpnguard.conf
for f in vpn-status vpnguard-dns vpnguard-switch vpnguard-ovpn-up vpnguard-qbit-port vpnguard-natpmp; do
    install -m 755 "$S/$f" "/usr/local/sbin/$f"
done
if [ "$FW_ONLY" != 1 ]; then
    rm -rf /etc/vpnguard/slots
    install -d -m 700 /etc/vpnguard/slots
    for f in "$S"/slot-*; do
        [ -e "$f" ] || continue
        install -m 600 "$f" "/etc/vpnguard/slots/${f##*/slot-}"
    done
fi

# one target that means "the tunnel is up", whatever the protocol
cat > /etc/systemd/system/vpnguard-tunnel.target <<EOF
[Unit]
Description=VPN tunnel is up (vpn-lxc.sh)
BindsTo=$UNIT
PartOf=$UNIT
After=$UNIT
Wants=$APPS$([ "$PF_MODE" = natpmp ] && echo " vpnguard-natpmp.service")
EOF
if [ "$PROTO" = openvpn ]; then
    install -m 644 "$S/vpnguard-openvpn.service" /etc/systemd/system/vpnguard-openvpn.service
    if systemctl is-enabled --quiet wg-quick@wg0 2>/dev/null || systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        systemctl disable --now wg-quick@wg0 >/dev/null 2>&1
        step "switched from WireGuard to OpenVPN"
    fi
    rm -rf /etc/systemd/system/wg-quick@wg0.service.d
else
    install -d -m 755 "/etc/systemd/system/wg-quick@$VPN_IF.service.d"
    printf '# vpn-lxc.sh: the firewall is always up before the tunnel.\n[Unit]\nRequires=nftables.service\nAfter=nftables.service\nWants=vpnguard-tunnel.target\n' \
        > "/etc/systemd/system/wg-quick@$VPN_IF.service.d/vpnguard.conf"
    if [ -e /etc/systemd/system/vpnguard-openvpn.service ]; then
        systemctl disable --now vpnguard-openvpn >/dev/null 2>&1
        rm -f /etc/systemd/system/vpnguard-openvpn.service /etc/openvpn/client/vpnguard.conf
        step "switched from OpenVPN to WireGuard"
    fi
fi

# apps: only while the tunnel is up (tunnel role)
for dd in /etc/systemd/system/*.service.d/vpnguard-app.conf; do
    [ -e "$dd" ] || continue
    u=$(basename "$(dirname "$dd")" .d)
    case " $APPS " in *" $u "*) ;; *) rm -f "$dd"; rmdir "$(dirname "$dd")" 2>/dev/null; step "untied $u from the VPN" ;; esac
done
for a in $APPS; do
    install -d -m 755 "/etc/systemd/system/$a.d"
    printf '# vpn-lxc.sh: only run while the VPN tunnel is up.\n[Unit]\nBindsTo=vpnguard-tunnel.target\nAfter=vpnguard-tunnel.target\nPartOf=vpnguard-tunnel.target\n' \
        > "/etc/systemd/system/$a.d/vpnguard-app.conf"
done

if [ -f "$S/qbit.env" ]; then install -m 600 "$S/qbit.env" /etc/vpnguard/qbit.env
elif [ "$KEEP_CRED" != 1 ]; then rm -f /etc/vpnguard/qbit.env; fi

if [ "$PF_MODE" = natpmp ]; then
    install -m 644 "$S/vpnguard-natpmp.service" /etc/systemd/system/vpnguard-natpmp.service
elif [ -e /etc/systemd/system/vpnguard-natpmp.service ]; then
    systemctl disable --now vpnguard-natpmp >/dev/null 2>&1
    rm -f /etc/systemd/system/vpnguard-natpmp.service /run/vpnguard-pf-port
    step "NAT-PMP port forwarding turned off"
fi

if [ "$ROLE" = gateway ]; then
    printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.disable_ipv6 = 1\n' > /etc/sysctl.d/99-vpnguard.conf
    sysctl -q -p /etc/sysctl.d/99-vpnguard.conf >/dev/null 2>&1 || sysctl -q -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] || fail "could not turn on IP forwarding"
    install -d -m 755 /etc/dnsmasq.d
    install -m 644 "$S/dnsmasq.conf" /etc/dnsmasq.d/vpnguard.conf
    [ -f /etc/vpnguard-upstream.conf ] || : > /etc/vpnguard-upstream.conf
    chmod 644 /etc/vpnguard-upstream.conf
    step "routing for the VPN network ($VPNNET_IF) is on"
fi
systemctl daemon-reload

# firewall first: from here on nothing leaves except through the tunnel
systemctl enable nftables >/dev/null 2>&1
if [ "$FW_ONLY" = 1 ]; then
    # restarting the service would restart the tunnel unit that requires it: swap the rules in place instead (one atomic step)
    nft -f /etc/nftables.conf || fail "the firewall did not load, the previous rules are still active"
else
    systemctl restart nftables || fail "the firewall did not load: journalctl -u nftables"
fi
nft list table inet vpnguard >/dev/null 2>&1 || fail "the firewall table is missing after loading"
step "kill switch firewall active (default-deny)"

if [ "$RETIRE" = 1 ] && [ "$FW_ONLY" != 1 ]; then
    for t in iptables ip6tables; do
        command -v "$t" >/dev/null 2>&1 || continue
        "$t" -F; "$t" -X
        for c in INPUT FORWARD OUTPUT; do "$t" -P "$c" ACCEPT; done
    done
    for f in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do [ -f "$f" ] && mv "$f" "$f.vpnguard-disabled"; done
    step "old iptables rules retired"
fi

if [ "$FW_ONLY" != 1 ]; then
# swap the tunnel
for a in $APPS; do systemctl stop "$a" 2>/dev/null; done
systemctl stop vpnguard-natpmp 2>/dev/null
systemctl stop "$UNIT" 2>/dev/null
ip link del "$VPN_IF" 2>/dev/null
if [ "$PROTO" = openvpn ]; then
    install -d -m 700 /etc/openvpn/client
    install -m 600 /etc/vpnguard/slots/primary.conf /etc/openvpn/client/vpnguard.conf
else
    install -d -m 700 /etc/wireguard
    install -m 600 /etc/vpnguard/slots/primary.conf "/etc/wireguard/$VPN_IF.conf"
fi
echo primary > /etc/vpnguard/active-slot

if [ "$ROLE" = gateway ]; then
    printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf.vpnguard && mv -f /etc/resolv.conf.vpnguard /etc/resolv.conf
    # shellcheck disable=SC2086
    [ -n "$DNS_PRIMARY" ] && /usr/local/sbin/vpnguard-dns $DNS_PRIMARY
    systemctl enable dnsmasq >/dev/null 2>&1
    systemctl restart dnsmasq || fail "dnsmasq did not start: journalctl -u dnsmasq"
    step "DNS and DHCP for the VPN network running"
elif [ -n "$DNS_PRIMARY" ]; then
    # shellcheck disable=SC2086
    /usr/local/sbin/vpnguard-dns $DNS_PRIMARY
fi

systemctl enable "$UNIT" >/dev/null 2>&1
if ! timeout 75 systemctl start "$UNIT"; then
    fail "the tunnel did not come up: journalctl -u $UNIT"
fi
up=0
for _ in $(seq 1 25); do
    timeout 4 getent hosts example.com >/dev/null 2>&1 && dns_ok=1 || dns_ok=0
    if [ "$PROTO" = wireguard ]; then
        t=$(wg show "$VPN_IF" latest-handshakes 2>/dev/null | awk 'NR == 1 {print $2}')
        [ "${t:-0}" -gt 0 ] 2>/dev/null && [ "$dns_ok" = 1 ] && { up=1; break; }
    else
        ip link show "$VPN_IF" >/dev/null 2>&1 && [ "$dns_ok" = 1 ] && { up=1; break; }
    fi
    sleep 1
done
if [ "$up" = 1 ]; then step "tunnel up, DNS answers through it"
elif ! systemctl is-active --quiet "$UNIT"; then
    fail "the tunnel service is not running: journalctl -u $UNIT"
else warn "tunnel started, but no traffic through it yet"; fi
systemctl start vpnguard-tunnel.target 2>/dev/null

for a in $APPS; do
    if systemctl start "$a"; then step "started ${a%.service}"
    else warn "${a%.service} did not start: journalctl -u $a"; fi
done
fi   # FW_ONLY

case $PF_MODE in
    static)
        step "port $PF_PORT forwarded"
        if [ "$QBIT_SYNC" = 1 ]; then
            ok=0
            for _ in $(seq 1 10); do
                /usr/local/sbin/vpnguard-qbit-port "$PF_PORT" >/dev/null 2>&1 && { ok=1; break; }
                sleep 2
            done
            if [ "$ok" = 1 ]; then step "qBittorrent now listens on $PF_PORT"
            else warn "could not set qBittorrent's port (check the WebUI login)"; fi
        fi
        ;;
    natpmp)
        systemctl enable vpnguard-natpmp >/dev/null 2>&1
        systemctl restart vpnguard-natpmp
        port=""
        for _ in $(seq 1 25); do port=$(cat /run/vpnguard-pf-port 2>/dev/null); [ -n "$port" ] && break; sleep 1; done
        if [ -n "$port" ]; then step "forwarded port from the VPN: $port"; echo "RESULT PF_PORT=$port"
        else warn "no forwarded port yet: journalctl -u vpnguard-natpmp"; fi
        ;;
esac

echo "RESULT DNS=$(tr '\n' ' ' < /run/vpnguard-dns 2>/dev/null)"
echo "RESULT BACKUP=$BK"
rm -rf "$S"
VPNLXC_PAYLOAD_EOF

cat > "$d/remove.sh" <<'VPNLXC_PAYLOAD_EOF'
#!/bin/bash
# remove.sh <restore_legacy 0|1> <stop_tunnel 0|1>
umask 022   # the host script runs with 077 and pct exec passes it on
set -uo pipefail
step() { printf 'STEP %s\n' "$*"; }
RESTORE_LEGACY=${1:-0}; STOP_TUNNEL=${2:-0}
cfg() { sed -n "s/^$1=//p" /etc/vpnguard/vpnguard.env 2>/dev/null | head -n 1; }
UNIT=$(cfg TUNNEL_UNIT); UNIT=${UNIT:-wg-quick@wg0.service}
BK=/etc/vpnguard/backup/$(date +%Y%m%d-%H%M%S)-removed
install -d -m 700 "$BK"
cp -a /etc/nftables.conf /etc/vpnguard/vpnguard.env /etc/vpnguard/vpnguard.nft "$BK/" 2>/dev/null
first=""
for d in /etc/vpnguard/backup/*/; do
    [ -d "$d" ] || continue
    case $d in *-removed/) continue ;; esac
    first=${d%/}; break
done
systemctl disable --now vpnguard-natpmp >/dev/null 2>&1
rm -f /etc/systemd/system/vpnguard-natpmp.service /run/vpnguard-pf-port
for dd in /etc/systemd/system/*.service.d/vpnguard-app.conf /etc/systemd/system/*.service.d/vpnguard.conf; do
    [ -e "$dd" ] || continue
    rm -f "$dd"; rmdir "$(dirname "$dd")" 2>/dev/null
done
if [ "$STOP_TUNNEL" = 1 ]; then
    systemctl disable --now "$UNIT" >/dev/null 2>&1
    systemctl disable --now dnsmasq >/dev/null 2>&1
    step "VPN tunnel stopped and disabled"
    # the rendered config holds the private key: put back whatever was there before us, or remove it
    for f in /etc/wireguard/wg0.conf /etc/openvpn/client/vpnguard.conf; do
        if [ -n "$first" ] && [ -f "$first/${f##*/}" ]; then cp -a "$first/${f##*/}" "$f"; else rm -f "$f"; fi
    done
    step "VPN config files removed (your own are back if you had any)"
fi
rm -f /etc/systemd/system/vpnguard-tunnel.target
[ "$STOP_TUNNEL" = 1 ] && rm -f /etc/systemd/system/vpnguard-openvpn.service
if [ -n "$first" ] && [ -f "$first/nftables.conf" ]; then
    cp -a "$first/nftables.conf" /etc/nftables.conf
else
    printf '#!/usr/sbin/nft -f\n' > /etc/nftables.conf
fi
systemctl daemon-reload
if [ -n "$first" ] && [ -s "$first/resolv.conf" ]; then
    cp -aL "$first/resolv.conf" /etc/resolv.conf.vpnguard && mv -f /etc/resolv.conf.vpnguard /etc/resolv.conf
    step "DNS settings put back"
fi
if [ "$RESTORE_LEGACY" = 1 ] && [ -n "$first" ] && [ -s "$first/iptables.save" ]; then
    iptables-restore < "$first/iptables.save" && step "restored your old iptables rules"
    for f in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
        [ -f "$f.vpnguard-disabled" ] && mv "$f.vpnguard-disabled" "$f"
    done
fi
nft delete table inet vpnguard 2>/dev/null && step "kill switch firewall removed"
rm -f /etc/dhcp/dhclient-enter-hooks.d/vpnguard /etc/vpnguard-upstream.conf
rm -f /etc/vpnguard/vpnguard.env /etc/vpnguard/vpnguard.nft /etc/vpnguard/qbit.env /etc/vpnguard/active-slot \
      /usr/local/sbin/vpn-status /usr/local/sbin/vpnguard-dns /usr/local/sbin/vpnguard-switch \
      /usr/local/sbin/vpnguard-ovpn-up /usr/local/sbin/vpnguard-qbit-port /usr/local/sbin/vpnguard-natpmp \
      /etc/sysctl.d/99-vpnguard.conf /etc/dnsmasq.d/vpnguard.conf
rm -rf /etc/vpnguard/slots
step "backups kept in /etc/vpnguard/backup"
VPNLXC_PAYLOAD_EOF

cat > "$d/client.sh" <<'VPNLXC_PAYLOAD_EOF'
#!/bin/bash
# client.sh <nameserver> <qbit_conf or -> : finish moving a container behind the VPN gateway.
umask 022   # the host script runs with 077 and pct exec passes it on
set -uo pipefail
step() { printf 'STEP %s\n' "$*"; }
NS=$1; QCONF=${2:--}
{
    echo "# --- BEGIN PVE ---"
    echo "nameserver $NS"
    echo "# --- END PVE ---"
} > /etc/resolv.conf.vpnguard
[ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
mv -f /etc/resolv.conf.vpnguard /etc/resolv.conf; chmod 644 /etc/resolv.conf
step "DNS now goes to the gateway ($NS)"
if [ "$QCONF" != - ] && [ -f "$QCONF" ]; then
    units=$(systemctl list-units --type=service --all --plain --no-legend 2>/dev/null | awk '{print $1}' | grep -i '^qbittorrent' || true)
    for u in $units; do systemctl stop "$u" 2>/dev/null; done
    sed -i -e 's/^Session\\Interface=.*/Session\\Interface=/' \
           -e 's/^Session\\InterfaceName=.*/Session\\InterfaceName=/' \
           -e 's/^Session\\InterfaceAddress=.*/Session\\InterfaceAddress=/' "$QCONF"
    for u in $units; do systemctl start "$u" 2>/dev/null; done
    step "qBittorrent no longer bound to a VPN interface (the gateway handles it)"
fi
VPNLXC_PAYLOAD_EOF

cat > "$d/vpn-status" <<'VPNLXC_PAYLOAD_EOF'
#!/bin/bash
# vpn-status: tunnel, leak and kill switch check. Installed by vpn-lxc.sh.
#   vpn-status            full screen
#   vpn-status --brief    KEY=value summary for the dashboard
#   vpn-status --health   quick health check for the watchdog (no outside lookups)
[ -n "$BASH_VERSION" ] || exec bash "$0" "$@"

ENV=/etc/vpnguard/vpnguard.env
cfg() { sed -n "s/^$1=//p" "$ENV" 2>/dev/null | head -n 1; }
ROLE=$(cfg ROLE);         ROLE=${ROLE:-tunnel}
PROTO=$(cfg PROTO);       PROTO=${PROTO:-wireguard}
VPN_IF=$(cfg VPN_IF);     VPN_IF=${VPN_IF:-wg0}
UNIT=$(cfg TUNNEL_UNIT);  UNIT=${UNIT:-wg-quick@wg0.service}
LAN_IF=$(cfg LAN_IF);     LAN_IF=${LAN_IF:-eth0}
VPN_NET=$(cfg VPN_NET)
PROVIDER=$(cfg PROVIDER); PROVIDER=${PROVIDER:-vpn}
HOME_IP=$(cfg HOME_IP)
APPS=$(cfg APPS)
PF_MODE=$(cfg PF_MODE);   PF_MODE=${PF_MODE:-none}
PF_PORT=$(cfg PF_PORT);   PF_TARGET=$(cfg PF_TARGET)
PUBLISH=$(cfg PUBLISH);   LAN_NET=$(cfg LAN_NET); LAN_TCP=$(cfg LAN_TCP_PORTS)
LAN_MODE=$(cfg LAN_MODE); LAN_MODE=${LAN_MODE:-ports}
ACTIVE=$(cat /etc/vpnguard/active-slot 2>/dev/null); ACTIVE=${ACTIVE:-primary}
HAS_BACKUP=0; [ -f /etc/vpnguard/slots/backup.conf ] && HAS_BACKUP=1
MAX_AGE=180

# A VPN hop can drop the odd packet; one lost handshake must not read as "no traffic".
lookup() {   # lookup URL [curl options] : prints the body, tries twice
    local url=$1 out i; shift
    for i in 1 2; do
        out=$(curl -4 -s -m 6 "$@" "$url" 2>/dev/null)
        if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    done
    return 1
}
jget() {
    if command -v jq >/dev/null 2>&1; then jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
    else grep -o "\"$1\" *: *\"[^\"]*\"" | head -n 1 | cut -d'"' -f4; fi
}
hs_age() {
    local t
    t=$(wg show "$VPN_IF" latest-handshakes 2>/dev/null | awk 'NR == 1 {print $2}')
    if [ -n "$t" ] && [ "$t" -gt 0 ] 2>/dev/null; then echo $(( $(date +%s) - t )); else echo -1; fi
}
tunnel_up() { systemctl is-active --quiet "$UNIT" && ip link show "$VPN_IF" >/dev/null 2>&1; }
pf_now() { if [ "$PF_MODE" = natpmp ]; then cat /run/vpnguard-pf-port 2>/dev/null; else echo "$PF_PORT"; fi; }
bytes() { cat "/sys/class/net/$VPN_IF/statistics/$1" 2>/dev/null || echo 0; }
route_dev() { ip route get "$1" 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i+1); exit}}'; }

if [ "${1:-}" = --health ]; then
    reason=""
    if ! systemctl is-active --quiet "$UNIT"; then reason="tunnel service not running"
    elif ! ip link show "$VPN_IF" >/dev/null 2>&1; then reason="$VPN_IF is missing"
    else
        timeout 8 getent hosts example.com >/dev/null 2>&1; dns_ok=$?
        if [ "$PROTO" = wireguard ]; then
            a=$(hs_age)
            if [ "$a" -lt 0 ] || [ "$a" -gt "$MAX_AGE" ]; then reason="no fresh handshake"; fi
        fi
        [ -z "$reason" ] && [ "$dns_ok" -ne 0 ] && reason="DNS through the tunnel fails"
    fi
    if [ -z "$reason" ]; then echo "HEALTH=ok"; else echo "HEALTH=fail"; fi
    down=""
    for a in $APPS; do systemctl is-active --quiet "$a" || down="$down $a"; done
    echo "REASON=$reason"; echo "ACTIVE=$ACTIVE"; echo "HAS_BACKUP=$HAS_BACKUP"; echo "PF_PORT=$(pf_now)"
    echo "APPS_DOWN=${down# }"; echo "UNIT=$UNIT"
    exit 0
fi

if [ "${1:-}" = --brief ]; then
    up=down; tunnel_up && up=up
    a=-1; [ "$PROTO" = wireguard ] && a=$(hs_age)
    json=""; [ "$up" = up ] && json=$(lookup https://ipinfo.io/json)
    echo "ROLE=$ROLE"; echo "PROVIDER=$PROVIDER"; echo "PROTO=$PROTO"; echo "TUNNEL=$up"; echo "HS_AGE=$a"
    echo "ACTIVE=$ACTIVE"; echo "HAS_BACKUP=$HAS_BACKUP"; echo "PF_MODE=$PF_MODE"; echo "PF_PORT=$(pf_now)"
    echo "EXIT_IP=$(printf '%s' "$json" | jget ip)"; echo "CITY=$(printf '%s' "$json" | jget city)"
    echo "COUNTRY=$(printf '%s' "$json" | jget country)"; echo "RX=$(bytes rx_bytes)"; echo "TX=$(bytes tx_bytes)"
    exit 0
fi

# ── full screen ──
if { [ -t 1 ] || [ "${FORCE_COLOR:-0}" = 1 ]; } && [ -z "${NO_COLOR:-}" ]; then
    FANCY=1; RESET=$'\e[0m'; BOLD=$'\e[1m'
    GREEN=$'\e[38;5;84m'; RED=$'\e[38;5;203m'; YELLOW=$'\e[38;5;221m'
    CYAN=$'\e[38;5;81m'; GREY=$'\e[38;5;244m'; VIOLET=$'\e[38;5;141m'
else
    FANCY=0; RESET=""; BOLD=""; GREEN=""; RED=""; YELLOW=""; CYAN=""; GREY=""; VIOLET=""
fi
PASS=0; WARN=0; FAIL=0
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

hr()   { printf '%*s' "$1" '' | sed 's/ /━/g'; }
dots() { local pad=$((24 - ${#1})); [ "$pad" -lt 2 ] && pad=2; printf '%*s' "$pad" '' | tr ' ' '.'; }
bar() {
    local v=$1 m=$2 w=${3:-10} f i s=""
    [ "$m" -gt 0 ] || m=1
    f=$(( v * w / m )); [ "$f" -gt "$w" ] && f=$w; [ "$f" -lt 0 ] && f=0
    for ((i = 0; i < w; i++)); do if [ "$i" -lt "$f" ]; then s+="▰"; else s+="▱"; fi; done
    printf '%s' "$s"
}
section() { printf '\n  %s▌%s %s%s%s\n' "$VIOLET" "$RESET" "$BOLD" "$1" "$RESET"; }
row() {
    local state=$1 label=$2 detail=$3 sym col
    case $state in
        0) sym="✔"; col=$GREEN;  PASS=$((PASS + 1)) ;;
        3) sym="▲"; col=$YELLOW; WARN=$((WARN + 1)) ;;
        *) sym="✘"; col=$RED;    FAIL=$((FAIL + 1)); detail=${4:-$3} ;;
    esac
    printf '    %s%s%s %s %s%s%s %s%s%s\n' "$col" "$sym" "$RESET" "$label" "$GREY" "$(dots "$label")" "$RESET" "$col" "$detail" "$RESET"
}
info() { printf '    %s◆%s %s %s%s%s %s%s%s\n' "$CYAN" "$RESET" "$1" "$GREY" "$(dots "$1")" "$RESET" "$CYAN" "$2" "$RESET"; }
spin() {
    local label=$1 pid=$2 i=0 frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    [ "$FANCY" -eq 1 ] || return 0
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r    %s%s%s %s%s%s' "$CYAN" "${frames[i % 10]}" "$RESET" "$GREY" "$label" "$RESET"
        i=$((i + 1)); sleep 0.08
    done
    printf '\r\e[K'
}
fetch() {   # fetch LABEL FILE curl-args...   (RETRY=1: try again once if empty)
    local label=$1 out=$2; shift 2
    { curl -s -m 8 "$@" >"$out" 2>/dev/null
      if [ "${RETRY:-0}" = 1 ] && [ ! -s "$out" ]; then curl -s -m 8 "$@" >"$out" 2>/dev/null; fi; } &
    local pid=$!
    spin "$label" "$pid"
    wait "$pid"
}
human() { awk -v b="$1" 'BEGIN { split("B KiB MiB GiB TiB", u); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf "%.2f %s", b, u[i] }'; }

banner() {
    local colors=(51 45 39 33 27 63) i=0 line
    echo
    while IFS= read -r line; do
        if [ "$FANCY" -eq 1 ]; then printf '   \e[38;5;%sm%s\e[0m\n' "${colors[i]}" "$line"; else printf '   %s\n' "$line"; fi
        i=$((i + 1))
    done <<'EOF'
██╗   ██╗██████╗ ███╗   ██╗
██║   ██║██╔══██╗████╗  ██║
██║   ██║██████╔╝██╔██╗ ██║
╚██╗ ██╔╝██╔═══╝ ██║╚██╗██║
 ╚████╔╝ ██║     ██║ ╚████║
  ╚═══╝  ╚═╝     ╚═╝  ╚═══╝
EOF
    printf '   %sV P N · L X C   ·   %s · %s · %s%s\n' "$GREY" "$PROVIDER" "$PROTO" "$ROLE" "$RESET"
    printf '   %s%s  ·  %s%s\n' "$GREY" "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S')" "$RESET"
}

[ -f "$ENV" ] || echo "note: $ENV not found, using defaults (was vpn-lxc.sh run on this container?)"
banner
RETRY=1 fetch "probing the exit node..." "$TMP/exit" -4 https://ipinfo.io/json
[ "$PROVIDER" = mullvad ] && RETRY=1 fetch "asking Mullvad..." "$TMP/mullvad" -4 https://am.i.mullvad.net/json
fetch "testing the kill switch..." "$TMP/leak" -4 -m 5 --interface "$LAN_IF" https://ipinfo.io/ip

section "TUNNEL"
systemctl is-active --quiet "$UNIT"
row $? "Service" "${UNIT%.service} running" "${UNIT%.service} not running"
ip link show "$VPN_IF" &>/dev/null
row $? "Interface $VPN_IF" "up" "missing"
if [ "$PROTO" = wireguard ]; then
    EP=$(wg show "$VPN_IF" endpoints 2>/dev/null | awk 'NR == 1 {print $2}')
    info "Endpoint" "${EP:-unknown}"
    AGE=$(hs_age)
    if [ "$AGE" -ge 0 ] && [ "$AGE" -le "$MAX_AGE" ]; then row 0 "Handshake" "$(bar $((MAX_AGE - AGE)) "$MAX_AGE") ${AGE}s ago"
    elif [ "$AGE" -ge 0 ]; then row 1 "Handshake" "" "$(bar 0 "$MAX_AGE") stale: ${AGE}s ago"
    else row 1 "Handshake" "" "never completed"; fi
else
    GW=$(cat /run/vpnguard-gw 2>/dev/null)
    info "VPN gateway" "${GW:-unknown}"
fi
if [ "$HAS_BACKUP" = 1 ]; then
    if [ "$ACTIVE" = primary ]; then info "Config" "primary (backup standing by)"
    else row 3 "Config" "running on the BACKUP config"; fi
fi

section "EXIT"
EXIT_JSON=$(cat "$TMP/exit" 2>/dev/null)
EXIT_IP=$(printf '%s' "$EXIT_JSON" | jget ip)
if [ -z "$EXIT_IP" ]; then row 1 "Exit IP" "" "no answer through the tunnel"
elif [ -n "$HOME_IP" ] && [ "$EXIT_IP" = "$HOME_IP" ]; then row 1 "Exit IP" "" "$EXIT_IP is your HOME IP"
elif [ -z "$HOME_IP" ]; then row 3 "Exit IP" "$EXIT_IP (home IP unknown, can't compare)"
else row 0 "Exit IP" "$EXIT_IP · not your home IP"; fi
if [ "$PROVIDER" = mullvad ]; then
    grep -Eq '"mullvad_exit_ip" *: *true' "$TMP/mullvad" 2>/dev/null
    row $? "Mullvad confirms" "this is a Mullvad exit" "Mullvad says this is NOT its exit"
fi
CITY=$(printf '%s' "$EXIT_JSON" | jget city); COUNTRY=$(printf '%s' "$EXIT_JSON" | jget country)
ORG=$(printf '%s' "$EXIT_JSON" | jget org)
[ -n "$CITY$COUNTRY" ] && info "Location" "${CITY:+$CITY, }$COUNTRY"
[ -n "$ORG" ] && info "Network" "$ORG"

section "LEAKS"
V6DEV=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i+1); exit}}')
if [ -z "$V6DEV" ]; then row 0 "IPv6" "no IPv6 route"
elif curl -6 -s -m 5 https://api6.ipify.org >/dev/null 2>&1; then row 1 "IPv6" "" "LEAK: IPv6 reaches the internet via $V6DEV"
else row 0 "IPv6" "blocked by the firewall"; fi
if [ "$ROLE" = gateway ]; then
    systemctl is-active --quiet dnsmasq
    row $? "DNS for the VPN net" "dnsmasq running" "dnsmasq not running"
    for ns in $(sed -n 's/^server=//p' /etc/vpnguard-upstream.conf 2>/dev/null); do
        dev=$(route_dev "$ns")
        if [ "$dev" = "$VPN_IF" ]; then row 0 "Upstream DNS" "$ns via $VPN_IF"
        else row 1 "Upstream DNS" "" "$ns goes via ${dev:-?}, outside the tunnel"; fi
    done
else
    for ns in $(awk '$1 == "nameserver" {print $2}' /etc/resolv.conf 2>/dev/null); do
        dev=$(route_dev "$ns")
        if [ "$dev" = "$VPN_IF" ]; then row 0 "DNS resolver" "$ns via $VPN_IF"
        else row 1 "DNS resolver" "" "$ns goes via ${dev:-?}, outside the tunnel"; fi
    done
fi
timeout 8 getent hosts example.com >/dev/null 2>&1
row $? "DNS resolution" "working" "lookups failing"

section "KILL SWITCH"
if nft list chain inet vpnguard output 2>/dev/null | grep -q 'policy drop' \
   && nft list chain inet vpnguard input 2>/dev/null | grep -q 'policy drop' \
   && nft list chain inet vpnguard forward 2>/dev/null | grep -q 'policy drop'; then
    row 0 "Firewall" "default-deny in, out and forward"
else
    row 1 "Firewall" "" "vpnguard firewall not loaded"
fi
LEAK=$(cat "$TMP/leak" 2>/dev/null)
if [ -z "$LEAK" ]; then row 0 "Active test" "traffic forced out of $LAN_IF is blocked"
else row 1 "Active test" "" "LEAK: reachable outside the tunnel as $LEAK"; fi
LEGACY=$(iptables -S 2>/dev/null | grep -c '^-A')
[ "${LEGACY:-0}" -gt 0 ] && row 3 "Old iptables rules" "$LEGACY rules still loaded"
if [ "$ROLE" = gateway ]; then
    [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = 1 ]
    row $? "Routing" "VPN net $VPN_NET can only leave via $VPN_IF" "IP forwarding is off"
else
    if [ "$LAN_MODE" = open ]; then info "Home network" "$LAN_NET · full access both ways"
    elif [ -n "$LAN_NET" ]; then info "Home network" "$LAN_NET → tcp ${LAN_TCP:-none}"; fi
fi

if [ "$ROLE" = gateway ] && [ -n "$PUBLISH" ]; then
    section "PUBLISHED TO YOUR LAN"
    LANIP=$(ip -4 -o addr show dev "$LAN_IF" 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}')
    for p in $PUBLISH; do
        ext=${p%%:*}; rest=${p#*:}
        info "${LANIP:-gateway}:$ext" "→ $rest"
    done
fi

section "BOOT ORDER"
[ "$(systemctl is-enabled nftables 2>/dev/null)" = enabled ]
row $? "Firewall at boot" "loads before the network" "nftables.service not enabled"
[ "$(systemctl is-enabled "$UNIT" 2>/dev/null)" = enabled ]
row $? "Tunnel at boot" "${UNIT%.service} enabled" "${UNIT%.service} not enabled"
if [ "$ROLE" = gateway ]; then
    [ "$(systemctl is-enabled dnsmasq 2>/dev/null)" = enabled ]
    row $? "DNS/DHCP at boot" "dnsmasq enabled" "dnsmasq not enabled"
fi
for a in $APPS; do
    state=$(systemctl is-active "$a" 2>/dev/null)
    if systemctl show -p BindsTo --value "$a" 2>/dev/null | grep -q vpnguard-tunnel.target; then
        row 0 "${a%.service}" "only runs with the VPN · $state"
    else
        row 1 "${a%.service}" "" "not tied to the VPN · $state"
    fi
done

if [ "$PF_MODE" != none ]; then
    section "PORT FORWARDING"
    if [ "$PF_MODE" = natpmp ]; then
        systemctl is-active --quiet vpnguard-natpmp
        row $? "NAT-PMP keepalive" "running" "vpnguard-natpmp not running"
    fi
    port=$(pf_now)
    if [ -z "$port" ]; then
        row 1 "Forwarded port" "" "none yet"
    else
        nft list set inet vpnguard pf_ports 2>/dev/null | grep -qw "$port"
        row $? "Forwarded port" "$port open on $VPN_IF only" "$port is not open in the firewall"
        if [ "$ROLE" = gateway ]; then
            info "Sent on to" "${PF_TARGET:-?}:$port"
        else
            if [ -n "$(ss -Hln "( sport = :$port )" 2>/dev/null)" ]; then row 0 "Listening" "an app listens on $port"
            else row 3 "Listening" "nothing listens on $port yet (fine until you run a torrent client)"; fi
        fi
    fi
fi

section "TRAFFIC"
info "Through the tunnel" "▼ $(human "$(bytes rx_bytes)")   ▲ $(human "$(bytes tx_bytes)")"

TOTAL=$((PASS + WARN + FAIL))
echo
if [ "$FAIL" -eq 0 ]; then C=$GREEN; MSG="✔  ALL SYSTEMS GO  ·  SAFE TO USE"
else C=$RED; MSG="✘  CHECKS FAILED  ·  DO NOT USE YET"; fi
printf '  %s┏%s%s\n' "$C" "$(hr 44)" "$RESET"
printf '  %s┃%s  %s%s%s\n' "$C" "$RESET" "${BOLD}${C}" "$MSG" "$RESET"
printf '  %s┗%s%s\n' "$C" "$(hr 44)" "$RESET"
printf '  %s%s  %s/%s passed · %s warning(s) · %s failed · %ss%s\n\n' \
    "$GREY" "$(bar "$PASS" "$TOTAL")" "$PASS" "$TOTAL" "$WARN" "$FAIL" "$SECONDS" "$RESET"
[ "$FAIL" -eq 0 ]
VPNLXC_PAYLOAD_EOF

cat > "$d/dhclient-vpnguard" <<'VPNLXC_PAYLOAD_EOF'
# vpn-lxc.sh: DNS comes from the VPN tunnel, never from the DHCP server on the home network.
make_resolv_conf() { :; }
VPNLXC_PAYLOAD_EOF
}
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
        print "# DNS is handled by vpn-lxc.sh: only ever through the tunnel"
        if (dns != "") print "PostUp = /usr/local/sbin/vpnguard-dns " dns
        next
    }
    /^# DNS is handled by vpn-lxc.sh/ { next }
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
    /^# --- vpn-lxc.sh ---/ { ours = 1 }
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
    /^# --- vpn-lxc.sh ---/ { exit }
    /^[ \t]*<auth-user-pass>/   { skip = 1; next }
    /^[ \t]*<\/auth-user-pass>/ { skip = 0; next }
    skip { next }
    /^[ \t]*<\/[A-Za-z-]+>/ { inblk = 0; print; next }
    /^[ \t]*<[A-Za-z-]+>/   { inblk = 1; print; next }
    inblk { print; next }
    $1 ~ /^(remote|up|down|route-up|ipchange|route-pre-down|script-security|auth-user-pass|auth-nocache|dev|dev-type|persist-tun|resolv-retry|redirect-gateway|remote-random-hostname)$/ { next }
    { print }
    END {
        print "# --- vpn-lxc.sh ---"
        print "# Below is managed by vpn-lxc.sh. Servers are pinned to IPs because DNS only works inside the tunnel."
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
# ════════════════════════════════════════════════════════════
#  Wizard pages shared by both modes
#  A "target" is a key into V/D: 1, 2, 3... (per-container) or gw.
# ════════════════════════════════════════════════════════════
NT=0   # number of per-container targets

is_express() { [ "${V[mode]:-express}" = express ]; }

# Express fills in everything it can detect, so only the VPN config is asked for.
express_fill() {   # express_fill TARGET   (per-container targets; the gateway has its own)
    local t=$1
    V[$t.lan_mode]=open; V[$t.lan_tcp]=""; V[$t.lan_out]=""
    V[$t.apps_all]=${V[$t.apps_all]:-${D[$t.CUR_APPS]:-${D[$t.APP_SERVICES]:-}}}
    # stopping apps with the tunnel is optional; if this container was set up before without them, keep it that way
    if [ -z "${V[$t.tie]:-}" ]; then
        if [ "${D[$t.HAS_SETUP]:-}" = 1 ] && [ -z "${D[$t.CUR_APPS]:-}" ]; then V[$t.tie]=n; else V[$t.tie]=y; fi
    fi
    if [ "${V[$t.tie]}" = y ]; then V[$t.apps]=${V[$t.apps_all]}; else V[$t.apps]=""; fi
}

ctx() {
    local t=$1
    if [ "$t" = gw ]; then
        CONTEXT="$(chip 'gateway' "$PK") ${B}${V[gw.name]:-vpn-gateway}${R} ${GR}· CT ${V[gw.ct]:-new}${R}"
    else
        CONTEXT="$(chip "CT ${V[$t.ct]}" "$CY") ${B}${V[$t.name]}${R} ${GR}· $t of $NT${R}"
    fi
}

# detect_raw runs inside run_task (a subshell), so it only writes a file;
# detect_task then loads that file into D in this shell.
detect_raw() {   # detect_raw TARGET CTID
    local t=$1 ct=$2
    cpush "$ct" "$STAGE/payload/detect.sh" /tmp/vpnguard-detect.sh 700 || return 1
    cexec "$ct" bash /tmp/vpnguard-detect.sh > "$STAGE/detect-$t.out" 2>/dev/null
    cexec "$ct" rm -f /tmp/vpnguard-detect.sh >/dev/null 2>&1
    grep -q '^OS_ID=' "$STAGE/detect-$t.out"
}
detect_task() {   # detect_task "label" TARGET CTID
    local k
    for k in "${!D[@]}"; do [[ $k == "$2."* ]] && unset "D[$k]"; done
    run_task "$1" detect_raw "$2" "$3" || return 1
    read_kv_into D "$2." < "$STAGE/detect-$2.out"
    [ -n "${D[$2.OS_ID]:-}" ]
}

pg_provider() {
    local t=$1 p def
    if is_express; then V[$t.provider]=${V[$t.provider]:-${D[$t.CUR_PROVIDER]:-}}; return 3; fi   # guessed from the config
    ctx "$t"
    page "VPN provider" "Which VPN service should ${V[$t.name]:-this} use? Containers can use different providers."
    def=${V[$t.provider]:-${D[$t.CUR_PROVIDER]:-proton}}
    pick p "Provider" "$def" \
        "mullvad|Mullvad|WireGuard · no port forwarding" \
        "proton|Proton VPN|WireGuard or OpenVPN · port forwarding via NAT-PMP" \
        "airvpn|AirVPN|WireGuard or OpenVPN · a port you reserve" \
        "other|Other|any WireGuard or OpenVPN provider" || return
    V[$t.provider]=$p
}

# where an existing config lives inside the target container
existing_conf_path() {
    local t=$1 s=$2
    if [ "$s" = backup ]; then [ "${D[$t.HAS_BACKUP]:-}" = 1 ] && echo /etc/vpnguard/slots/backup.conf; return; fi
    if [ "${D[$t.CUR_ROLE]:-}" != "" ]; then echo /etc/vpnguard/slots/primary.conf
    elif [ "${D[$t.HAS_WGCONF]:-}" = 1 ]; then echo /etc/wireguard/wg0.conf
    elif [ "${D[$t.HAS_OVPNCONF]:-}" = 1 ]; then echo /etc/openvpn/client/vpnguard.conf
    fi
}

pg_config() {   # pg_config TARGET [primary|backup]
    local t=$1 s=${2:-primary} want src f lname ct
    ct=${V[$t.ct]:-}
    if [ "$s" = backup ] && is_express && [ "${D[$t.HAS_BACKUP]:-}" != 1 ] && [ -z "${V[$t.backup.kind]:-}" ]; then return 3; fi
    while true; do
        ctx "$t"
        if [ "$s" = backup ]; then
            page "Backup config (failover)" "If the main server stops answering, the watchdog switches to this config by itself and tells you. Use a second server of the same type (${V[$t.primary.kind]:-WireGuard or OpenVPN}), from the same or another provider."
            local defb=n
            [ -n "${V[$t.backup.kind]:-}" ] || [ "${D[$t.HAS_BACKUP]:-}" = 1 ] && defb=y
            yn want "Add a backup config?" "$defb" || return
            if [ "$want" = n ]; then
                for k in kind file endpoints dns label src user pass fp lib; do unset "V[$t.backup.$k]"; done
                return 0
            fi
        else
            page "VPN config" "$(provider_hint "${V[$t.provider]}" "${V[$t.primary.kind]:-}")"
        fi

        local -a opts=()
        local have=""
        [ -n "$ct" ] && have=$(existing_conf_path "$t" "$s")
        [ -n "$have" ] && opts+=("keep|Keep the current one|already in the container")
        local nlib; nlib=$(lib_names | wc -l)
        [ "$nlib" -gt 0 ] && opts+=("lib|From your library|$nlib saved config$([ "$nlib" -gt 1 ] && echo s)")
        opts+=("paste|Paste it|copy the file's text and paste it here")
        opts+=("file|A file on this host|e.g. /root/proton.conf")
        local defsrc=${V[$t.$s.src]:-}
        if [ -z "$defsrc" ]; then
            if [ -n "$have" ]; then defsrc=keep; elif [ "$nlib" -gt 0 ]; then defsrc=lib; else defsrc=paste; fi
        fi
        pick src "Where's the config?" "$defsrc" "${opts[@]}" || return

        f="$STAGE/t$t.$s.src"
        local user="" pass="" hostfile=""
        case $src in
            keep)
                pct pull "$ct" "$have" "$f.raw" >/dev/null 2>&1 || { bad "could not read $have from CT $ct"; pause; continue; }
                tr -d '\r' < "$f.raw" > "$f"; rm -f "$f.raw"
                local authp="/etc/vpnguard/slots/$s.auth"
                if pct pull "$ct" "$authp" "$f.auth" >/dev/null 2>&1; then
                    user=$(sed -n 1p "$f.auth"); pass=$(sed -n 2p "$f.auth"); rm -f "$f.auth"
                fi ;;
            lib)
                echo
                local -a li=()
                local n who busy=""
                while IFS= read -r n; do
                    if who=$(fp_conflict "$t" "$s" "$(lib_fp "$n")" "${V[$t.ct]:-}"); then busy="$busy\n$n → $who"; continue; fi
                    li+=("$n|$n|$(lib_meta "$n" KIND) · $(provider_label "$(lib_meta "$n" PROVIDER)") · $(lib_meta "$n" ENDPOINTS | awk '{print $1}')")
                done < <(lib_names)
                if [ -n "$busy" ]; then
                    note "not offered, already in use (one connection per config):"
                    while IFS= read -r who; do [ -n "$who" ] && printf '        %s%s%s\n' "$GR" "$who" "$R"; done <<<"$(printf '%b' "$busy")"
                    echo
                fi
                if [ ${#li[@]} -eq 0 ]; then bad "every saved config is in use: paste a new one or add one in Settings"; pause; continue; fi
                pick lname "Which one?" "${V[$t.$s.lib]:-}" "${li[@]}" || { [ $? = 2 ] && return 2; continue; }
                tr -d '\r' < "$LIB/$lname.conf" > "$f"
                if [ -f "$LIB/$lname.auth" ]; then user=$(sed -n 1p "$LIB/$lname.auth"); pass=$(sed -n 2p "$LIB/$lname.auth"); fi
                V[$t.$s.lib]=$lname ;;
            paste)
                echo
                paste_block "$f.raw" || { bad "nothing was pasted"; pause; continue; }
                tr -d '\r' < "$f.raw" > "$f"; rm -f "$f.raw" ;;
            file)
                echo
                field hostfile "Path to the file" "${V[$t.$s.hostfile]:-}" v_path || { [ $? = 2 ] && return 2; continue; }
                tr -d '\r' < "$hostfile" > "$f" ;;
        esac

        if ! analyze_config "$t" "$s" "$f"; then
            bad "$VERR"; pause; continue
        fi
        V[$t.$s.fp]=$(cfg_fp_of "$t" "$s")
        local why
        if why=$(fp_conflict "$t" "$s" "${V[$t.$s.fp]}" "${V[$t.ct]:-}"); then
            bad "That config is already used by $why. Every connection needs its own config (a WireGuard key holds one session)."
            unset "V[$t.$s.fp]"; pause; continue
        fi
        if [ -z "${V[$t.provider]:-}" ]; then
            V[$t.provider]=""
            [ "$src" = lib ] && V[$t.provider]=$(lib_meta "$lname" PROVIDER)
            [ -n "${V[$t.provider]}" ] || V[$t.provider]=$(guess_provider "$t" "$s")
        fi
        if [ "$s" = backup ] && [ "${V[$t.backup.kind]}" != "${V[$t.primary.kind]}" ]; then
            bad "the backup has to be ${V[$t.primary.kind]} too (the main config is)"; pause; continue
        fi
        if [ "${V[$t.$s.kind]}" = wireguard ] && [ -z "${V[$t.$s.dns]}" ]; then
            local dns
            echo
            note "the config has no DNS line; DNS must go through the tunnel, so pick the VPN's resolver"
            field dns "DNS server inside the tunnel" "$(provider_dns "${V[$t.provider]}")" v_ip4 || { [ $? = 2 ] && return 2; continue; }
            V[$t.$s.dns]=$dns
        fi
        echo
        config_card "$t" "$s"
        echo

        if [ "${V[$t.$s.auth]}" = 1 ]; then
            if [ -z "$user" ]; then
                note "This OpenVPN config needs a login."
                field user "OpenVPN username" "${V[$t.$s.user]:-}" v_req || { [ $? = 2 ] && return 2; continue; }
                secret pass "OpenVPN password"
            else
                ok "login for $user is already stored"
            fi
        fi
        V[$t.$s.user]=$user; V[$t.$s.pass]=$pass; V[$t.$s.src]=$src; V[$t.$s.hostfile]=$hostfile

        if [ "$src" = paste ] || [ "$src" = file ]; then
            local save
            yn save "Save it to your config library (root-only, on this host)?" y || { [ $? = 2 ] && return 2; continue; }
            if [ "$save" = y ]; then
                local defname
                defname="${V[$t.provider]}-$(echo "${V[$t.$s.endpoints]}" | awk '{print $1}' | cut -d: -f1 | tr . -)"
                field lname "Name in the library" "$defname" v_name || { [ $? = 2 ] && return 2; continue; }
                lib_save "$lname" "$f" "${V[$t.$s.kind]}" "${V[$t.provider]}" "${V[$t.$s.endpoints]}" "$user" "$pass"
                ok "saved as $lname"
                V[$t.$s.lib]=$lname
            fi
        fi
        local use
        yn use "Use this config?" y || { [ $? = 2 ] && return 2; continue; }
        [ "$use" = y ] && return 0
    done
}

pg_backup() { pg_config "$1" backup; }

# Port forwarding. For a gateway, also which client gets the port.
pg_pf() {
    local t=$1
    if [ "$t" != gw ] && is_express; then express_fill "$t"; fi
    local prov=${V[$t.provider]} kind=${V[$t.primary.kind]} mode use
    ctx "$t"
    if [ "$prov" = mullvad ]; then V[$t.pf_mode]=none; return 3; fi
    page "Port forwarding" "Lets peers on the internet connect to your torrent client through the VPN, so you show as connectable. Prowlarr and similar apps don't need it."
    mode=${V[$t.pf_mode]:-${D[$t.CUR_PF_MODE]:-}}
    case $prov in
        proton)
            yn use "Use Proton's port forwarding? (paid plan, P2P server, NAT-PMP on)" "$([ "${mode:-natpmp}" = none ] && echo n || echo y)" || return
            if [ "$use" = y ]; then
                mode=natpmp
                if [ "$kind" = openvpn ]; then
                    note "for OpenVPN, +pmp gets added to your username automatically (that's how Proton turns it on)"
                    V[$t.pf_gw]=""
                else
                    V[$t.pf_gw]=10.2.0.1
                fi
            else mode=none; fi ;;
        airvpn)
            note "reserve a port first: Client Area → Ports"
            yn use "Use a forwarded port from AirVPN?" "$([ "${mode:-static}" = none ] && echo n || echo y)" || return
            if [ "$use" = y ]; then mode=static; else mode=none; fi ;;
        *)
            pick mode "Port forwarding" "${mode:-none}" \
                "none|None|peers can't connect in" \
                "static|A fixed port|the provider gave you a port number" \
                "natpmp|NAT-PMP|the port is requested and kept alive automatically" || return
            if [ "$mode" = natpmp ]; then
                local gw
                field gw "NAT-PMP gateway inside the tunnel (- = the one the server pushes)" "${V[$t.pf_gw]:-$([ "$kind" = openvpn ] && echo - || echo 10.2.0.1)}" v_any || return
                [ -n "$gw" ] && ! is_ip4 "$gw" && { bad "not an IPv4 address"; pause; return 1; }
                V[$t.pf_gw]=$gw
            fi ;;
    esac
    V[$t.pf_mode]=$mode
    if [ "$mode" = static ]; then
        local port
        field port "Forwarded port" "${V[$t.pf_port]:-${D[$t.CUR_PF_PORT]:-${D[$t.QBIT_LISTEN_PORT]:-}}}" v_port || return
        V[$t.pf_port]=$port
    fi
    [ "$mode" = none ] && return 0

    # which container gets the port, and is it qBittorrent?
    local qt="$t" qip="127.0.0.1"
    if [ "$t" = gw ]; then
        local -a items=() c
        for c in ${V[gw.clients]}; do items+=("$c|CT $c ${V[c$c.name]}|${V[c$c.ip]}"); done
        [ ${#items[@]} -gt 0 ] || { warn "no containers behind the gateway yet, so the port has nowhere to go"; V[$t.pf_mode]=none; pause; return 0; }
        local tgt
        echo
        pick tgt "Which container gets the forwarded port?" "${V[gw.pf_target]:-$(echo "${V[gw.clients]}" | awk '{print $1}')}" "${items[@]}" || return
        V[gw.pf_target]=$tgt
        qt="c$tgt"; qip=${V[c$tgt.ip]}
    fi
    V[$t.qbit_sync]=0
    if [ -n "${D[$qt.QBIT_CONF]:-}" ]; then
        local sync
        echo
        yn sync "Let the script set qBittorrent's listening port for you?" y || return
        if [ "$sync" = y ]; then
            V[$t.qbit_sync]=1
            local scheme=http url
            [ "${D[$qt.QBIT_HTTPS]:-0}" = 1 ] && scheme=https
            field url "qBittorrent WebUI address" "${V[$t.qbit_url]:-$scheme://$qip:${D[$qt.QBIT_WEBUI_PORT]:-8080}}" v_url || return
            V[$t.qbit_url]=$url
            if [ "$t" != gw ] && [ "${D[$qt.QBIT_LOCALAUTH]:-1}" = 0 ]; then
                note "qBittorrent skips the login for localhost, no password needed"
                V[$t.qbit_user]=""
            elif [ "$t" != gw ] && [ "${D[$t.HAS_QBIT_CRED]:-}" = 1 ] && [ -z "${V[$t.qbit_user]:-}" ]; then
                local keep
                yn keep "Keep the qBittorrent login that's already stored?" y || return
                [ "$keep" = y ] && V[$t.qbit_keep]=1
            fi
            if [ "${V[$t.qbit_keep]:-0}" != 1 ] && { [ "$t" = gw ] || [ "${D[$qt.QBIT_LOCALAUTH]:-1}" != 0 ]; }; then
                local u pw
                field u "qBittorrent WebUI username" "${V[$t.qbit_user]:-admin}" v_req || return
                secret pw "qBittorrent WebUI password"
                V[$t.qbit_user]=$u; V[$t.qbit_pass]=$pw
                note "stored root-only, used only to change the listening port"
            fi
        fi
    elif [ "$mode" = natpmp ]; then
        echo
        warn "the port changes over time and this isn't qBittorrent, so you'd update it by hand"
        pause
    fi
    return 0
}

# ════════════════════════════════════════════════════════════
#  Per-container mode
# ════════════════════════════════════════════════════════════
tm_select() {
    FLOW="per-container setup"; CONTEXT=""
    page "Pick containers" "Each one gets its own VPN tunnel and kill switch. Pick as many as you like; shared questions are asked once."
    local -a items=()
    local id name st role mark on
    for id in $(ct_ids); do
        role=$(reg_get "$id" ROLE)
        [ "$role" = gateway ] || [ "$role" = client ] && continue
        name=$(ct_name "$id"); st=$(ct_status "$id")
        mark="$st"
        [ "$role" = tunnel ] && mark="$st · VPN: $(provider_label "$(reg_get "$id" PROVIDER)")"
        on=0; case " ${V[sel]:-} " in *" $id "*) on=1 ;; esac
        items+=("$id|$id $name|$mark|$on")
    done
    [ ${#items[@]} -gt 0 ] || { warn "no containers found"; pause; return 1; }
    local chosen mode
    while true; do
        checklist chosen "Containers" "${items[@]}" || return
        if [ -z "$chosen" ]; then bad "pick at least one"; continue; fi
        echo
        pick mode "How much do you want to decide?" "${V[mode]:-express}" \
            "express|Express (recommended)|only asks for the VPN config; full access to your home network" \
            "custom|Custom|choose ports, apps and a backup config yourself" || { local rc=$?; [ "$rc" = 2 ] && return 2; continue; }
        break
    done
    V[sel]=$chosen; V[mode]=$mode
    local count; count=$(wc -w <<<"$chosen")
    if is_express; then PAGE_TOTAL=$((2 + 2 * count + 1)); else PAGE_TOTAL=$((3 + 6 * count + 1)); fi
}

tm_detect() {
    FLOW="per-container setup"; CONTEXT=""
    [ "$DIR" = back ] && [ "$NT" -gt 0 ] && return 3
    page "Looking inside" "Checking each container: OS, network, apps, and what's already set up. Nothing is changed."
    local id t=0 st
    NT=0
    for id in ${V[sel]}; do
        t=$((t + 1))
        st=$(ct_status "$id")
        if [ "$st" != running ]; then
            run_task "starting CT $id" pct start "$id" || { bad "CT $id won't start, skipping it"; continue; }
            sleep 3
        fi
        V[$t.ct]=$id; V[$t.name]=$(ct_name "$id")
        if detect_task "CT $id ${V[$t.name]}" "$t" "$id"; then
            case " ${D[$t.OS_ID]} ${D[$t.OS_LIKE]} " in
                *" debian "*|*" ubuntu "*) ;;
                *) warn "CT $id runs ${D[$t.OS_NAME]}; only Debian/Ubuntu are supported, skipping it"; t=$((t - 1)); continue ;;
            esac
            [ -n "${D[$t.LAN_IF]}" ] || { warn "CT $id has no network, skipping it"; t=$((t - 1)); continue; }
            NT=$t
        else
            t=$((t - 1))
        fi
    done
    [ "$NT" -gt 0 ] || { bad "none of the containers can be set up"; pause; return 1; }
    echo
    local i
    for ((i = 1; i <= NT; i++)); do
        local extra=""
        [ "${D[$i.HAS_SETUP]:-}" = 1 ] && extra=" · already set up, current choices are the defaults"
        ok "CT ${V[$i.ct]} ${V[$i.name]}: ${D[$i.OS_NAME]} · ${D[$i.LAN_IF]} ${D[$i.LAN_IP]}$extra"
    done
    pause
}

tm_shared() {
    FLOW="per-container setup"; CONTEXT=""
    if is_express && [ -n "${V[lan_net]:-${D[1.CUR_LAN_NET]:-${D[1.LAN_NET]:-}}}" ]; then
        V[lan_net]=${V[lan_net]:-${D[1.CUR_LAN_NET]:-${D[1.LAN_NET]}}}; return 3
    fi
    page "Home network" "Which network is your home LAN? Containers get full access to it (you can narrow that down in Custom setup)."
    local net
    field net "Home network" "${V[lan_net]:-${D[1.CUR_LAN_NET]:-${D[1.LAN_NET]}}}" v_cidr4 || return
    V[lan_net]=$net
}

tm_lan() {
    local t=$1 sugg="" p ports out full
    if is_express; then express_fill "$t"; return 3; fi
    ctx "$t"
    page "Home network access" "Your home network is never behind the VPN: ${V[$t.name]} can reach your NAS, other containers and devices directly, and they can reach it."
    local curmode=${V[$t.lan_mode]:-${D[$t.CUR_LAN_MODE]:-open}}
    yn full "Give ${V[$t.name]} full access to ${V[lan_net]}? (recommended)" "$([ "$curmode" = open ] && echo y || echo n)" || return
    if [ "$full" = y ]; then V[$t.lan_mode]=open; V[$t.lan_tcp]=""; V[$t.lan_out]=""; return 0; fi
    V[$t.lan_mode]=ports
    echo
    note "locked-down mode: only the ports you list below"
    [ -n "${D[$t.LISTEN_TCP]}" ] && note "listening right now: tcp ${D[$t.LISTEN_TCP]}"
    [ -n "${D[$t.QBIT_WEBUI_PORT]:-}" ] && note "qBittorrent WebUI: ${D[$t.QBIT_WEBUI_PORT]}"
    echo
    if [ -n "${V[$t.lan_tcp]+x}" ]; then sugg=${V[$t.lan_tcp]}
    elif [ "${D[$t.HAS_SETUP]:-}" = 1 ]; then sugg=${D[$t.CUR_LAN_TCP_PORTS]:-}
    else
        for p in ${D[$t.LISTEN_TCP]}; do [ "$p" = "${D[$t.QBIT_LISTEN_PORT]:-}" ] || sugg="$sugg $p"; done
        sugg=${sugg# }
    fi
    field ports "TCP ports open to your home network (- for none)" "$sugg" v_ports || return
    V[$t.lan_tcp]=$ports
    echo
    note "only if this app talks to other machines, e.g. Prowlarr → Lidarr 192.168.1.23:8686"
    field out "LAN services it connects to, ip:port (- for none)" "${V[$t.lan_out]:-${D[$t.CUR_LAN_OUT]:-}}" v_lanout || return
    V[$t.lan_out]=$out
}

tm_apps() {
    local t=$1 inp a ok_all
    local -a list
    if is_express; then express_fill "$t"; return 3; fi
    ctx "$t"
    page "Apps" "These stop whenever the tunnel goes down, and only start once it's up."
    [ -n "${D[$t.APP_SERVICES]}" ] && note "found: ${D[$t.APP_SERVICES]}"
    while true; do
        field inp "Services tied to the VPN (- for none)" "${V[$t.apps]:-${D[$t.CUR_APPS]:-${D[$t.APP_SERVICES]}}}" v_any || return
        read -ra list <<<"${inp//,/ }"
        local out=""; ok_all=1
        for a in "${list[@]}"; do
            [[ $a == *.service ]] || a="$a.service"
            if ! is_unit "$a"; then bad "'$a' isn't a service name"; ok_all=0; break; fi
            if ! cexec "${V[$t.ct]}" systemctl cat "$a" >/dev/null 2>&1; then bad "$a doesn't exist in CT ${V[$t.ct]}"; ok_all=0; break; fi
            out="$out $a"
        done
        [ "$ok_all" = 1 ] && break
    done
    V[$t.apps_all]=${out# }
    if [ -n "${V[$t.apps_all]}" ]; then
        echo
        local tie
        yn tie "Stop them while the VPN is down, and start them again when it's back? (recommended)" "${V[$t.tie]:-y}" || return
        V[$t.tie]=$tie
    fi
    if [ "${V[$t.tie]:-y}" = y ]; then V[$t.apps]=${V[$t.apps_all]}; else V[$t.apps]=""; fi
    if [[ ${V[$t.apps_all]} == *qbittorrent* ]] && [ -n "${D[$t.QBIT_IFACE]:-}" ]; then
        local want=wg0; [ "${V[$t.primary.kind]}" = openvpn ] && want=tun0
        [ "${D[$t.QBIT_IFACE]}" != "$want" ] && warn "qBittorrent is bound to ${D[$t.QBIT_IFACE]}; set Options → Advanced → Network interface to $want"
    fi
    return 0
}

# review card for one per-container target
tm_card() {
    local t=$1 pf
    case ${V[$t.pf_mode]:-none} in
        none)   pf="off" ;;
        static) pf="port ${V[$t.pf_port]}$([ "${V[$t.qbit_sync]:-0}" = 1 ] && echo ' · set in qBittorrent')" ;;
        natpmp) pf="NAT-PMP$([ "${V[$t.qbit_sync]:-0}" = 1 ] && echo ' · synced to qBittorrent')" ;;
    esac
    box_top "CT ${V[$t.ct]} · ${V[$t.name]}"
    box_row "${GR}VPN${R}            $(provider_label "${V[$t.provider]}") · ${V[$t.primary.label]}"
    [ -n "${V[$t.backup.kind]:-}" ] && box_row "${GR}Backup${R}         ${V[$t.backup.label]}"
    if [ "${V[$t.lan_mode]:-open}" = open ]; then
        box_row "${GR}Home network${R}   ${V[lan_net]} · ${OK}full access both ways${R}"
    else
        box_row "${GR}From home${R}      ${V[lan_net]} → tcp ${V[$t.lan_tcp]:-none}"
        box_row "${GR}LAN out${R}        ${V[$t.lan_out]:-none}"
    fi
    if [ -n "${V[$t.apps]:-}" ]; then box_row "${GR}Tied to VPN${R}    ${V[$t.apps]} ${GR}· stop when the VPN drops${R}"
    elif [ -n "${V[$t.apps_all]:-}" ]; then box_row "${GR}Apps${R}            ${V[$t.apps_all]} ${GR}· keep running when the VPN drops${R}"
    else box_row "${GR}Tied to VPN${R}    nothing"; fi
    box_row "${GR}Port forward${R}   $pf"
    box_row "${GR}Internet${R}       only through the VPN · IPv6 blocked"
    if [[ ${V[$t.apps]:-} == *qbittorrent* ]] && [ -n "${D[$t.QBIT_IFACE]:-}" ]; then
        local want=wg0; [ "${V[$t.primary.kind]}" = openvpn ] && want=tun0
        [ "${D[$t.QBIT_IFACE]}" != "$want" ] && box_row "${WA}▲${R} qBittorrent is bound to ${D[$t.QBIT_IFACE]}: set Options → Advanced → Network interface to $want"
    fi
    [ "${D[$t.LEGACY_RULES]:-0}" -gt 0 ] && box_row "${WA}▲${R} ${D[$t.LEGACY_RULES]} old iptables rules get retired (backed up)"
    [ "${V[$t.primary.kind]}" = openvpn ] && [ "${D[$t.HAS_TUN]:-}" != 1 ] && box_row "${WA}▲${R} needs /dev/net/tun: the container restarts once"
    box_bot
}

tm_review() {
    FLOW="per-container setup"; CONTEXT=""
    local i tie ask=0
    if is_express; then
        for ((i = 1; i <= NT; i++)); do express_fill "$i"; [ -n "${V[$i.apps_all]:-}" ] && ask=1; done
    fi
    if [ "$ask" = 1 ]; then
        page "Apps" "Apps like qBittorrent can be stopped automatically whenever the VPN is down, and started again when it's back. They can't reach the internet while it's down either way; this just stops them retrying."
        for ((i = 1; i <= NT; i++)); do
            [ -n "${V[$i.apps_all]:-}" ] || continue
            yn tie "CT ${V[$i.ct]} ${V[$i.name]}: stop ${V[$i.apps_all]//.service/} while the VPN is down?" "${V[$i.tie]:-y}" || return
            V[$i.tie]=$tie
            express_fill "$i"
        done
    fi
    page "Review" "Nothing has changed yet. This is what will happen:"
    for ((i = 1; i <= NT; i++)); do tm_card "$i"; done
    echo
    local snap go
    yn snap "Take a Proxmox snapshot of each first, so you can roll back?" "${V[snap]:-y}" || return
    V[snap]=$snap
    yn go "Apply to $NT container$([ "$NT" -gt 1 ] && echo s) now?" y || return
    [ "$go" = y ] || return 1
}

tunnel_wizard() {
    new_stage
    write_payload "$STAGE/payload"
    local rc i
    while true; do
        PB=0; PAGE_TOTAL=${PAGE_TOTAL:-10}
        run_pages "tm_select" "tm_detect" "tm_shared"; rc=$?
        [ "$rc" = 0 ] || return "$rc"
        local -a pages=()
        for ((i = 1; i <= NT; i++)); do
            if is_express; then
                pages+=("pg_config $i")
                [ "${D[$i.HAS_BACKUP]:-}" = 1 ] && pages+=("pg_backup $i")
                pages+=("pg_pf $i")
            else
                pages+=("pg_provider $i" "pg_config $i" "pg_backup $i" "tm_lan $i" "tm_apps $i" "pg_pf $i")
            fi
        done
        pages+=("tm_review")
        if is_express; then PB=2; else PB=3; fi
        PAGE_TOTAL=$((PB + ${#pages[@]}))
        run_pages "${pages[@]}"; rc=$?
        case $rc in
            0) tunnel_apply; return 0 ;;
            1) DIR=back; continue ;;
            *) return 2 ;;
        esac
    done
}
# ════════════════════════════════════════════════════════════
#  Gateway mode: one VPN container + a private bridge
# ════════════════════════════════════════════════════════════

gateway_ids() { local id; for id in $(reg_ids); do [ "$(reg_get "$id" ROLE)" = gateway ] && echo "$id"; done; }
gateway_clients_of() { local id; for id in $(reg_ids); do [ "$(reg_get "$id" ROLE)" = client ] && [ "$(reg_get "$id" GATEWAY)" = "$1" ] && echo "$id"; done; }
# names the user gave to gateways (and every container hostname), so a new one can't clash
name_taken() { local id n; for id in $(reg_ids); do [ "$id" = "${V[gw.ct]:-}" ] && continue; [ "$(reg_get "$id" NAME)" = "$1" ] && return 0; done; for id in $(ct_ids); do [ "$id" = "${V[gw.ct]:-}" ] && continue; [ "$(ct_name "$id")" = "$1" ] && return 0; done; return 1; }
suggest_gw_name() { local n=1 cand=vpn-gateway; while name_taken "$cand"; do n=$((n + 1)); cand=vpn-gateway-$n; done; echo "$cand"; }
v_gwname() { VERR="that name is already used by a container or another gateway"; v_host "$1" >/dev/null || { VERR="use letters, digits and - only"; return 1; }; ! name_taken "$1" && printf '%s' "$1"; }
# a VPN network no other gateway uses (10.10.10.0/24, then 10.10.11.0/24, ...)
used_vpnnets() { local id; for id in $(gateway_ids); do [ "$id" = "${V[gw.ct]:-}" ] || reg_get "$id" VPN_NET; done; }
free_vpnnet() {
    local n net used
    used=" $(used_vpnnets | tr '\n' ' ') "
    for n in $(seq 10 99); do
        net=10.10.$n.0/24
        [[ $used == *" $net "* ]] && continue
        [ "$(net_prefix "$net")" = "$(net_prefix "${V[lan_net]:-x.x.x.0/24}")" ] && continue
        ip route show 2>/dev/null | grep -q "^10\.10\.$n\." && continue
        echo "$net"; return
    done
}
bridge_exists()   { ip link show "$1" >/dev/null 2>&1 || grep -Eq "^(auto|iface)[[:space:]]+$1([[:space:]]|$)" "$IFACES_FILE" 2>/dev/null; }
free_bridge()     { local n; for n in $(seq 1 99); do bridge_exists "vmbr$n" || { echo "vmbr$n"; return; }; done; }
net_prefix()      { echo "${1%.*/*}"; }   # 10.10.10.0/24 → 10.10.10

v_newbridge() { VERR="use a free name like vmbr1"; [[ $1 =~ ^vmbr[0-9]{1,4}$ ]] && { [ "${V[gw.mode]}" = reconfig ] || ! bridge_exists "$1"; } && printf '%s' "$1"; }
v_vpnnet() {
    VERR="use a /24 like 10.10.10.0/24 that isn't your home network"
    [[ $1 =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.0/24$ ]] || return 1
    is_ip4 "${1%/*}" || return 1
    [ "$(net_prefix "$1")" = "$(net_prefix "${V[lan_net]:-x.x.x.0/24}")" ] && return 1
    [[ " $(used_vpnnets | tr '\n' ' ') " == *" $1 "* ]] && { VERR="another gateway already uses $1"; return 1; }
    printf '%s' "$1"
}
v_newct() { VERR="that ID is taken or isn't a number"; [[ $1 =~ ^[0-9]{3,9}$ ]] && ! ct_exists "$1" && printf '%s' "$1"; }
v_gwlan() {
    v_ip4len "$1" >/dev/null || return 1
    [ "$1" = dhcp ] && { printf dhcp; return 0; }
    VERR="${1%/*} already answers on your network, pick a free address"
    ping -c 1 -W 1 "${1%/*}" >/dev/null 2>&1 && return 1
    printf '%s' "$1"
}

# a free address near the top of the home network, for the gateway
suggest_gw_ip() {
    local pre i len=${V[lan_net]#*/}
    pre=$(net_prefix "${V[lan_net]}")
    local mine; mine=" $(for g in $(gateway_ids); do reg_get "$g" LAN_ADDR; done | sed 's#/.*##' | tr '\n' ' ') "
    for i in 250 249 248 247 246 245 240 230 220 210 200; do
        [[ $mine == *" $pre.$i "* ]] && continue
        ping -c 1 -W 1 "$pre.$i" >/dev/null 2>&1 || { echo "$pre.$i/$len"; return; }
    done
    echo dhcp
}

# auto_publish CT : sets AP_OUT to "outside:inside ..." for the container's listening ports, avoiding clashes (AP_TAKEN = outside ports used)
AP_OUT=""; AP_TAKEN=" 53 67 "
auto_publish() {
    local c=$1 p out
    AP_OUT=""
    for p in ${D[c$c.LISTEN_TCP]:-}; do
        [ "$p" = "${D[c$c.QBIT_LISTEN_PORT]:-}" ] && continue
        out=$p
        while [[ $AP_TAKEN == *" $out "* ]]; do out=$((out + 10000)); [ "$out" -gt 65535 ] && out=$((out - 20000)); done
        AP_TAKEN="$AP_TAKEN$out "
        AP_OUT="$AP_OUT $out:$p"
    done
    AP_OUT=${AP_OUT# }
}

gw_diagram() {
    local gwn=${V[gw.name]:-vpn-gateway} br=${V[gw.bridge]:-vmbr1} net=${V[gw.net]:-10.10.10.0/24} lan=${V[lan_net]:-your LAN}
    printf '    %shome LAN %s%s\n' "$GR" "$lan" "$R"
    printf '    %s━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$CY" "$R"
    printf '           %s┃%s\n' "$CY" "$R"
    printf '    %s╭──────┸─────────────╮%s       %s╭─────────╮%s\n' "$PK" "$R" "$VI" "$R"
    printf '    %s│%s %s%-18s%s %s│%s%s═══════%s%s│%s  VPN    %s│%s%s═══ internet%s\n' "$PK" "$R" "$B" "$gwn" "$R" "$PK" "$R" "$OK" "$R" "$VI" "$R" "$VI" "$R" "$OK" "$R"
    printf '    %s│%s %skill switch · NAT%s  %s│%s %stunnel%s%s╰─────────╯%s\n' "$PK" "$R" "$GR" "$R" "$PK" "$R" "$GR" "$R" "$VI" "$R"
    printf '    %s╰──────┰─────────────╯%s\n' "$PK" "$R"
    printf '           %s┃%s  %s%s %s · no way out except the tunnel%s\n' "$WA" "$R" "$GR" "$br" "$net" "$R"
    printf '    %s━━━━━━━┻━━━━━━━━┳━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━%s\n' "$WA" "$R"
    printf '              %scontainer%s      %scontainer%s     %s…%s\n' "$B" "$R" "$B" "$R" "$GR" "$R"
}

gw_intro() {
    FLOW="VPN gateway"; CONTEXT=""
    local g="" gids; gids=$(gateway_ids)
    if [ -n "$gids" ]; then
        page "VPN gateways" "Each gateway is its own VPN connection with its own name, private bridge and containers. Pick one to change, or make another."
        local -a gi=(); local x
        for x in $gids; do gi+=("$x|$(reg_get "$x" NAME)|$(reg_get "$x" PROVIDER) · $(gateway_clients_of "$x" | wc -l) containers · $(reg_get "$x" BRIDGE) · $(reg_get "$x" LAN_ADDR)"); done
        gi+=("new|New gateway|another VPN connection with its own name and bridge")
        pick g "Which gateway?" "${V[pick_gw]:-new}" "${gi[@]}" || return
        [ "$g" = new ] && g=""
        V[pick_gw]=${g:-new}
    fi
    for x in name ct bridge net lanaddr; do unset "V[gw.$x]"; done
    if [ -n "$g" ]; then
        V[gw.mode]=reconfig; V[gw.ct]=$g; V[gw.name]=$(reg_get "$g" NAME); V[gw.name]=${V[gw.name]:-$(ct_name "$g")}
        V[gw.bridge]=$(reg_get "$g" BRIDGE); V[gw.net]=$(reg_get "$g" VPN_NET); V[gw.lanaddr]=$(reg_get "$g" LAN_ADDR)
        page "Gateway ${V[gw.name]}" "CT $g. You can change its VPN, which containers sit behind it, and what's published to your home network."
    else
        V[gw.mode]=create
        page "New VPN gateway" "A small container becomes a VPN router. Every container you plug into its private bridge goes through the VPN, with the kill switch outside the apps, so nothing inside them can route around it."
    fi
    [ -z "${V[lan_net]:-}" ] && V[lan_net]=$(ip -4 route show dev "$(ip -4 route show default | awk '{print $5; exit}')" scope link 2>/dev/null | awk '{print $1; exit}')
    gw_diagram
    echo
    local mode
    pick mode "How much do you want to decide?" "${V[mode]:-express}" \
        "express|Express (recommended)|only asks for the gateway's address and the VPN config" \
        "custom|Custom|choose the bridge, network, ports and storage yourself" || return
    V[mode]=$mode
    echo
    if [ "${V[gw.mode]}" = reconfig ]; then
        local newname
        field newname "Name of this gateway" "${V[gw.name]}" v_gwname || return
        V[gw.newname]=$newname
    else
        local newname
        field newname "Name for the new gateway (this is also its hostname)" "${V[gw.name]:-$(suggest_gw_name)}" v_gwname || return
        V[gw.name]=$newname
    fi
    if [ "${V[gw.mode]}" = reconfig ]; then
        if [ "$(ct_status "$g")" != running ]; then run_task "starting CT $g" pct start "$g" || { pause; return 1; }; sleep 3; fi
        detect_task "looking inside the gateway" gw "$g" || { bad "could not read the gateway's setup"; pause; return 1; }
        local c
        V[gw.clients]=""
        for c in $(reg_ids); do
            [ "$(reg_get "$c" ROLE)" = client ] && [ "$(reg_get "$c" GATEWAY)" = "$g" ] && V[gw.clients]="${V[gw.clients]} $c"
        done
        V[gw.clients]=${V[gw.clients]# }
        V[gw.old_clients]=${V[gw.clients]}
        [ -n "${D[gw.CUR_LAN_OUT]:-}" ] && V[gw.lan_out]=${D[gw.CUR_LAN_OUT]}
    fi
    local net
    if is_express && [ -n "${V[lan_net]:-}" ]; then return 0; fi
    field net "Your home network" "${V[lan_net]}" v_cidr4 || return
    V[lan_net]=$net
}

gw_bridge() {
    [ "${V[gw.mode]}" = reconfig ] && return 3
    if is_express; then
        local xbr=${V[gw.bridge]:-$(free_bridge)} xnet=${V[gw.net]:-$(free_vpnnet)}
        V[gw.bridge]=$xbr; V[gw.net]=$xnet; V[gw.ip]="$(net_prefix "$xnet").1"
        return 3
    fi
    FLOW="VPN gateway"; ctx gw
    page "Private bridge" "A new Proxmox bridge with no physical port. Containers on it can only reach the internet through the gateway's tunnel."
    local br net
    field br "Bridge name" "${V[gw.bridge]:-$(free_bridge)}" v_newbridge || return
    field net "VPN network" "${V[gw.net]:-$(free_vpnnet)}" v_vpnnet || return
    V[gw.bridge]=$br; V[gw.net]=$net; V[gw.ip]="$(net_prefix "$net").1"
    echo
    note "the gateway gets ${V[gw.ip]}, containers get .10 and up, DHCP hands out .100–.199"
    note "this host stays off the bridge, so nothing there can reach Proxmox itself"
    pause
}

gw_container() {
    [ "${V[gw.mode]}" = reconfig ] && return 3
    is_express && gw_bridge
    FLOW="VPN gateway"; ctx gw
    page "Gateway container" "A tiny Debian container (256 MB RAM, 2 GB disk) that runs the tunnel. It needs a fixed address on your home network: that's where you'll open qBittorrent, Prowlarr and so on."
    local id name lan store
    if is_express; then
        id=${V[gw.ct]:-$(pvesh get /cluster/nextid 2>/dev/null)}; name=${V[gw.name]:-$(suggest_gw_name)}
        if ! { [[ $id =~ ^[0-9]{3,9}$ ]] && ! ct_exists "$id"; }; then bad "container ID $id is not free"; pause; return 1; fi
        note "found a free address on ${V[lan_net]}; reserve it in your router's DHCP if you can"
        field lan "LAN address for the gateway (or dhcp)" "${V[gw.lanaddr]:-$(suggest_gw_ip)}" v_gwlan || return
    else
        field id "Container ID" "${V[gw.ct]:-$(pvesh get /cluster/nextid 2>/dev/null)}" v_newct || return
        name=${V[gw.name]:-$(suggest_gw_name)}
        note "pick a free address on ${V[lan_net]}; reserve it in your router's DHCP if you can"
        field lan "LAN address for the gateway (or dhcp)" "${V[gw.lanaddr]:-$(suggest_gw_ip)}" v_gwlan || return
    fi
    V[gw.ct]=$id; V[gw.name]=$name; V[gw.lanaddr]=$lan
    V[gw.lan_gw]=$(host_lan_gw)
    V[gw.lan_bridge]=$(ip -4 -o addr show scope global 2>/dev/null | awk '$2 ~ /^vmbr/ {print $2; exit}')
    echo
    local -a items=()
    local s
    while read -r s; do items+=("$s|$s|$(pvesm status --storage "$s" 2>/dev/null | awk 'NR == 2 {printf "%.0f GB free", $6 / 1048576}')"); done \
        < <(pvesm status --content rootdir 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1}')
    [ ${#items[@]} -gt 0 ] || { bad "no storage for container disks found"; pause; return 1; }
    local defs=${V[gw.storage]:-}
    [ -z "$defs" ] && { printf '%s\n' "${items[@]}" | grep -q '^local-lvm|' && defs=local-lvm || defs=${items[0]%%|*}; }
    if is_express; then store=$defs; else pick store "Storage for its disk" "$defs" "${items[@]}" || return; fi
    V[gw.storage]=$store
    V[gw.tstore]=$(pvesm status --content vztmpl 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1; exit}')
    V[gw.tstore]=${V[gw.tstore]:-local}
}

gw_clients() {
    FLOW="VPN gateway"; ctx gw
    page "Containers behind the gateway" "Ticked containers move to ${V[gw.bridge]}. Their old network card is replaced, so they get a new address; apps that talk to them (Lidarr → qBittorrent, say) need the gateway's address afterwards."
    local -a items=()
    local id name role on desc
    for id in $(ct_ids); do
        [ "$id" = "${V[gw.ct]}" ] && continue
        role=$(reg_get "$id" ROLE)
        name=$(ct_name "$id")
        on=0; case " ${V[gw.clients]:-} " in *" $id "*) on=1 ;; esac
        case $role in
            client) [ "$(reg_get "$id" GATEWAY)" = "${V[gw.ct]}" ] || continue
                    desc="behind this gateway · $(reg_get "$id" IP)" ;;
            tunnel) desc="has its own VPN now → gets converted" ;;
            gateway) continue ;;
            *) desc=$(ct_status "$id") ;;
        esac
        items+=("$id|$id $name|$desc|$on")
    done
    [ ${#items[@]} -gt 0 ] || { warn "no other containers yet: create them later and re-run this"; pause; V[gw.clients]=""; return 0; }
    local chosen
    checklist chosen "Containers" "${items[@]}" || return
    V[gw.clients]=$chosen
}

next_client_ip() {
    local pre i ip used=" ${V[gw.ip]:-} " c
    pre=$(net_prefix "${V[gw.net]}")
    for c in $(reg_ids); do used="$used $(reg_get "$c" IP)"; done
    for c in ${V[gw.clients]}; do used="$used ${V[c$c.ip]:-}"; done
    for i in $(seq 10 99); do
        ip="$pre.$i"
        case " $used " in *" $ip "*) ;; *) echo "$ip"; return ;; esac
    done
}

gw_client_detect() {
    FLOW="VPN gateway"; ctx gw
    [ -z "${V[gw.clients]}" ] && return 3
    [ "$DIR" = back ] && return 3
    page "Looking inside" "Checking the containers that go behind the gateway. Nothing is changed yet."
    local c ok_list=""
    for c in ${V[gw.clients]}; do
        V[c$c.name]=$(ct_name "$c")
        if [ "$(ct_status "$c")" != running ]; then run_task "starting CT $c" pct start "$c" || continue; sleep 3; fi
        if detect_task "CT $c ${V[c$c.name]}" "c$c" "$c"; then ok_list="$ok_list $c"
        else warn "skipping CT $c"; fi
    done
    V[gw.clients]=${ok_list# }
    echo
    for c in ${V[gw.clients]}; do
        [ -z "${V[c$c.ip]:-}" ] && V[c$c.ip]=$(reg_get "$c" IP)
        [ -z "${V[c$c.ip]:-}" ] && V[c$c.ip]=$(next_client_ip)
        local nics
        nics=$(pct config "$c" | grep -E '^net[0-9]+:' | wc -l)
        V[c$c.netkey]=$(pct config "$c" | grep -E '^net[0-9]+:' | grep -m 1 "name=${D[c$c.LAN_IF]:-eth0}," | cut -d: -f1)
        V[c$c.netkey]=${V[c$c.netkey]:-net0}
        local extra=""
        [ "$nics" -gt 1 ] && extra=" · $((nics - 1)) extra network card(s) get removed (they'd bypass the gateway)"
        ok "CT $c ${V[c$c.name]} → ${V[c$c.ip]}$extra"
    done
    pause
}

gw_publish() {
    FLOW="VPN gateway"; ctx gw
    [ -z "${V[gw.clients]}" ] && return 3
    local gwaddr=${V[gw.lanaddr]%/*}
    [ "$gwaddr" = dhcp ] && gwaddr="the gateway"
    local c pub sugg e ok_all
    AP_TAKEN=" 53 67 "
    # suggestions: what was published before, else every port the container listens on
    for c in ${V[gw.clients]}; do
        if [ -n "${V[c$c.publish]+x}" ]; then sugg=${V[c$c.publish]}
        else
            sugg=$(reg_get "$c" PUBLISH)
            if [ -z "$sugg" ]; then auto_publish "$c"; sugg=$AP_OUT; fi
        fi
        V[c$c.sugg]=$sugg
        for e in $sugg; do AP_TAKEN="$AP_TAKEN${e%%:*} "; done
    done
    V[gw.lan_mode]=${V[gw.lan_mode]:-open}
    if is_express; then
        for c in ${V[gw.clients]}; do V[c$c.publish]=${V[c$c.sugg]}; done
        V[gw.lan_mode]=open; V[gw.lan_out]=""
        return 3
    fi
    page "Published to your home network" "Your home network reaches each container through the gateway's address ($gwaddr:port). Pick the ports to publish; use outside:inside (2222:22) when two containers use the same port."
    local taken=" 53 67 "
    for c in ${V[gw.clients]}; do
        sugg=${V[c$c.sugg]}
        [ -n "${D[c$c.LISTEN_TCP]:-}" ] && note "CT $c ${V[c$c.name]} listens on: tcp ${D[c$c.LISTEN_TCP]}"
        while true; do
            field pub "CT $c ${V[c$c.name]}: ports to publish (- for none)" "$sugg" v_publish || return
            ok_all=1
            for e in $pub; do
                case "$taken" in *" ${e%%:*} "*) bad "outside port ${e%%:*} is already used, try $((${e%%:*} + 10000)):${e#*:}"; ok_all=0 ;; esac
            done
            [ "$ok_all" = 1 ] && break
        done
        for e in $pub; do taken="$taken${e%%:*} "; done
        V[c$c.publish]=$pub
    done
    echo
    local full
    yn full "Let the containers reach your whole home network? (recommended)" "$([ "${V[gw.lan_mode]}" = open ] && echo y || echo n)" || return
    if [ "$full" = y ]; then V[gw.lan_mode]=open; V[gw.lan_out]=""; return 0; fi
    V[gw.lan_mode]=ports
    note "locked-down mode: only the services you list can be reached"
    note "e.g. Prowlarr → Lidarr 192.168.1.23:8686"
    local out
    field out "LAN services they may connect to, ip:port (- for none)" "${V[gw.lan_out]:-}" v_lanout || return
    V[gw.lan_out]=$out
}

gw_review() {
    FLOW="VPN gateway"; CONTEXT=""
    is_express && gw_publish
    page "Review" "Nothing has changed yet. This is what will happen:"
    local gwaddr=${V[gw.lanaddr]} pf c
    case ${V[gw.pf_mode]:-none} in
        none)   pf="off" ;;
        static) pf="port ${V[gw.pf_port]} → CT ${V[gw.pf_target]}" ;;
        natpmp) pf="NAT-PMP → CT ${V[gw.pf_target]}$([ "${V[gw.qbit_sync]:-0}" = 1 ] && echo ' · synced to qBittorrent')" ;;
    esac
    if [ "${V[gw.mode]}" = create ]; then
        box_top "On this Proxmox host"
        box_row "${GR}New bridge${R}     ${V[gw.bridge]} (${V[gw.net]}), added to $IFACES_FILE (backed up) + ifreload"
        box_row "${GR}New container${R}  CT ${V[gw.ct]} ${V[gw.name]} · Debian · 256 MB · 2 GB on ${V[gw.storage]}"
        box_bot
    fi
    box_top "Gateway · CT ${V[gw.ct]} ${V[gw.name]}"
    box_row "${GR}LAN address${R}    ${gwaddr:-unchanged} on ${V[gw.lan_bridge]:-vmbr0}"
    box_row "${GR}VPN network${R}    ${V[gw.bridge]} ${V[gw.net]} · gateway ${V[gw.ip]:-$(net_prefix "${V[gw.net]}").1}"
    box_row "${GR}VPN${R}            $(provider_label "${V[gw.provider]}") · ${V[gw.primary.label]}"
    [ -n "${V[gw.backup.kind]:-}" ] && box_row "${GR}Backup${R}         ${V[gw.backup.label]}"
    box_row "${GR}Port forward${R}   $pf"
    if [ "${V[gw.lan_mode]:-open}" = open ]; then box_row "${GR}Home network${R}   ${V[lan_net]} · ${OK}containers can reach all of it${R}"
    else box_row "${GR}LAN out${R}        ${V[gw.lan_out]:-none}"; fi
    box_row "${GR}Kill switch${R}    ${OK}the VPN network can only leave through the tunnel${R}"
    box_bot
    for c in ${V[gw.clients]}; do
        local conv=""
        [ "$(reg_get "$c" ROLE)" = tunnel ] && conv=" · its own VPN gets removed"
        [ -n "${D[c$c.QBIT_IFACE]:-}" ] && conv="$conv · qBittorrent unbound from ${D[c$c.QBIT_IFACE]}"
        box_top "CT $c · ${V[c$c.name]}"
        box_row "${GR}New address${R}    ${V[c$c.ip]} on ${V[gw.bridge]} · DNS via the gateway$conv"
        local e pubs=""
        for e in ${V[c$c.publish]}; do pubs="$pubs ${gwaddr%/*}:${e%%:*}→${e#*:}"; done
        box_row "${GR}Published${R}     ${pubs:-nothing}"
        box_row "${GR}Restarts${R}       once, to switch networks"
        box_bot
    done
    for c in ${V[gw.old_clients]:-}; do
        case " ${V[gw.clients]} " in *" $c "*) ;; *) note "CT $c leaves the gateway and goes back to its old network" ;; esac
    done
    echo
    local snap go
    yn snap "Take Proxmox snapshots of existing containers first?" "${V[snap]:-y}" || return
    V[snap]=$snap
    yn go "Apply now?" y || return
    [ "$go" = y ] || return 1
}

gateway_wizard() {
    new_stage
    write_payload "$STAGE/payload"
    NT=0
    local rc
    while true; do
        PB=0; PAGE_TOTAL=7; DIR=fwd
        run_pages gw_intro; rc=$?
        [ "$rc" = 0 ] || return "$rc"
        local -a pages
        if is_express; then
            # the bridge, network and published ports are filled in by the pages that need them
            pages=(gw_container "pg_config gw")
            [ "${D[gw.HAS_BACKUP]:-}" = 1 ] && pages+=("pg_backup gw")
            pages+=(gw_clients gw_client_detect "pg_pf gw" gw_review)
        else
            pages=(gw_bridge gw_container "pg_provider gw" "pg_config gw" "pg_backup gw" gw_clients gw_client_detect gw_publish "pg_pf gw" gw_review)
        fi
        PB=1; PAGE_TOTAL=$((1 + ${#pages[@]}))
        run_pages "${pages[@]}"; rc=$?
        case $rc in
            0) break ;;
            1) continue ;;
            *) return 2 ;;
        esac
    done
    gateway_apply
}
# ════════════════════════════════════════════════════════════
#  Generating files and applying them
# ════════════════════════════════════════════════════════════

endpoint_elems() {   # "ip:port/proto ..." → "ip . proto . port, ..." (deduplicated)
    local e out="" ip rest port proto
    for e in $(printf '%s\n' $* | sort -u); do
        ip=${e%%:*}; rest=${e#*:}; port=${rest%/*}; proto=${rest#*/}
        out="${out:+$out, }$ip . $proto . $port"
    done
    printf '%s' "$out"
}
csv() { local x=$*; printf '%s' "${x// /, }"; }

needed_pkgs() {   # needed_pkgs TARGET → apt package names that are missing
    local t=$1
    local m=" ${D[$t.MISSING]:-} " p=""
    if [ "${V[$t.primary.kind]}" = openvpn ]; then case $m in *" openvpn "*) p="$p openvpn" ;; esac
    else case $m in *" wg "*|*" wg-quick "*) p="$p wireguard-tools" ;; esac; fi
    case $m in *" nft "*) p="$p nftables" ;; esac
    case $m in *" curl "*) p="$p curl" ;; esac
    case $m in *" ip "*|*" ss "*) p="$p iproute2" ;; esac
    [ "${V[$t.pf_mode]:-none}" = natpmp ] && case $m in *" natpmpc "*) p="$p natpmpc" ;; esac
    [ "$t" = gw ] && case $m in *" dnsmasq "*) p="$p dnsmasq" ;; esac
    printf '%s' "${p# }"
}

install_pkgs() {   # install_pkgs CT "pkgs" : waits for DNS and retries, a fresh container is often not ready for a few seconds
    local ct=$1 try
    for try in 1 2 3; do
        cexec "$ct" bash -c 'for i in $(seq 1 20); do getent hosts deb.debian.org >/dev/null 2>&1 && exit 0; sleep 1; done; exit 0'
        # shellcheck disable=SC2086
        if cexec "$ct" env DEBIAN_FRONTEND=noninteractive apt-get -qq -o Acquire::Retries=5 update \
           && cexec "$ct" env DEBIAN_FRONTEND=noninteractive apt-get -y -qq -o Acquire::Retries=5 install --no-install-recommends $2; then
            return 0
        fi
        sleep 5
    done
    return 1
}

ensure_tun() {   # give a container /dev/net/tun (needs a restart)
    local ct=$1 n
    pct config "$ct" | grep -Eq '^(dev[0-9]+: /dev/net/tun|lxc.mount.entry: /dev/net)' && return 0
    for n in $(seq 0 9); do pct config "$ct" | grep -q "^dev$n:" || break; done
    if ! pct set "$ct" "--dev$n" /dev/net/tun 2>/dev/null; then
        printf 'lxc.cgroup2.devices.allow: c 10:200 rwm\nlxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file\n' >> "/etc/pve/lxc/$ct.conf" || return 1
    fi
    pct reboot "$ct" >/dev/null 2>&1 || { pct stop "$ct"; pct start "$ct"; }
    wait_ct_net "$ct"
}

wait_ct_net() {
    local ct=$1 i
    for i in $(seq 1 40); do
        ct_forget
        [ "$(ct_status "$ct")" = running ] && cexec "$ct" true >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

snapshot_ct() { pct snapshot "$1" "vpnlxc_$(date +%Y%m%d_%H%M%S)" --description "before vpn-lxc.sh $(date '+%F %T')"; }
last_snapshot() { pct listsnapshot "$1" 2>/dev/null | grep -o 'vpnlxc_[0-9_]*' | sort | tail -n 1; }

# slots: rendered primary/backup configs (+ OpenVPN logins)
render_slots() {   # render_slots TARGET DIR
    local t=$1 d=$2 s user
    for s in primary backup; do
        [ -n "${V[$t.$s.kind]:-}" ] || continue
        if [ "${V[$t.$s.kind]}" = wireguard ]; then
            wg_render "${V[$t.$s.file]}" "$d/slot-$s.conf" "${V[$t.$s.pin]:-}" "${V[$t.$s.dns]}" || return 1
        else
            local authf=""
            [ "${V[$t.$s.auth]}" = 1 ] && authf="/etc/vpnguard/slots/$s.auth"
            ovpn_render "${V[$t.$s.file]}" "$d/slot-$s.conf" "${V[$t.$s.endpoints]}" "$authf" || return 1
            if [ -n "$authf" ]; then
                user=${V[$t.$s.user]}
                if [ "${V[$t.provider]}" = proton ] && [ "${V[$t.pf_mode]:-none}" = natpmp ] && [[ $user != *+pmp* ]]; then user="$user+pmp"; fi
                printf '%s\n%s\n' "$user" "${V[$t.$s.pass]}" > "$d/slot-$s.auth"
            fi
        fi
    done
}

stage_common() {   # stage_common TARGET DIR
    local t=$1 d=$2 f
    mkdir -p "$d"
    for f in apply.sh vpn-status vpnguard-dns vpnguard-switch vpnguard-ovpn-up vpnguard-qbit-port vpnguard-natpmp \
             vpnguard-natpmp.service vpnguard-openvpn.service nftables.conf dropin-nftables.conf dhclient-vpnguard; do
        cp "$STAGE/payload/$f" "$d/$f"
    done
    [ "${FW_ONLY:-0}" = 1 ] || render_slots "$t" "$d" || return 1
    {
        echo "RETIRE_LEGACY=$([ "${D[$t.LEGACY_RULES]:-0}${D[$t.LEGACY6_RULES]:-0}" != 00 ] && echo 1 || echo 0)"
        echo "QBIT_SYNC=${V[$t.qbit_sync]:-0}"
        echo "FW_ONLY=${FW_ONLY:-0}"
        echo "KEEP_QBIT_CRED=${V[$t.qbit_keep]:-0}"
    } > "$d/apply.env"
    if [ "${V[$t.qbit_sync]:-0}" = 1 ] && [ "${V[$t.qbit_keep]:-0}" != 1 ]; then
        {
            echo "QBIT_URL=${V[$t.qbit_url]}"
            if [ -n "${V[$t.qbit_user]:-}" ]; then echo "QBIT_USER=${V[$t.qbit_user]}"; echo "QBIT_PASS=${V[$t.qbit_pass]}"; fi
        } > "$d/qbit.env"
    fi
}

tunnel_vars() {   # sets PROTO VPN_IF UNIT for a target
    if [ "${V[$1.primary.kind]}" = openvpn ]; then PROTO=openvpn; VPN_IF=tun0; UNIT=vpnguard-openvpn.service
    else PROTO=wireguard; VPN_IF=wg0; UNIT=wg-quick@wg0.service; fi
}

stage_tunnel() {   # stage_tunnel TARGET DIR
    local t=$1 d=$2 PROTO VPN_IF UNIT
    tunnel_vars "$t"
    stage_common "$t" "$d" || return 1
    local lan=${D[$t.LAN_IF]} eps="${V[$t.primary.endpoints]} ${V[$t.backup.endpoints]:-}"
    local dhcp=0
    pct config "${V[$t.ct]}" | grep -E '^net[0-9]+:' | grep "name=$lan," | grep -q 'ip=dhcp' && dhcp=1
    {
        echo "# vpn-lxc.sh settings ($(date '+%F %T')). Re-run vpn-lxc.sh on the Proxmox host to change them."
        echo "VERSION=$VERSION"; echo "ROLE=tunnel"; echo "PROVIDER=${V[$t.provider]}"
        echo "PROTO=$PROTO"; echo "VPN_IF=$VPN_IF"; echo "TUNNEL_UNIT=$UNIT"
        echo "LAN_IF=$lan"; echo "LAN_NET=${V[lan_net]}"; echo "LAN_MODE=${V[$t.lan_mode]:-open}"; echo "LAN_TCP_PORTS=${V[$t.lan_tcp]}"; echo "LAN_OUT=${V[$t.lan_out]}"
        echo "DNS_PRIMARY=${V[$t.primary.dns]:-}"; echo "DNS_OVERRIDE="
        echo "ENDPOINTS=$(printf '%s\n' $eps | sort -u | tr '\n' ' ')"; echo "HOME_IP=${V[home_ip]:-}"; echo "APPS=${V[$t.apps]}"
        echo "PF_MODE=${V[$t.pf_mode]:-none}"; echo "PF_PORT=${V[$t.pf_port]:-}"; echo "PF_GATEWAY=${V[$t.pf_gw]:-}"
        echo "QBIT_URL=${V[$t.qbit_url]:-}"
    } > "$d/vpnguard.env"
    local out_elems="" e
    for e in ${V[$t.lan_out]}; do out_elems="${out_elems:+$out_elems, }${e%:*} . ${e##*:}"; done
    {
        echo '#!/usr/sbin/nft -f'
        echo "# VPN kill switch for CT ${V[$t.ct]} (${V[$t.name]}), generated by vpn-lxc.sh $(date '+%F %T')."
        echo "# Default-deny for IPv4 and IPv6. Re-run vpn-lxc.sh on the host to change it."
        echo "table inet vpnguard {}"
        echo "delete table inet vpnguard"
        echo "table inet vpnguard {"
        echo "	set endpoints {"
        echo "		type ipv4_addr . inet_proto . inet_service"
        echo "		elements = { $(endpoint_elems $eps) }"
        echo "	}"
        echo "	set lan_tcp {"
        echo "		type inet_service"
        [ -n "${V[$t.lan_tcp]}" ] && echo "		elements = { $(csv ${V[$t.lan_tcp]}) }"
        echo "	}"
        echo "	set lan_out {"
        echo "		type ipv4_addr . inet_service"
        [ -n "$out_elems" ] && echo "		elements = { $out_elems }"
        echo "	}"
        echo "	set pf_ports {"
        echo "		type inet_service"
        [ "${V[$t.pf_mode]:-none}" = static ] && echo "		elements = { ${V[$t.pf_port]} }"
        echo "	}"
        echo "	chain input {"
        echo "		type filter hook input priority filter; policy drop;"
        echo "		iifname \"lo\" accept"
        echo "		ct state invalid drop"
        echo "		ct state established,related accept"
        echo "		iifname \"$lan\" ip saddr . meta l4proto . th sport @endpoints accept"
        echo "		iifname \"$VPN_IF\" meta l4proto { tcp, udp } th dport @pf_ports accept"
        if [ "${V[$t.lan_mode]:-open}" = open ]; then
            echo "		iifname \"$lan\" ip saddr ${V[lan_net]} accept"
        else
            echo "		iifname \"$lan\" ip saddr ${V[lan_net]} tcp dport @lan_tcp accept"
            echo "		iifname \"$lan\" ip saddr ${V[lan_net]} icmp type echo-request accept"
        fi
        [ "$dhcp" = 1 ] && echo "		iifname \"$lan\" udp sport 67 udp dport 68 accept"
        echo "	}"
        echo "	chain forward {"
        echo "		type filter hook forward priority filter; policy drop;"
        echo "	}"
        echo "	chain output {"
        echo "		type filter hook output priority filter; policy drop;"
        echo "		oifname \"lo\" accept"
        echo "		ct state invalid drop"
        echo "		ct state established,related accept"
        echo "		oifname \"$VPN_IF\" accept"
        echo "		oifname \"$lan\" ip daddr . meta l4proto . th dport @endpoints accept"
        echo "		oifname \"$lan\" ip daddr . tcp dport @lan_out accept"
        if [ "${V[$t.lan_mode]:-open}" = open ]; then
            echo "		oifname \"$lan\" meta l4proto { tcp, udp } th dport { 53, 853 } drop"
            echo "		oifname \"$lan\" ip daddr ${V[lan_net]} accept"
        fi
        [ "$dhcp" = 1 ] && echo "		oifname \"$lan\" udp sport 68 udp dport 67 accept"
        echo "	}"
        echo "}"
    } > "$d/vpnguard.nft"
}

stage_gateway() {   # stage_gateway DIR
    local d=$1 PROTO VPN_IF UNIT
    tunnel_vars gw
    stage_common gw "$d" || return 1
    local eps="${V[gw.primary.endpoints]} ${V[gw.backup.endpoints]:-}" pre gwip c e publish="" pf_ip=""
    pre=$(net_prefix "${V[gw.net]}"); gwip="$pre.1"
    for c in ${V[gw.clients]}; do
        for e in ${V[c$c.publish]:-}; do publish="$publish ${e%%:*}:${V[c$c.ip]}:${e#*:}"; done
    done
    [ -n "${V[gw.pf_target]:-}" ] && pf_ip=${V[c${V[gw.pf_target]}.ip]:-}
    local dhcp=0; [ "${V[gw.lanaddr]:-}" = dhcp ] && dhcp=1
    [ "${V[gw.mode]}" = reconfig ] && [ "$(reg_get "${V[gw.ct]}" LAN_ADDR)" = dhcp ] && dhcp=1
    {
        echo "# vpn-lxc.sh settings ($(date '+%F %T')). Re-run vpn-lxc.sh on the Proxmox host to change them."
        echo "VERSION=$VERSION"; echo "ROLE=gateway"; echo "PROVIDER=${V[gw.provider]}"
        echo "PROTO=$PROTO"; echo "VPN_IF=$VPN_IF"; echo "TUNNEL_UNIT=$UNIT"
        echo "LAN_IF=eth0"; echo "LAN_NET=${V[lan_net]}"; echo "LAN_MODE=${V[gw.lan_mode]:-open}"; echo "VPNNET_IF=eth1"; echo "VPN_NET=${V[gw.net]}"; echo "GW_IP=$gwip"
        echo "DNS_PRIMARY=${V[gw.primary.dns]:-}"; echo "DNS_OVERRIDE="
        echo "ENDPOINTS=$(printf '%s\n' $eps | sort -u | tr '\n' ' ')"; echo "HOME_IP=${V[home_ip]:-}"; echo "APPS="
        echo "PUBLISH=$(echo $publish)"; echo "LAN_OUT=${V[gw.lan_out]:-}"
        echo "PF_MODE=${V[gw.pf_mode]:-none}"; echo "PF_PORT=${V[gw.pf_port]:-}"; echo "PF_GATEWAY=${V[gw.pf_gw]:-}"; echo "PF_TARGET=$pf_ip"
        echo "QBIT_URL=${V[gw.qbit_url]:-}"
    } > "$d/vpnguard.env"
    cat > "$d/dnsmasq.conf" <<EOF
# vpn-lxc.sh: DNS (only through the tunnel) and DHCP for the VPN network
interface=eth1
listen-address=127.0.0.1
bind-dynamic
no-resolv
servers-file=/etc/vpnguard-upstream.conf
domain-needed
bogus-priv
cache-size=1000
dhcp-range=$pre.100,$pre.199,255.255.255.0,12h
dhcp-option=option:router,$gwip
dhcp-option=option:dns-server,$gwip
EOF
    local out_elems=""
    for e in ${V[gw.lan_out]:-}; do out_elems="${out_elems:+$out_elems, }${e%:*} . ${e##*:}"; done
    {
        echo '#!/usr/sbin/nft -f'
        echo "# VPN gateway kill switch, generated by vpn-lxc.sh $(date '+%F %T')."
        echo "# The VPN network (${V[gw.net]} on eth1) can only leave through $VPN_IF."
        echo "table inet vpnguard {}"
        echo "delete table inet vpnguard"
        echo "table inet vpnguard {"
        echo "	set endpoints {"
        echo "		type ipv4_addr . inet_proto . inet_service"
        echo "		elements = { $(endpoint_elems $eps) }"
        echo "	}"
        echo "	set lan_out {"
        echo "		type ipv4_addr . inet_service"
        [ -n "$out_elems" ] && echo "		elements = { $out_elems }"
        echo "	}"
        echo "	set pf_ports {"
        echo "		type inet_service"
        [ "${V[gw.pf_mode]:-none}" = static ] && echo "		elements = { ${V[gw.pf_port]} }"
        echo "	}"
        echo "	chain prerouting {"
        echo "		type nat hook prerouting priority dstnat; policy accept;"
        for e in $publish; do
            local ext=${e%%:*} rest=${e#*:}
            echo "		iifname \"eth0\" ip saddr ${V[lan_net]} tcp dport $ext dnat ip to ${rest%%:*}:${rest#*:}"
        done
        [ -n "$pf_ip" ] && echo "		iifname \"$VPN_IF\" meta l4proto { tcp, udp } th dport @pf_ports dnat ip to $pf_ip"
        echo "	}"
        echo "	chain postrouting {"
        echo "		type nat hook postrouting priority srcnat; policy accept;"
        echo "		oifname \"$VPN_IF\" masquerade"
        echo "		oifname \"eth0\" ip saddr ${V[gw.net]} masquerade"
        echo "	}"
        echo "	chain input {"
        echo "		type filter hook input priority filter; policy drop;"
        echo "		iifname \"lo\" accept"
        echo "		ct state invalid drop"
        echo "		ct state established,related accept"
        echo "		iifname \"eth0\" ip saddr . meta l4proto . th sport @endpoints accept"
        echo "		iifname \"eth1\" ip saddr ${V[gw.net]} udp dport { 53, 67 } accept"
        echo "		iifname \"eth1\" ip saddr ${V[gw.net]} tcp dport 53 accept"
        echo "		iifname \"eth1\" udp sport 68 udp dport 67 accept"
        echo "		iifname \"eth1\" icmp type echo-request accept"
        if [ "${V[gw.lan_mode]:-open}" = open ]; then echo "		iifname \"eth0\" ip saddr ${V[lan_net]} accept"
        else echo "		iifname \"eth0\" ip saddr ${V[lan_net]} icmp type echo-request accept"; fi
        [ "$dhcp" = 1 ] && echo "		iifname \"eth0\" udp sport 67 udp dport 68 accept"
        echo "	}"
        echo "	chain forward {"
        echo "		type filter hook forward priority filter; policy drop;"
        echo "		ct state invalid drop"
        echo "		ct state established,related accept"
        echo "		iifname \"eth1\" ip saddr != ${V[gw.net]} drop"
        echo "		iifname \"eth1\" oifname \"$VPN_IF\" accept"
        echo "		iifname \"eth1\" oifname \"eth0\" ip daddr . tcp dport @lan_out accept"
        if [ "${V[gw.lan_mode]:-open}" = open ]; then
            echo "		iifname \"eth1\" oifname \"eth0\" meta l4proto { tcp, udp } th dport { 53, 853 } drop"
            echo "		iifname \"eth1\" oifname \"eth0\" ip daddr ${V[lan_net]} accept"
        fi
        echo "		iifname { \"eth0\", \"$VPN_IF\" } oifname \"eth1\" ct status dnat accept"
        echo "	}"
        echo "	chain output {"
        echo "		type filter hook output priority filter; policy drop;"
        echo "		oifname \"lo\" accept"
        echo "		ct state invalid drop"
        echo "		ct state established,related accept"
        echo "		oifname \"$VPN_IF\" accept"
        echo "		oifname \"eth0\" ip daddr . meta l4proto . th dport @endpoints accept"
        [ "${V[gw.lan_mode]:-open}" = open ] && echo "		oifname \"eth0\" ip daddr ${V[lan_net]} accept"
        echo "		oifname \"eth1\" accept"
        [ "$dhcp" = 1 ] && echo "		oifname \"eth0\" udp sport 68 udp dport 67 accept"
        echo "	}"
        echo "}"
    } > "$d/vpnguard.nft"
}

push_dir() {   # push_dir CT DIR
    local ct=$1 d=$2 f
    cexec "$ct" rm -rf "$STAGE_CT" && cexec "$ct" install -d -m 700 "$STAGE_CT" || return 1
    for f in "$d"/*; do
        [ -f "$f" ] || continue
        cpush "$ct" "$f" "$STAGE_CT/${f##*/}" 600 || return 1
    done
}

apply_in_ct() {   # apply_in_ct CT  (streams the checklist; RESULTS[] stays in this shell)
    RESULTS=()
    render_stream < <(cexec "$1" bash "$STAGE_CT/apply.sh" 2>&1; echo "RESULT __RC=$?")
    return "${RESULTS[__RC]:-1}"
}

section_head() { printf '\n  %s◆%s %s%s%s %s%s%s\n' "$PK" "$R" "$B" "$1" "$R" "$GR" "${2:-}" "$R"; }

install_watchdog() {
    [ "$(set_get WATCHDOG)" = 0 ] && return 0
    [ "$SELF" = /usr/local/sbin/vpn-lxc ] || install -m 755 "$SELF" /usr/local/sbin/vpn-lxc
    cat > /etc/systemd/system/vpn-lxc-watchdog.service <<'EOF'
[Unit]
Description=vpn-lxc.sh watchdog: checks VPN tunnels, restarts or fails over, notifies
After=pve-guests.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-lxc watchdog
EOF
    cat > /etc/systemd/system/vpn-lxc-watchdog.timer <<'EOF'
[Unit]
Description=Run the vpn-lxc.sh watchdog every 2 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload && systemctl enable --now vpn-lxc-watchdog.timer >/dev/null 2>&1
}

# ── per-container apply ─────────────────────────────────────
tunnel_apply() {
    FLOW="per-container setup"; CONTEXT=""; PAGE_TOTAL=0
    page "Applying" "Each container: snapshot, packages, files, then the firewall goes up before the tunnel does."
    V[home_ip]=$(home_ip)
    local t ct pk dir rc
    declare -gA RES=()
    for ((t = 1; t <= NT; t++)); do
        ct=${V[$t.ct]}
        section_head "CT $ct ${V[$t.name]}" "$(provider_label "${V[$t.provider]}") · ${V[$t.primary.kind]}"
        if [ "${V[snap]}" = y ]; then
            run_task "snapshot" snapshot_ct "$ct" || warn "no snapshot (storage without snapshot support?), file backups still happen"
        fi
        if [ "${V[$t.primary.kind]}" = openvpn ] && [ "${D[$t.HAS_TUN]:-}" != 1 ]; then
            run_task "adding /dev/net/tun (restarts the container)" ensure_tun "$ct" || { RES[$t]=fail; continue; }
        fi
        pk=$(needed_pkgs "$t")
        if [ -n "$pk" ]; then run_task "installing $pk" install_pkgs "$ct" "$pk" || { RES[$t]=fail; continue; }; fi
        dir="$STAGE/out$t"
        run_task "preparing the firewall and configs" stage_tunnel "$t" "$dir" || { RES[$t]=fail; continue; }
        run_task "copying files in" push_dir "$ct" "$dir" || { RES[$t]=fail; continue; }
        if [ -z "$(reg_get "$ct" ORIG_NS_SAVED)" ] && [ "$(reg_get "$ct" ROLE)" != client ]; then
            reg_set "$ct" ORIG_NS "$(pct config "$ct" | sed -n 's/^nameserver: //p')"; reg_set "$ct" ORIG_NS_SAVED 1
        fi
        [ -n "${V[$t.primary.dns]:-}" ] && pct set "$ct" --nameserver "${V[$t.primary.dns]}" >/dev/null 2>&1
        apply_in_ct "$ct"; rc=$?
        if [ "$rc" = 0 ]; then
            RES[$t]=ok
            local pushed; pushed=$(trim "${RESULTS[DNS]:-}")
            [ -z "${V[$t.primary.dns]:-}" ] && [ -n "$pushed" ] && pct set "$ct" --nameserver "$pushed" >/dev/null 2>&1
            reg_set "$ct" ROLE tunnel; reg_set "$ct" NAME "${V[$t.name]}"
            reg_set "$ct" FPS "$(echo ${V[$t.primary.fp]:-} ${V[$t.backup.fp]:-})"
            reg_set "$ct" PROVIDER "${V[$t.provider]}"; reg_set "$ct" PROTO "${V[$t.primary.kind]}"
        else
            RES[$t]=fail
        fi
    done
    echo
    run_task "watchdog timer on this host" install_watchdog
    tunnel_results
}

tunnel_results() {
    local t ct
    while true; do
        FLOW="per-container setup"; PAGE_TOTAL=0; CONTEXT=""
        page "Results" "A quick look at each container through its tunnel."
        run_task "checking the tunnels" brief_all
        for ((t = 1; t <= NT; t++)); do
            ct=${V[$t.ct]}
            if [ "${RES[$t]}" = ok ]; then
                local -A BR=()
                read_kv_into BR "" < "$STAGE/res/$t" 2>/dev/null
                if [ "${BR[TUNNEL]:-}" = up ] && [ -n "${BR[EXIT_IP]:-}" ]; then
                    ok "CT $ct ${V[$t.name]} · exit ${BR[EXIT_IP]} ${BR[CITY]:+(${BR[CITY]}, ${BR[COUNTRY]})}${BR[PF_PORT]:+ · port ${BR[PF_PORT]}}"
                else
                    warn "CT $ct ${V[$t.name]} · applied, but the tunnel isn't passing traffic yet"
                fi
            else
                bad "CT $ct ${V[$t.name]} · failed (the firewall stays closed, nothing leaks)"
            fi
            unset BR
        done
        echo
        local a
        pick a "What next?" "done" \
            "status|Full status screen|for one container" \
            "rollback|Roll back|restore a container's snapshot" \
            "done|Back to the main menu|" || return 0
        case $a in
            status)   pick_ct_from_targets ct && { cls; cexec "$ct" env FORCE_COLOR="$FANCY" /usr/local/sbin/vpn-status; pause; } ;;
            rollback) pick_ct_from_targets ct && rollback_ct "$ct" ;;
            done)     return 0 ;;
        esac
    done
}

brief_all() {
    local t
    mkdir -p "$STAGE/res"
    for ((t = 1; t <= NT; t++)); do
        [ "${RES[$t]}" = ok ] && cexec "${V[$t.ct]}" /usr/local/sbin/vpn-status --brief > "$STAGE/res/$t" 2>/dev/null &
    done
    wait
    return 0
}

pick_ct_from_targets() {
    local -n __out=$1
    local -a items=()
    local t
    for ((t = 1; t <= NT; t++)); do items+=("${V[$t.ct]}|CT ${V[$t.ct]} ${V[$t.name]}|${RES[$t]}"); done
    echo
    pick __out "Which container?" "${V[1.ct]}" "${items[@]}"
}

rollback_ct() {
    local ct=$1 snap a
    snap=$(last_snapshot "$ct")
    [ -n "$snap" ] || { bad "no vpn-lxc snapshot found for CT $ct"; pause; return; }
    yn a "Roll CT $ct back to $snap? (it restarts)" n || return
    [ "$a" = y ] || return
    run_task "rolling back CT $ct" bash -c "pct stop $ct >/dev/null 2>&1; pct rollback $ct $snap && pct start $ct" && reg_del "$ct"
    pause
}

# ── gateway apply ───────────────────────────────────────────
add_bridge() {
    local br=$1
    cp -a "$IFACES_FILE" "$IFACES_FILE.vpn-lxc.$(date +%Y%m%d-%H%M%S)" || return 1
    printf '\nauto %s\niface %s inet manual\n\tbridge-ports none\n\tbridge-stp off\n\tbridge-fd 0\n#VPN-only network (vpn-lxc.sh)\n' "$br" "$br" >> "$IFACES_FILE"
    ifreload -a && ip link show "$br" >/dev/null
}

ensure_template() {
    local store=$1 tpl have arch
    umask 022   # the template cache is shared with Proxmox itself
    arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
    pveam update >/dev/null 2>&1
    # the list has an arm64 build of every template: it must match this host
    tpl=$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E "^debian-13-standard_.*_${arch}\.tar" | sort -V | tail -n 1)
    [ -z "$tpl" ] && tpl=$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E "^debian-12-standard_.*_${arch}\.tar" | sort -V | tail -n 1)
    have=$(pveam list "$store" 2>/dev/null | awk '{print $1}' | sed 's#.*/##' | grep -E "^debian-1[23]-standard_.*_${arch}\.tar" | sort -V | tail -n 1)
    if [ -n "$tpl" ] && ! pveam list "$store" 2>/dev/null | grep -q "$tpl"; then
        pveam download "$store" "$tpl" || { [ -n "$have" ] && tpl=$have || return 1; }
    fi
    [ -n "$tpl" ] || tpl=$have
    [ -n "$tpl" ] || { echo "no Debian template found (pveam available)"; return 1; }
    echo "$store:vztmpl/$tpl" > "$STAGE/template"
}

create_gateway() {
    local id=${V[gw.ct]} lan=${V[gw.lanaddr]} net0 net1 tpl
    tpl=$(cat "$STAGE/template")
    if [ "$lan" = dhcp ]; then net0="name=eth0,bridge=${V[gw.lan_bridge]},ip=dhcp,type=veth"
    else net0="name=eth0,bridge=${V[gw.lan_bridge]},ip=$lan,gw=${V[gw.lan_gw]},type=veth"; fi
    net1="name=eth1,bridge=${V[gw.bridge]},ip=$(net_prefix "${V[gw.net]}").1/24,type=veth"
    local -a args=("$id" "$tpl" --hostname "${V[gw.name]}" --arch "$(dpkg --print-architecture)" --memory 256 --swap 128 --cores 1
                   --rootfs "${V[gw.storage]}:2" --net0 "$net0" --net1 "$net1" --unprivileged 1
                   --features nesting=1 --onboot 1 --startup 'order=1,up=15' --ostype debian
                   --description "VPN gateway, managed by vpn-lxc.sh")
    # this script runs with umask 077 to protect its secrets; a container created that way gets a root-only /etc
    umask 022
    if ! pct create "${args[@]}" --dev0 /dev/net/tun; then
        ct_exists "$id" && return 1
        pct create "${args[@]}" || return 1
        printf 'lxc.cgroup2.devices.allow: c 10:200 rwm\nlxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file\n' >> "/etc/pve/lxc/$id.conf"
    fi
    pct start "$id" && wait_ct_net "$id" || return 1
    local i
    for i in $(seq 1 30); do cexec "$id" getent hosts deb.debian.org >/dev/null 2>&1 && return 0; sleep 2; done
    echo "the new container has no internet access on your LAN"
    return 1
}

client_move() {   # client_move CT
    local c=$1
    local key=${V[c$c.netkey]} orig hw fw name newnet line k
    orig=$(pct config "$c" | sed -n "s/^$key: //p")
    reg_set "$c" ORIG_NET "$orig"; reg_set "$c" NETKEY "$key"
    [ -n "$(reg_get "$c" ORIG_NS_SAVED)" ] || { reg_set "$c" ORIG_NS "$(pct config "$c" | sed -n 's/^nameserver: //p')"; reg_set "$c" ORIG_NS_SAVED 1; }
    hw=$(tr ',' '\n' <<<"$orig" | grep '^hwaddr=')
    fw=$(tr ',' '\n' <<<"$orig" | grep '^firewall=')
    name=$(tr ',' '\n' <<<"$orig" | grep '^name='); name=${name:-name=eth0}
    newnet="$name,bridge=${V[gw.bridge]}${hw:+,$hw},ip=${V[c$c.ip]}/24,gw=$(net_prefix "${V[gw.net]}").1,type=veth${fw:+,$fw}"
    pct set "$c" "--$key" "$newnet" || return 1
    local extra=""
    while IFS= read -r line; do
        k=${line%%:*}
        [ "$k" = "$key" ] && continue
        extra="${extra:+$extra;}$line"
        pct set "$c" --delete "$k" || return 1
    done < <(pct config "$c" | grep -E '^net[0-9]+:')
    reg_set "$c" ORIG_EXTRA "$extra"
    pct set "$c" --nameserver "$(net_prefix "${V[gw.net]}").1"
}

client_detach() {   # client_detach CT : back to the network it had before
    local c=$1 key orig extra ns item
    key=$(reg_get "$c" NETKEY); orig=$(reg_get "$c" ORIG_NET); extra=$(reg_get "$c" ORIG_EXTRA); ns=$(reg_get "$c" ORIG_NS)
    [ -n "$key" ] && [ -n "$orig" ] || { echo "no saved network for CT $c"; return 1; }
    pct set "$c" "--$key" "$orig" || return 1
    if [ -n "$extra" ]; then
        local IFS=';'
        for item in $extra; do pct set "$c" "--${item%%: *}" "${item#*: }"; done
        unset IFS
    fi
    if [ -n "$ns" ]; then pct set "$c" --nameserver "$ns"; else pct set "$c" --delete nameserver; fi
    pct reboot "$c" >/dev/null 2>&1
    reg_del "$c"
}

gateway_apply() {
    FLOW="VPN gateway"; CONTEXT=""; PAGE_TOTAL=0
    page "Applying" "The gateway's firewall goes up before its tunnel, and containers only move once the gateway works."
    V[home_ip]=$(home_ip)
    local g=${V[gw.ct]} c rc
    if [ "${V[gw.mode]}" = create ]; then
        section_head "Proxmox host"
        run_task "adding bridge ${V[gw.bridge]}" add_bridge "${V[gw.bridge]}" || { pause; return 1; }
        run_task "fetching the Debian template" ensure_template "${V[gw.tstore]}" || { pause; return 1; }
        run_task "creating CT $g ${V[gw.name]}" create_gateway || { pause; return 1; }
        detect_task "looking inside the new container" gw "$g" || { pause; return 1; }
    elif [ "${V[snap]}" = y ]; then
        section_head "Snapshots"
        run_task "CT $g ${V[gw.name]}" snapshot_ct "$g" || warn "no snapshot for the gateway"
    fi

    section_head "Gateway CT $g ${V[gw.name]}" "$(provider_label "${V[gw.provider]}") · ${V[gw.primary.kind]}"
    if [ "${V[gw.primary.kind]}" = openvpn ] && [ "${D[gw.HAS_TUN]:-}" != 1 ]; then
        run_task "adding /dev/net/tun (restarts the gateway)" ensure_tun "$g" || { pause; return 1; }
    fi
    local pk; pk=$(needed_pkgs gw)
    [ -n "$pk" ] && { run_task "installing $pk" install_pkgs "$g" "$pk" || { pause; return 1; }; }
    run_task "preparing the firewall and configs" stage_gateway "$STAGE/outgw" || { pause; return 1; }
    run_task "copying files in" push_dir "$g" "$STAGE/outgw" || { pause; return 1; }
    pct set "$g" --nameserver 127.0.0.1 >/dev/null 2>&1
    apply_in_ct "$g"; rc=$?
    if [ "$rc" != 0 ]; then
        bad "the gateway didn't come up, so no containers were moved"
        pause; return 1
    fi
    if [ -n "${V[gw.newname]:-}" ] && [ "${V[gw.newname]}" != "${V[gw.name]}" ]; then
        pct set "$g" --hostname "${V[gw.newname]}" >/dev/null 2>&1
        cexec "$g" sh -c "echo '${V[gw.newname]}' > /etc/hostname; hostname '${V[gw.newname]}'" >/dev/null 2>&1
        ok "renamed ${V[gw.name]} → ${V[gw.newname]}"
        V[gw.name]=${V[gw.newname]}
    fi
    reg_set "$g" ROLE gateway; reg_set "$g" NAME "${V[gw.name]}"; reg_set "$g" PROVIDER "${V[gw.provider]}"
    reg_set "$g" FPS "$(echo ${V[gw.primary.fp]:-} ${V[gw.backup.fp]:-})"
    reg_set "$g" PROTO "${V[gw.primary.kind]}"; reg_set "$g" BRIDGE "${V[gw.bridge]}"; reg_set "$g" VPN_NET "${V[gw.net]}"
    [ "${V[gw.mode]}" = create ] && reg_set "$g" LAN_ADDR "${V[gw.lanaddr]}"

    for c in ${V[gw.clients]}; do
        local publish_reg="" e
        for e in ${V[c$c.publish]:-}; do publish_reg="$publish_reg $e"; done
        if [ "$(reg_get "$c" ROLE)" = client ]; then
            reg_set "$c" PUBLISH "${publish_reg# }"
            continue
        fi
        section_head "CT $c ${V[c$c.name]}" "→ ${V[c$c.ip]} behind the gateway"
        [ "${V[snap]}" = y ] && { run_task "snapshot" snapshot_ct "$c" || warn "no snapshot"; }
        local was_tunnel=0; [ "$(reg_get "$c" ROLE)" = tunnel ] && was_tunnel=1
        run_task "moving it to ${V[gw.bridge]}" client_move "$c" || { bad "could not move CT $c"; continue; }
        if [ "$was_tunnel" = 1 ] || [ "${D[c$c.HAS_SETUP]:-}" = 1 ]; then
            cpush "$c" "$STAGE/payload/remove.sh" /tmp/vpnguard-remove.sh 700
            cexec "$c" bash /tmp/vpnguard-remove.sh 0 1 2>&1 | render_stream
        fi
        cpush "$c" "$STAGE/payload/client.sh" /tmp/vpnguard-client.sh 700
        cexec "$c" bash /tmp/vpnguard-client.sh "$(net_prefix "${V[gw.net]}").1" "${D[c$c.QBIT_CONF]:--}" 2>&1 | render_stream
        run_task "restarting it on the new network" bash -c "pct reboot $c >/dev/null 2>&1 || { pct stop $c; pct start $c; }"
        kvfile_del "$REG/$c.env" PROVIDER; kvfile_del "$REG/$c.env" PROTO
        reg_set "$c" ROLE client; reg_set "$c" NAME "${V[c$c.name]}"; reg_set "$c" GATEWAY "$g"
        reg_set "$c" IP "${V[c$c.ip]}"; reg_set "$c" PUBLISH "${publish_reg# }"
    done
    for c in ${V[gw.old_clients]:-}; do
        case " ${V[gw.clients]} " in *" $c "*) continue ;; esac
        section_head "CT $c" "leaves the gateway"
        run_task "back to its old network" client_detach "$c"
    done
    echo
    run_task "watchdog timer on this host" install_watchdog
    gateway_results
}

gateway_results() {
    local g=${V[gw.ct]} c gwexit
    FLOW="VPN gateway"; PAGE_TOTAL=0; CONTEXT=""
    page "Results" "Checking the gateway, then asking each container which IP the internet sees. They should all match the gateway's."
    local -A BR=()
    run_task "gateway tunnel" bash -c "pct exec $g -- /usr/local/sbin/vpn-status --brief > '$STAGE/res-gw' 2>/dev/null"
    read_kv_into BR "" < "$STAGE/res-gw"
    gwexit=${BR[EXIT_IP]:-}
    if [ "${BR[TUNNEL]:-}" = up ] && [ -n "$gwexit" ]; then
        ok "gateway exit $gwexit ${BR[CITY]:+(${BR[CITY]}, ${BR[COUNTRY]})}${BR[PF_PORT]:+ · forwarded port ${BR[PF_PORT]}}"
    else
        warn "the gateway's tunnel isn't passing traffic yet"
    fi
    sleep 4
    for c in ${V[gw.clients]}; do
        local ip=""
        wait_ct_net "$c" >/dev/null 2>&1
        ip=$(cexec "$c" sh -c 'command -v curl >/dev/null && for i in 1 2; do curl -4 -s -m 8 https://ipinfo.io/ip && break; done || wget -qO- -T 8 https://ipinfo.io/ip' 2>/dev/null)
        if [ -z "$ip" ]; then warn "CT $c ${V[c$c.name]}: no internet answer yet (still booting?)"
        elif [ "$ip" = "$gwexit" ]; then ok "CT $c ${V[c$c.name]} (${V[c$c.ip]}) exits as $ip ${OK}· same as the gateway${R}"
        else bad "CT $c ${V[c$c.name]} exits as $ip, not the gateway's $gwexit"; fi
    done
    local gwaddr=${V[gw.lanaddr]%/*}
    [ "${V[gw.mode]}" = reconfig ] && gwaddr=$(reg_get "$g" LAN_ADDR); gwaddr=${gwaddr%/*}
    echo
    box_top "Open your apps at"
    local e any=0
    for c in ${V[gw.clients]}; do
        for e in ${V[c$c.publish]:-}; do box_row "${CY}http://${gwaddr}:${e%%:*}${R}  ${GR}→ ${V[c$c.name]} port ${e#*:}${R}"; any=1; done
    done
    [ "$any" = 0 ] && box_row "${GR}nothing published${R}"
    box_bot
    note "update apps that talk to these (Lidarr's download client, Prowlarr's apps) to the addresses above"
    note "containers behind the gateway reach each other directly on ${V[gw.bridge]}, e.g. Prowlarr → qBittorrent at its 10.x address"
    pause
}
# ════════════════════════════════════════════════════════════
#  Dashboard
# ════════════════════════════════════════════════════════════
probe_all() {   # probe_all DIR : brief status of every managed container, in parallel
    local d=$1 id role
    mkdir -p "$d"; rm -f "$d"/*
    for id in $(reg_ids); do
        [ "$(ct_status "$id")" = running ] || continue
        role=$(reg_get "$id" ROLE)
        case $role in
            tunnel|gateway) cexec "$id" /usr/local/sbin/vpn-status --brief > "$d/$id" 2>/dev/null & ;;
            client) cexec "$id" sh -c 'command -v curl >/dev/null && curl -4 -s -m 6 https://ipinfo.io/ip || wget -qO- -T 6 https://ipinfo.io/ip' > "$d/$id.ip" 2>/dev/null & ;;
        esac
    done
    wait
    return 0
}

ago() { local s=$1; if [ "$s" -lt 0 ]; then echo "—"; elif [ "$s" -lt 120 ]; then echo "${s}s"; else echo "$((s / 60))m"; fi; }

hb() { awk -v b="${1:-0}" 'BEGIN { split("B KiB MiB GiB TiB", u); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf "%.1f%s", b, u[i] }'; }

dash_row() {   # dash_row ID [indent]
    local id=$1 d="$STAGE/dash" name role st dot line nw=12 more=""
    [ "$W" -ge 100 ] && nw=18; [ "$W" -ge 130 ] && nw=24
    name=$(reg_get "$id" NAME); role=$(reg_get "$id" ROLE); st=$(ct_status "$id")
    local -A BR=()
    [ -f "$d/$id" ] && read_kv_into BR "" < "$d/$id"
    if [ "$st" != running ]; then
        DASH_OFF=$((DASH_OFF + 1))
        dot="$DG○$R"; line=$(printf '%s %-4s %-*.*s %s%-7s%s %s%s%s' "$dot" "$id" "$nw" "$nw" "$name" "$GR" "$role" "$R" "$DG" "$st" "$R")
    elif [ "$role" = client ]; then
        local ip gwexit
        ip=$(cat "$d/$id.ip" 2>/dev/null)
        gwexit=$(kvfile_get "$d/$(reg_get "$id" GATEWAY)" EXIT_IP)
        if [ -n "$ip" ] && [ "$ip" = "$gwexit" ]; then dot="$OK●$R"; DASH_OK=$((DASH_OK + 1)); else dot="$WA●$R"; DASH_BAD=$((DASH_BAD + 1)); fi
        line=$(printf '  %s└%s %s %-4s %-*.*s %s%-13s%s %s' "$DG" "$R" "$dot" "$id" "$((nw - 1))" "$((nw - 1))" "$name" "$GR" "$(reg_get "$id" IP)" "$R" \
            "$([ -n "$ip" ] && [ "$ip" = "$gwexit" ] && echo "${OK}via gateway${R}" || echo "${WA}${ip:-no answer}${R}")")
    else
        local prov proto exit extra=""
        prov=$(provider_label "${BR[PROVIDER]:-$(reg_get "$id" PROVIDER)}"); proto=${BR[PROTO]:-$(reg_get "$id" PROTO)}
        [ "$proto" = wireguard ] && proto=wg || proto=ovpn
        if [ "${BR[TUNNEL]:-}" = up ] && [ -n "${BR[EXIT_IP]:-}" ]; then dot="$OK●$R"; exit="${BR[EXIT_IP]} ${GR}${BR[COUNTRY]:-}${R}"; DASH_OK=$((DASH_OK + 1))
        elif [ "${BR[TUNNEL]:-}" = up ]; then dot="$WA●$R"; exit="${WA}no traffic${R}"; DASH_BAD=$((DASH_BAD + 1))
        else dot="$ER●$R"; exit="${ER}tunnel down${R}"; DASH_BAD=$((DASH_BAD + 1)); fi
        [ -n "${BR[PF_PORT]:-}" ] && extra="$extra ${CY}⇅${BR[PF_PORT]}${R}"
        [ "${BR[ACTIVE]:-}" = backup ] && extra="$extra ${WA}⟲backup${R}"
        [ "${BR[PROTO]:-}" = wireguard ] && [ "${BR[HS_AGE]:--1}" -ge 0 ] && extra="$extra ${DG}$(ago "${BR[HS_AGE]}")${R}"
        if [ "$W" -ge 100 ]; then
            [ "$role" = gateway ] && more="  ${DG}$(reg_get "$id" BRIDGE) · $(reg_get "$id" LAN_ADDR)${R}"
            [ "$W" -ge 130 ] && [ -n "${BR[RX]:-}" ] && more="$more  ${DG}▼$(hb "${BR[RX]}") ▲$(hb "${BR[TX]:-0}")${R}"
        fi
        line=$(printf '%s %-4s %-*.*s %s%-7s%s %s %s%s%s' "$dot" "$id" "$nw" "$nw" "$name" "$GR" "$role" "$R" "$(padr "${prov%% *} · $proto" 14)" "$exit" "$extra" "$more")
    fi
    box_row "$line"
}

DASH_OK=0; DASH_BAD=0; DASH_OFF=0
dashboard() {   # dashboard [cached] : "cached" draws what probe_all already collected
    local ids gw id
    ids=$(reg_ids)
    if [ -z "$ids" ]; then
        box_top "Your containers"
        box_row "${GR}Nothing is protected yet. Choose ${R}${B}Protect containers${R}${GR} or ${R}${B}VPN gateways${R}${GR}: Express takes about a minute.${R}"
        box_bot
        return
    fi
    if [ "${1:-}" != cached ]; then
        run_task "checking $(wc -w <<<"$ids") containers" probe_all "$STAGE/dash"
        [ "$FANCY" = 1 ] && printf '\e[1A\e[2K'
    fi
    DASH_OK=0; DASH_BAD=0; DASH_OFF=0
    box_top "Your containers"
    for id in $ids; do [ "$(reg_get "$id" ROLE)" = tunnel ] && dash_row "$id"; done
    for gw in $ids; do
        [ "$(reg_get "$gw" ROLE)" = gateway ] || continue
        dash_row "$gw"
        for id in $ids; do [ "$(reg_get "$id" ROLE)" = client ] && [ "$(reg_get "$id" GATEWAY)" = "$gw" ] && dash_row "$id"; done
    done
    for id in $ids; do
        [ "$(reg_get "$id" ROLE)" = client ] || continue
        gw=$(reg_get "$id" GATEWAY)
        [ "$(reg_get "$gw" ROLE)" = gateway ] && continue
        box_row "${WA}▲${R} CT $id $(reg_get "$id" NAME) is set to gateway CT $gw, which isn't set up (use Remove)"
    done
    local wd="${ER}off${R}"
    systemctl is-active --quiet vpn-lxc-watchdog.timer 2>/dev/null && wd="${OK}on${R}"
    local nk; nk=$(set_get NOTIFY_KIND); nk=${nk:-none}
    box_row "${DG}$(rep ─ $((W - 4)))${R}"
    local sum="${OK}✔ $DASH_OK protected${R}"
    [ "$DASH_BAD" -gt 0 ] && sum="$sum   ${WA}▲ $DASH_BAD need attention${R}"
    [ "$DASH_OFF" -gt 0 ] && sum="$sum   ${DG}○ $DASH_OFF stopped${R}"
    box_row "$sum"
    box_row "${GR}watchdog${R} $wd   ${GR}notifications${R} $nk   ${GR}library${R} $(lib_names | wc -l) configs"
    box_bot
}

# live view: refreshes every 10 s, any key goes back
live_screen() {
    local k
    new_stage
    if [ "$INTERACTIVE" != 1 ]; then dashboard; return 0; fi
    cls; printf '\n    %sgathering the first reading...%s\n' "$GR" "$R"
    while true; do
        probe_all "$STAGE/dash"
        FLOW="live dashboard"; PAGE_TOTAL=0; CONTEXT=""
        page "Live dashboard" "Refreshes every 10 seconds. Press any key to go back."
        dashboard cached
        printf '\n    %s%s%s\n' "$GR" "updated $(date +%H:%M:%S)" "$R"
        cur_hide
        if IFS= read -rsn1 -t 10 k; then cur_show; return 0; fi
    done
}

# ════════════════════════════════════════════════════════════
#  Port forwarding menu (per gateway). Two kinds:
#    · from the internet, through the VPN, to one container (NAT-PMP or a fixed port)
#    · from your home network, through the gateway's address, to a container's ports
#  Changes only reload the gateway's firewall; the tunnel is never restarted.
# ════════════════════════════════════════════════════════════

# pf_load_gateway GWID : fill V from the registry and the gateway's own settings file
pf_load_gateway() {
    local g=$1 envf="$STAGE/gw-$g.env" c
    local -A GE=()
    pct pull "$g" /etc/vpnguard/vpnguard.env "$envf" >/dev/null 2>&1 || return 1
    read_kv_into GE "" < "$envf"
    V[gw.mode]=reconfig; V[gw.ct]=$g; V[gw.name]=$(reg_get "$g" NAME); V[gw.name]=${V[gw.name]:-$(ct_name "$g")}
    V[gw.provider]=${GE[PROVIDER]:-other}; V[gw.bridge]=$(reg_get "$g" BRIDGE); V[gw.net]=${GE[VPN_NET]}; V[gw.ip]=${GE[GW_IP]}
    V[gw.lanaddr]=$(reg_get "$g" LAN_ADDR); V[lan_net]=${GE[LAN_NET]}; V[gw.lan_mode]=${GE[LAN_MODE]:-open}; V[gw.lan_out]=${GE[LAN_OUT]}
    V[gw.primary.kind]=${GE[PROTO]:-wireguard}; V[gw.primary.endpoints]=${GE[ENDPOINTS]}; V[gw.primary.dns]=${GE[DNS_PRIMARY]}
    V[gw.pf_mode]=${GE[PF_MODE]:-none}; V[gw.pf_port]=${GE[PF_PORT]}; V[gw.pf_gw]=${GE[PF_GATEWAY]}; V[gw.qbit_url]=${GE[QBIT_URL]}
    V[home_ip]=${GE[HOME_IP]}
    V[gw.clients]=""; V[gw.pf_target]=""
    for c in $(gateway_clients_of "$g"); do
        V[gw.clients]="${V[gw.clients]} $c"
        V[c$c.name]=$(reg_get "$c" NAME); V[c$c.ip]=$(reg_get "$c" IP); V[c$c.publish]=$(reg_get "$c" PUBLISH)
        [ -n "${GE[PF_TARGET]}" ] && [ "${V[c$c.ip]}" = "${GE[PF_TARGET]}" ] && V[gw.pf_target]=$c
    done
    V[gw.clients]=${V[gw.clients]# }
    # a stored qBittorrent login stays in place unless the forwarded port setup is redone
    if cexec "$g" test -f /etc/vpnguard/qbit.env 2>/dev/null; then V[gw.qbit_sync]=1; V[gw.qbit_keep]=1; fi
    return 0
}

pf_tables() {
    local gwaddr=${V[gw.lanaddr]%/*} c e pf port rows=0
    [ "$gwaddr" = dhcp ] && gwaddr="the gateway"
    case ${V[gw.pf_mode]:-none} in
        none)   pf="off" ;;
        natpmp) port=$(cexec "${V[gw.ct]}" cat /run/vpnguard-pf-port 2>/dev/null)
                pf="NAT-PMP · port ${port:-pending} → CT ${V[gw.pf_target]:-?} ${V[c${V[gw.pf_target]:-0}.name]:-}" ;;
        static) pf="fixed port ${V[gw.pf_port]} → CT ${V[gw.pf_target]:-?} ${V[c${V[gw.pf_target]:-0}.name]:-}" ;;
    esac
    box_top "From the internet, through the VPN"
    box_row "$pf"
    box_bot
    box_top "From your home network, through ${gwaddr}"
    for c in ${V[gw.clients]}; do
        for e in ${V[c$c.publish]}; do
            box_row "${CY}${gwaddr}:${e%%:*}${R}  →  ${V[c$c.name]} (CT $c) port ${e#*:}"; rows=1
        done
    done
    [ "$rows" = 0 ] && box_row "${GR}nothing published${R}"
    box_bot
}

# edit one container's published ports
pf_edit_published() {
    local -a items=(); local c pick_c pub e ok_all other taken
    for c in ${V[gw.clients]}; do items+=("$c|CT $c ${V[c$c.name]}|${V[c$c.publish]:-nothing published}"); done
    [ ${#items[@]} -gt 0 ] || { warn "no containers behind this gateway yet"; pause; return 0; }
    echo
    pick pick_c "Which container?" "" "${items[@]}" || return 0
    if [ -z "${D[c$pick_c.LISTEN_TCP]+x}" ]; then
        V[c$pick_c.name]=${V[c$pick_c.name]:-$(ct_name "$pick_c")}
        detect_task "looking at CT $pick_c ${V[c$pick_c.name]}" "c$pick_c" "$pick_c" || warn "could not look inside, you can still type ports by hand"
    fi
    [ -n "${D[c$pick_c.LISTEN_TCP]:-}" ] && note "CT $pick_c listens on: tcp ${D[c$pick_c.LISTEN_TCP]}"
    note "type ports like: 8090 9696, or outside:inside like 2222:22 (- for none)"
    while true; do
        field pub "Ports to publish for ${V[c$pick_c.name]}" "${V[c$pick_c.publish]}" v_publish || return 0
        ok_all=1; taken=" 53 67 "
        for other in ${V[gw.clients]}; do
            [ "$other" = "$pick_c" ] && continue
            for e in ${V[c$other.publish]}; do taken="$taken${e%%:*} "; done
        done
        for e in $pub; do
            case "$taken" in *" ${e%%:*} "*) bad "outside port ${e%%:*} is already used by another container (try $((${e%%:*} + 10000)):${e#*:})"; ok_all=0 ;; esac
        done
        [ "$ok_all" = 1 ] && break
    done
    V[c$pick_c.publish]=$pub
    PF_CHANGED=1
}

# change the port the VPN forwards (mode, target container, qBittorrent sync)
pf_edit_vpn() {
    local c
    [ -n "${V[gw.clients]}" ] || { warn "no containers behind this gateway yet"; pause; return 0; }
    for c in ${V[gw.clients]}; do
        [ -n "${D[c$c.LISTEN_TCP]+x}" ] && continue
        V[c$c.name]=${V[c$c.name]:-$(ct_name "$c")}
        detect_task "looking at CT $c ${V[c$c.name]}" "c$c" "$c" || true
    done
    V[gw.qbit_sync]=0; V[gw.qbit_keep]=0
    local rc
    pg_pf gw; rc=$?
    case $rc in 0) PF_CHANGED=1 ;; 2) return 2 ;; esac
    return 0
}

pf_apply() {
    local g=${V[gw.ct]} rc c
    FLOW="port forwarding"; PAGE_TOTAL=0; CONTEXT=""
    page "Applying" "Only the gateway's firewall and port forwarding are reloaded. The VPN stays connected."
    FW_ONLY=1
    run_task "preparing the firewall" stage_gateway "$STAGE/outgw" || { FW_ONLY=0; pause; return 1; }
    run_task "copying files in" push_dir "$g" "$STAGE/outgw" || { FW_ONLY=0; pause; return 1; }
    FW_ONLY=0
    apply_in_ct "$g"; rc=$?
    if [ "$rc" != 0 ]; then bad "the gateway did not take the change (the previous firewall is still in place if it failed its check)"; pause; return 1; fi
    for c in ${V[gw.clients]}; do reg_set "$c" PUBLISH "${V[c$c.publish]}"; done
    PF_CHANGED=0
    echo
    pf_tables
    pause
}

port_screen() {
    local g a name
    new_stage; write_payload "$STAGE/payload"
    FLOW="port forwarding"; PAGE_TOTAL=0; CONTEXT=""
    PF_CHANGED=0
    page "Port forwarding" "Choose a gateway, then change what is reachable from the internet (through the VPN) and from your home network."
    pick_managed g "gateway" "Which gateway?" || return 0
    V=(); D=()
    pf_load_gateway "$g" || { bad "could not read the gateway's settings (is CT $g running?)"; pause; return 0; }
    name=${V[gw.name]}
    while true; do
        FLOW="port forwarding"; PAGE_TOTAL=0; CONTEXT=""
        page "Port forwarding · $name" "Nothing changes until you choose Apply."
        pf_tables
        [ "$PF_CHANGED" = 1 ] && printf '\n    %s▲ unsaved changes%s\n' "$WA" "$R"
        echo
        pick a "What now?" "$([ "$PF_CHANGED" = 1 ] && echo apply || echo back)" \
            "ports|Published ports|choose which of a container's ports your home network can reach" \
            "vpn|Port from the VPN|the port your provider forwards, and which container gets it" \
            "apply|Apply changes|reload the gateway's firewall (the VPN stays connected)" \
            "back|Back|$([ "$PF_CHANGED" = 1 ] && echo "discard unsaved changes")" || return 0
        case $a in
            ports) pf_edit_published ;;
            vpn)   pf_edit_vpn; [ $? = 2 ] && return 0 ;;
            apply) [ "$PF_CHANGED" = 1 ] || { note "nothing to apply"; nap 0.8; continue; }
                   pf_apply && { pf_load_gateway "$g"; } ;;
            back)  return 0 ;;
        esac
    done
}
# ════════════════════════════════════════════════════════════
#  Smaller screens
# ════════════════════════════════════════════════════════════
pick_managed() {   # pick_managed VAR "roles" "prompt"
    local -n __o=$1
    local __roles=" $2 " __id
    local -a __items=()
    for __id in $(reg_ids); do
        case "$__roles" in *" $(reg_get "$__id" ROLE) "*) ;; *) continue ;; esac
        __items+=("$__id|$__id $(reg_get "$__id" NAME)|$(reg_get "$__id" ROLE) · $(ct_status "$__id")")
    done
    [ ${#__items[@]} -gt 0 ] || { warn "nothing to pick here yet"; pause; return 1; }
    pick __o "${3:-Which container?}" "" "${__items[@]}"
}

status_screen() {
    FLOW="status"; PAGE_TOTAL=0; CONTEXT=""
    page "Status screen" "The full check, run inside the container."
    local id
    pick_managed id "tunnel gateway client" || return 0
    if [ "$(reg_get "$id" ROLE)" = client ]; then
        local g ip; g=$(reg_get "$id" GATEWAY)
        ip=$(cexec "$id" sh -c 'command -v curl >/dev/null && curl -4 -s -m 6 https://ipinfo.io/ip' 2>/dev/null)
        echo
        note "CT $id sits behind gateway CT $g; it has no tunnel of its own. It exits as: ${ip:-no answer}"
        note "showing the gateway's status:"
        pause
        id=$g
    fi
    cls
    cexec "$id" env FORCE_COLOR="$FANCY" /usr/local/sbin/vpn-status
    pause
}

switch_screen() {
    FLOW="primary ⇄ backup"; PAGE_TOTAL=0; CONTEXT=""
    page "Primary ⇄ backup" "Switch a tunnel to its other config by hand. The watchdog does this by itself when the primary keeps failing."
    local id act other a
    pick_managed id "tunnel gateway" || return 0
    act=$(cexec "$id" cat /etc/vpnguard/active-slot 2>/dev/null); act=${act:-primary}
    cexec "$id" test -f /etc/vpnguard/slots/backup.conf || { warn "CT $id has no backup config (add one with the setup)"; pause; return 0; }
    [ "$act" = primary ] && other=backup || other=primary
    echo
    note "CT $id is using its $act config"
    yn a "Switch to the $other config?" y || return 0
    [ "$a" = y ] || return 0
    run_task "switching CT $id to $other" cexec "$id" /usr/local/sbin/vpnguard-switch "$other" \
        && notify "$(reg_get "$id" NAME): switched to $other" "Switched by hand from the vpn-lxc menu." 2 repeat
    pause
}

library_screen() {
    while true; do
        FLOW="config library"; PAGE_TOTAL=0; CONTEXT=""
        page "Config library" "Saved VPN configs on this host ($LIB, root-only). Pick one during setup instead of pasting again."
        local n any=0
        box_top "Saved configs"
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            any=1
            box_row "$(printf '%s%-24.24s%s %-9s %-8s %s%-15s %s%s' "$B" "$n" "$R" "$(lib_meta "$n" KIND)" "$(provider_label "$(lib_meta "$n" PROVIDER)" | cut -d' ' -f1)" "$GR" "$(lib_meta "$n" ENDPOINTS | awk '{print $1}' | cut -d: -f1)" "$(lib_meta "$n" ADDED | cut -d' ' -f1)" "$R")"
        done < <(lib_names)
        [ "$any" = 0 ] && box_row "${GR}empty${R}"
        box_bot
        echo
        local a
        pick a "What now?" back "add|Add a config|paste it or point to a file" "delete|Delete one|" "back|Back|" || return 0
        case $a in
            add) library_add || [ $? != 2 ] || return 0 ;;
            delete)
                local -a items=()
                while IFS= read -r n; do [ -n "$n" ] && items+=("$n|$n|$(lib_meta "$n" KIND)"); done < <(lib_names)
                [ ${#items[@]} -gt 0 ] || continue
                local del sure
                echo; pick del "Delete which?" "" "${items[@]}" || continue
                yn sure "Delete $del for good?" n || continue
                [ "$sure" = y ] && lib_delete "$del" && ok "deleted $del" && nap 0.6 ;;
            back) return 0 ;;
        esac
    done
}

library_add() {
    new_stage
    local t=lib how f="$STAGE/lib-new.conf" p user="" pass="" name path
    page "Add to the library"
    pick how "How?" paste "paste|Paste it|" "file|A file on this host|" || return
    if [ "$how" = paste ]; then echo; paste_block "$f.raw" || return 1; tr -d '\r' < "$f.raw" > "$f"
    else echo; field path "Path" "" v_path || return; tr -d '\r' < "$path" > "$f"; fi
    analyze_config lib primary "$f" || { bad "$VERR"; pause; return 1; }
    echo; config_card lib primary; echo
    pick p "Provider" proton "mullvad|Mullvad|" "proton|Proton VPN|" "airvpn|AirVPN|" "other|Other|" || return
    if [ "${V[lib.primary.auth]}" = 1 ]; then
        field user "OpenVPN username" "" v_req || return
        secret pass "OpenVPN password"
    fi
    field name "Name" "$p-$(echo "${V[lib.primary.endpoints]}" | awk '{print $1}' | cut -d: -f1 | tr . -)" v_name || return
    lib_save "$name" "$f" "${V[lib.primary.kind]}" "$p" "${V[lib.primary.endpoints]}" "$user" "$pass"
    ok "saved as $name"
    if [ "$how" = file ]; then
        local del; yn del "Delete $path now? (the library has a copy)" y && [ "$del" = y ] && rm -f "$path" && ok "deleted $path"
    fi
    pause
}

settings_screen() {
    while true; do
        FLOW="watchdog & notifications"; PAGE_TOTAL=0; CONTEXT=""
        page "Watchdog & notifications" "Every 2 minutes this host checks each tunnel. When one stops working it restarts it, then switches to the backup config if there is one, and tells you."
        local wd ra fa nk timer
        wd=$(set_get WATCHDOG); wd=${wd:-1}
        ra=$(set_get WD_RESTART_AFTER); ra=${ra:-2}
        fa=$(set_get WD_FAILOVER_AFTER); fa=${fa:-4}
        nk=$(set_get NOTIFY_KIND); nk=${nk:-none}
        timer="${ER}not installed${R}"
        systemctl is-active --quiet vpn-lxc-watchdog.timer 2>/dev/null && timer="${OK}running${R}"
        box_top "Now"
        box_row "${GR}Watchdog${R}         $([ "$wd" = 1 ] && echo "${OK}on${R}" || echo "${ER}off${R}") · timer $timer"
        box_row "${GR}Restart after${R}    $ra failed checks ($((ra * 2)) min)"
        box_row "${GR}Failover after${R}   $fa failed checks ($((fa * 2)) min), if a backup config exists"
        box_row "${GR}Notifications${R}    $nk $(set_get NOTIFY_URL)$([ "$nk" = ntfy ] && echo "/$(set_get NOTIFY_TOPIC)")"
        box_bot
        echo
        local a
        pick a "Change" back \
            "toggle|Watchdog on/off|" \
            "timing|Restart / failover timing|" \
            "notify|Notifications|ntfy or Gotify" \
            "test|Send a test notification|" \
            "library|Saved VPN configs|add, list or delete" \
            "back|Back|" || return 0
        case $a in
            toggle)
                if [ "$wd" = 1 ]; then
                    set_set WATCHDOG 0; systemctl disable --now vpn-lxc-watchdog.timer >/dev/null 2>&1; ok "watchdog off"
                else
                    set_set WATCHDOG 1; run_task "installing the watchdog timer" install_watchdog
                fi
                nap 0.8 ;;
            timing)
                local x y
                field x "Restart the tunnel after how many failed checks" "$ra" v_port || continue
                field y "Switch to the backup after how many failed checks" "$fa" v_port || continue
                [ "$y" -gt "$x" ] || { bad "failover has to come after the restart"; pause; continue; }
                set_set WD_RESTART_AFTER "$x"; set_set WD_FAILOVER_AFTER "$y" ;;
            notify)
                local nkind url topic token
                echo
                pick nkind "Send notifications with" "$nk" \
                    "none|Nothing|" \
                    "ntfy|ntfy|ntfy.sh or your own ntfy server" \
                    "gotify|Gotify|your Gotify server" || continue
                case $nkind in
                    ntfy)
                        field url "ntfy server" "$(set_get NOTIFY_URL | grep . || echo https://ntfy.sh)" v_url || continue
                        [ -z "$url" ] && url=https://ntfy.sh
                        set_set NOTIFY_KIND ntfy
                        field topic "Topic (long and random if you use ntfy.sh)" "$(set_get NOTIFY_TOPIC | grep . || echo "vpn-lxc-$(tr -dc a-z0-9 < /dev/urandom | head -c 10)")" v_name || continue
                        secret token "Access token (optional, ⏎ to skip)"
                        set_set NOTIFY_URL "$url"; set_set NOTIFY_TOPIC "$topic"; set_set NOTIFY_TOKEN "$token"
                        note "subscribe to $topic in the ntfy app" ;;
                    gotify)
                        field url "Gotify server" "$(set_get NOTIFY_URL)" v_url || continue
                        secret token "Application token"
                        set_set NOTIFY_KIND gotify; set_set NOTIFY_URL "$url"; set_set NOTIFY_TOKEN "$token" ;;
                    none) set_set NOTIFY_KIND none ;;
                esac
                pause ;;
            test)
                if [ "$nk" = none ]; then warn "notifications are off: pick ntfy or Gotify first"
                elif run_task "sending a test" notify "vpn-lxc test" "Notifications from $(hostname) work." 3 white_check_mark; then ok "check your phone"
                else bad "it didn't go through: check the server, topic and token"; fi
                pause ;;
            library) library_screen ;;
            back) return 0 ;;
        esac
    done
}

remove_screen() {
    FLOW="remove"; PAGE_TOTAL=0; CONTEXT=""
    page "Remove or detach" "Take the VPN off a container, move one out from behind the gateway, or take the gateway down."
    local id role a restore stop
    pick_managed id "tunnel gateway client" || return 0
    role=$(reg_get "$id" ROLE)
    new_stage; write_payload "$STAGE/payload"
    echo
    case $role in
        tunnel)
            warn "CT $id loses its kill switch: if the tunnel drops, traffic goes out unprotected"
            yn restore "Put back the iptables rules it had before the first setup?" y || return 0
            yn stop "Stop its VPN tunnel too?" n || return 0
            yn a "Remove now?" n || return 0
            [ "$a" = y ] || return 0
            cpush "$id" "$STAGE/payload/remove.sh" /tmp/vpnguard-remove.sh 700
            cexec "$id" bash /tmp/vpnguard-remove.sh "$([ "$restore" = y ] && echo 1 || echo 0)" "$([ "$stop" = y ] && echo 1 || echo 0)" 2>&1 | render_stream
            local ons; ons=$(reg_get "$id" ORIG_NS)
            pct set "$id" --revert nameserver >/dev/null 2>&1   # a running container keeps our change as "pending"
            if [ -n "$ons" ]; then pct set "$id" --nameserver "$ons" >/dev/null 2>&1
            else pct set "$id" --delete nameserver >/dev/null 2>&1; fi
            reg_del "$id"; ok "done · the container's own DNS setting is back" ;;
        client)
            yn a "Move CT $id back to the network it had before?" y || return 0
            [ "$a" = y ] && run_task "moving CT $id back" client_detach "$id" ;;
        gateway)
            local c clients=""
            for c in $(reg_ids); do [ "$(reg_get "$c" ROLE)" = client ] && [ "$(reg_get "$c" GATEWAY)" = "$id" ] && clients="$clients $c"; done
            [ -n "$clients" ] && warn "these move back to their old networks first:$clients"
            local destroy br
            yn destroy "Also delete the gateway container CT $id?" n || return 0
            br=$(reg_get "$id" BRIDGE)
            yn a "Take the gateway down now?" n || return 0
            [ "$a" = y ] || return 0
            for c in $clients; do run_task "moving CT $c back" client_detach "$c"; done
            if [ "$destroy" = y ]; then
                run_task "deleting CT $id" bash -c "pct stop $id >/dev/null 2>&1; pct destroy $id --purge"
                local rmbr
                yn rmbr "Remove the bridge $br from this host too?" y || true
                [ "${rmbr:-n}" = y ] && run_task "removing bridge $br" remove_bridge "$br"
            else
                cpush "$id" "$STAGE/payload/remove.sh" /tmp/vpnguard-remove.sh 700
                cexec "$id" bash /tmp/vpnguard-remove.sh 0 1 2>&1 | render_stream
            fi
            reg_del "$id" ;;
    esac
    pause
}

remove_bridge() {
    local br=$1 tmp
    cp -a "$IFACES_FILE" "$IFACES_FILE.vpn-lxc.$(date +%Y%m%d-%H%M%S)"
    tmp=$(mktemp)
    awk -v br="$br" '
        $1 == "auto" && $2 == br { skip = 1; if (held > 0) held--; next }   # also drops the blank line we added in front of it
        skip && /^#VPN-only network \(vpn-lxc.sh\)/ { skip = 0; next }
        skip && ($0 ~ /^iface / || $0 ~ /^[ \t]/ || $0 == "") { next }
        $0 == "" { held++; next }
        { skip = 0; while (held > 0) { print ""; held-- } print }
        END { while (held > 0) { print ""; held-- } }' "$IFACES_FILE" > "$tmp" && cat "$tmp" > "$IFACES_FILE"
    rm -f "$tmp"
    # let ifupdown2 take the bridge down itself: deleting the link first leaves it with a stale state and every later ifreload fails
    ifreload -a
    ip link show "$br" >/dev/null 2>&1 && ip link delete "$br"
    return 0
}

# ════════════════════════════════════════════════════════════
#  Watchdog (runs from the systemd timer, no screen)
# ════════════════════════════════════════════════════════════
watchdog_round() {
    [ "$(set_get WATCHDOG)" = 0 ] && return 0
    local ra fa id role out sf fails down lastpf name
    ra=$(set_get WD_RESTART_AFTER); ra=${ra:-2}
    fa=$(set_get WD_FAILOVER_AFTER); fa=${fa:-4}
    install -d -m 700 "$VARD"
    for id in $(reg_ids); do
        role=$(reg_get "$id" ROLE)
        case $role in tunnel|gateway) ;; *) continue ;; esac
        [ "$(ct_status "$id")" = running ] || continue
        name=$(reg_get "$id" NAME); name=${name:-CT $id}
        out=$(timeout 60 pct exec "$id" -- /usr/local/sbin/vpn-status --health 2>/dev/null)
        [ -n "$out" ] || { echo "CT $id: no answer from vpn-status"; continue; }
        local -A H=()
        read_kv_into H "" <<<"$out"
        sf="$VARD/$id.state"
        fails=$(kvfile_get "$sf" FAILS); fails=${fails:-0}
        down=$(kvfile_get "$sf" DOWN); down=${down:-0}
        lastpf=$(kvfile_get "$sf" LAST_PF)
        if [ "${H[HEALTH]:-}" = ok ]; then
            if [ "$down" = 1 ]; then
                echo "CT $id: healthy again (${H[ACTIVE]} config)"
                notify "$name: VPN is back" "The tunnel works again, on the ${H[ACTIVE]} config." 3 white_check_mark
            fi
            fails=0; down=0
            if [ -n "${H[APPS_DOWN]:-}" ]; then
                echo "CT $id: starting ${H[APPS_DOWN]}"
                # shellcheck disable=SC2086
                pct exec "$id" -- systemctl start ${H[APPS_DOWN]}
            fi
            if [ -n "${H[PF_PORT]:-}" ]; then
                if [ -n "$lastpf" ] && [ "${H[PF_PORT]}" != "$lastpf" ]; then
                    echo "CT $id: forwarded port $lastpf → ${H[PF_PORT]}"
                    notify "$name: new forwarded port" "The VPN gave a new port: ${H[PF_PORT]} (was $lastpf). qBittorrent is updated automatically if it's synced." 2 arrows_counterclockwise
                fi
                lastpf=${H[PF_PORT]}
            fi
        else
            fails=$((fails + 1))
            echo "CT $id: unhealthy ($fails): ${H[REASON]:-?}"
            if [ "$fails" -eq "$ra" ]; then
                down=1
                notify "$name: VPN down" "${H[REASON]:-The tunnel stopped working}. Restarting it. Nothing leaks: the kill switch keeps traffic blocked." 4 warning
                pct exec "$id" -- systemctl restart "${H[UNIT]}"
            elif [ "$fails" -ge "$fa" ] && [ "${H[HAS_BACKUP]:-0}" = 1 ] && [ "${H[ACTIVE]:-primary}" = primary ]; then
                notify "$name: switching to the backup config" "The primary config still fails (${H[REASON]:-?}) after a restart." 4 repeat
                pct exec "$id" -- /usr/local/sbin/vpnguard-switch backup
                fails=0
            elif [ "$fails" -gt "$ra" ] && [ $(( (fails - ra) % ra )) -eq 0 ]; then
                pct exec "$id" -- systemctl restart "${H[UNIT]}"
            fi
        fi
        { echo "FAILS=$fails"; echo "DOWN=$down"; echo "LAST_PF=$lastpf"; echo "CHECKED=$(date +%s)"; } > "$sf"
        unset H
    done
}

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

# vpn-lxc update [--check] [ref] : fetch the latest release, verify its checksum, install it
update_self() {
    local check=0 ref=main tmp want have newv oldv dest=/usr/local/sbin/vpn-lxc
    for a in "$@"; do case $a in --check) check=1 ;; *) ref=$a ;; esac; done
    command -v curl >/dev/null 2>&1 || die "curl is needed"
    tmp=$(mktemp -d) || die "could not create a temp dir"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN
    # a changing query string keeps GitHub's cache from handing out an older copy
    local bust; bust="?t=$(date +%s)"
    curl -fsSL -m 60 "$REPO_RAW/$ref/dist/vpn-lxc.sh$bust" -o "$tmp/s" || die "could not download the latest version (no internet, or no such version: $ref)"
    curl -fsSL -m 30 "$REPO_RAW/$ref/dist/vpn-lxc.sh.sha256$bust" -o "$tmp/s.sha" || die "could not download the checksum"
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

