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
    GR=$'\e[38;5;244m'; DG=$'\e[38;5;238m'; WH=$'\e[38;5;255m'
    CHIPBG=$'\e[48;5;236m'
else
    R=""; B=""; DIM=""; IT=""; CY=""; VI=""; PK=""; OK=""; ER=""; WA=""; GR=""; DG=""; WH=""; CHIPBG=""
    ANIM=0
fi

# The layout follows the terminal: re-read the size whenever a screen is drawn, so a resize shows on the next screen.
fit() {
    COLS=$(tput cols 2>/dev/null || echo 80)
    [[ $COLS =~ ^[0-9]+$ ]] || COLS=80
    W=$((COLS - 4)); [ "$W" -gt 160 ] && W=160; [ "$W" -lt 50 ] && W=50
}
fit

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
    if [ -n "$CONTEXT" ]; then
        n=$((W - $(vislen "$CONTEXT") - $(vislen "$keys")))
        [ "$n" -lt 1 ] && n=1
        printf '  %s%*s%s\n' "$CONTEXT" "$n" "" "$keys"
    elif [ "$PAGE_TOTAL" -gt 0 ]; then
        n=$((W - $(vislen "$keys")))
        printf '  %*s%s\n' "$n" "" "$keys"
    fi
    echo
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
                printf '    %s%s%s%s○%s %s %s%s%s\n' "$CY" "$(num $((i + 1)))" "$R" "$DG" "$R" "$(padr "${labels[i]}" 24)" "$DG" "${descs[i]}" "$R"
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
    printf '    %s›%s %s  %s↑↓ move · ⏎ choose · b back · q quit%s\n' "$CY" "$R" "$__q" "$GR" "$R"
    cur_hide
    local first=1
    while true; do
        [ "$first" = 1 ] || printf '\e[%dA\e[J' "$((drawn - 1))"
        first=0
        for ((i = top; i < top + vis; i++)); do
            if [ "$i" = "$cur" ]; then
                printf '  %s❯%s %s%s%s%s%s%s %s%s%s\n' "$PK" "$R" "$CY" "$(num $((i + 1)))" "$R" "$B$WH" "$(padr "${labels[i]}" 22)" "$R" "$GR" "${descs[i]}" "$R"
            else
                printf '    %s%s%s%s %s%s%s\n' "$CY" "$(num $((i + 1)))" "$R" "$(padr "${labels[i]}" 22)" "$DG" "${descs[i]}" "$R"
            fi
            [ "$gap" = 1 ] && printf '\n'
        done
        if [ "$n" -gt "$vis" ]; then printf '    %s%s of %s%s\n' "$DG" "$((cur + 1))" "$n" "$R"; else printf '\n'; fi
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
    printf '    %s›%s %s  %s↑↓ move · space tick · a all · n none · ⏎ done · b back · q quit%s\n' "$CY" "$R" "$__q" "$GR" "$R"
    cur_hide
    local first=1 mark
    while true; do
        [ "$first" = 1 ] || printf '\e[%dA\e[J' "$((drawn - 1))"
        first=0
        for ((i = top; i < top + vis; i++)); do
            if [ "${state[i]}" = 1 ]; then mark="${OK}◉${R}"; else mark="${DG}○${R}"; fi
            if [ "$i" = "$cur" ]; then
                printf '  %s❯%s %s%s%s %s %s%s%s %s%s%s\n' "$PK" "$R" "$CY" "$(num $((i + 1)))" "$R" "$mark" "$B$WH" "$(padr "${labels[i]}" 24)" "$R" "$GR" "${descs[i]}" "$R"
            else
                printf '    %s%s%s %s %s %s%s%s\n' "$CY" "$(num $((i + 1)))" "$R" "$mark" "$(padr "${labels[i]}" 24)" "$DG" "${descs[i]}" "$R"
            fi
        done
        if [ "$n" -gt "$vis" ]; then printf '    %s%s of %s%s\n' "$DG" "$((cur + 1))" "$n" "$R"; else printf '\n'; fi
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

