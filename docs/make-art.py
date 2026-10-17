#!/usr/bin/env python3
"""Generates the README pictures (docs/*.svg) and docs/social-preview.png.
Everything shown is sample data: documentation IP ranges, made-up container names.
    python3 docs/make-art.py        (the PNG needs rsvg-convert)"""
import html
import os
import subprocess

OUT = os.path.dirname(os.path.abspath(__file__))
FONT = "ui-monospace, 'JetBrains Mono', 'DejaVu Sans Mono', 'Liberation Mono', Menlo, Consolas, monospace"
SANS = "-apple-system, 'Segoe UI', 'Helvetica Neue', Arial, sans-serif"
BG, PANEL, LINE = "#0d1117", "#161b22", "#30363d"
C = dict(cy="#5fd7ff", vi="#af87ff", pk="#ff87d7", ok="#5fff87", er="#ff5f5f", wa="#ffd75f",
         gr="#8b949e", dg="#484f58", wh="#e6edf3")


def esc(s):
    return html.escape(s, quote=False)


def write(name, svg):
    with open(os.path.join(OUT, name), "w") as f:
        f.write(svg)


def terminal(name, title, lines, width=980, size=15, pad=22):
    """lines: list of lines; a line is a list of (text, colour-key[, bold]) pieces."""
    lh = int(size * 1.45)
    height = 46 + pad * 2 + lh * len(lines)
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
           f'<rect width="{width}" height="{height}" rx="12" fill="{PANEL}" stroke="{LINE}"/>',
           f'<path d="M0 12a12 12 0 0 1 12-12h{width - 24}a12 12 0 0 1 12 12v22H0z" fill="#21262d"/>',
           '<circle cx="24" cy="17" r="6" fill="#ff5f56"/><circle cx="46" cy="17" r="6" fill="#ffbd2e"/><circle cx="68" cy="17" r="6" fill="#27c93f"/>',
           f'<text x="{width // 2}" y="22" text-anchor="middle" font-family="{SANS}" font-size="13" fill="{C["gr"]}">{esc(title)}</text>']
    y = 46 + pad
    for line in lines:
        spans = "".join(
            f'<tspan fill="{C.get(p[1], p[1])}"{" font-weight=\"700\"" if len(p) > 2 and p[2] else ""}>{esc(p[0])}</tspan>'
            for p in line)
        out.append(f'<text x="{pad}" y="{y}" font-family="{FONT}" font-size="{size}" xml:space="preserve">{spans}</text>')
        y += lh
    out.append("</svg>")
    write(name, "\n".join(out))


def box(rows, title, w):
    """open-sided box (no right edge: symbol widths differ between fonts, so a right edge would wobble)"""
    top = [("╭─ ", "dg"), (title, "wh", True), (" " + "─" * (w - len(title) - 2), "dg")]
    body = [[("│ ", "dg")] + r for r in rows]
    bot = [("╰" + "─" * (w + 1), "dg")]
    return [top] + body + [bot]


# ───────────────────────── dashboard ─────────────────────────
def dash():
    G = lambda s: (s, "gr")
    rows = [
        [("● ", "ok"), ("141  ", "wh"), ("media        ", "wh", True), ("gateway  ", "gr"), ("Proton · wg   ", "wh"), ("198.51.100.21 SE ", "wh"), ("⇅51820 ", "cy"), ("18s", "dg")],
        [G("  └ "), ("● ", "ok"), ("142  jellyfin     10.10.10.10   ", "wh"), ("via gateway", "ok")],
        [G("  └ "), ("● ", "ok"), ("143  sonarr       10.10.10.11   ", "wh"), ("via gateway", "ok")],
        [G("  └ "), ("● ", "ok"), ("144  radarr       10.10.10.12   ", "wh"), ("via gateway", "ok")],
        [G("  └ "), ("● ", "ok"), ("145  prowlarr     10.10.10.13   ", "wh"), ("via gateway", "ok")],
        [("● ", "ok"), ("150  ", "wh"), ("private      ", "wh", True), ("gateway  ", "gr"), ("Mullvad · wg  ", "wh"), ("203.0.113.40 CH ", "wh"), ("      ", "wh"), ("9s", "dg")],
        [G("  └ "), ("● ", "ok"), ("151  notes        10.10.11.10   ", "wh"), ("via gateway", "ok")],
        [("● ", "ok"), ("160  ", "wh"), ("downloads    ", "wh", True), ("gateway  ", "gr"), ("Proton · wg   ", "wh"), ("192.0.2.77 NL    ", "wh"), ("⇅41337 ", "cy"), ("31s", "dg")],
        [G("  └ "), ("● ", "ok"), ("161  qbittorrent  10.10.12.10   ", "wh"), ("via gateway", "ok")],
        [("─" * 70, "dg")],
        [("✓ 9 protected", "ok")],
        [("watchdog ", "gr"), ("on", "ok"), ("   notifications ", "gr"), ("ntfy", "wh"), ("   library ", "gr"), ("3 configs", "wh")],
    ]
    lines = [[("", "wh")]] + box(rows, "Your containers", 76) + [[("", "wh")]] + [
        [("  › ", "cy"), ("What now?  ", "wh"), ("↑↓ move · ⏎ choose · b back · q quit", "dg")],
        [("  ❯ ", "pk"), ("①  VPN gateways         ", "wh", True), ("named gateways: one VPN for many containers", "gr")],
        [("    ②  Port forwarding       ", "wh"), ("what the VPN forwards in, and what your home can reach", "gr")],
        [("    ③  Live dashboard        ", "wh"), ("auto-refreshing view of everything", "gr")],
        [("    ④  Check a container     ", "wh"), ("full leak and kill-switch test", "gr")],
    ]
    terminal("dashboard.svg", "pvm · dashboard", lines, width=1020)


# ───────────────────────── express setup ─────────────────────────
def express():
    lines = [
        [("  ◆ PVM  v3.0.4", "pk", True), ("                                                  VPN gateways", "gr")],
        [("  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "cy")],
        [("", "wh")],
        [("  ▍ ", "vi"), ("New VPN gateway", "wh", True)],
        [("    A small container becomes a VPN router. Every container you plug into", "gr")],
        [("    its private bridge goes through the VPN, with the kill switch outside", "gr")],
        [("    the apps, so nothing inside them can route around it.", "gr")],
        [("", "wh")],
        [("    › ", "cy"), ("How much do you want to decide?", "wh"), ("  ↑↓ move · ⏎ choose", "dg")],
        [("  ❯ ", "pk"), ("①  Express (recommended)  ", "wh", True), ("only asks for the gateway's address and the VPN config", "gr")],
        [("    ②  Custom                 ", "wh"), ("choose the bridge, network, ports and storage yourself", "gr")],
        [("", "wh")],
        [("    ✓ ", "ok"), ("Name: ", "gr"), ("downloads", "wh"), ("      ✓ ", "ok"), ("Address: ", "gr"), ("192.168.1.250/24", "wh")],
        [("    ✓ ", "ok"), ("Config: ", "gr"), ("proton-nl-12 (WireGuard)", "wh"), ("      ✓ ", "ok"), ("Containers: ", "gr"), ("161 qbittorrent", "wh")],
        [("    ✓ ", "ok"), ("kill switch firewall active (default-deny)", "wh")],
        [("    ✓ ", "ok"), ("tunnel up, DNS answers through it", "wh")],
        [("    ✓ ", "ok"), ("forwarded port from the VPN: ", "wh"), ("41337", "cy", True)],
    ]
    terminal("express.svg", "pvm · Express setup", lines, width=960)


# ───────────────────────── architecture ─────────────────────────
def architecture():
    w, h = 1100, 640
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" font-family="{SANS}">',
         f'<rect width="{w}" height="{h}" rx="14" fill="{BG}" stroke="{LINE}"/>',
         '<defs><linearGradient id="g" x1="0" x2="1"><stop offset="0" stop-color="#5fd7ff"/><stop offset="0.5" stop-color="#af87ff"/><stop offset="1" stop-color="#ff87d7"/></linearGradient>',
         '<marker id="a" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="#8b949e"/></marker></defs>']

    def text(x, y, t, size=15, fill=C["wh"], anchor="middle", weight="400", mono=False):
        fam = FONT if mono else SANS
        s.append(f'<text x="{x}" y="{y}" font-family="{fam}" font-size="{size}" fill="{fill}" text-anchor="{anchor}" font-weight="{weight}">{esc(t)}</text>')

    text(w // 2, 40, "How it fits together", 22, weight="700")
    # internet / VPN providers
    s.append(f'<rect x="60" y="64" width="980" height="56" rx="10" fill="{PANEL}" stroke="{LINE}"/>')
    text(w // 2, 98, "Internet  ·  VPN providers (WireGuard / OpenVPN)", 16, C["gr"])
    cols = [(220, "media", "Proton", "#5fd7ff", ["jellyfin", "sonarr", "radarr", "prowlarr"]),
            (550, "private", "Mullvad", "#af87ff", ["notes"]),
            (880, "downloads", "Proton", "#ff87d7", ["qbittorrent"])]
    for x, name, prov, col, kids in cols:
        # tunnel
        s.append(f'<line x1="{x}" y1="120" x2="{x}" y2="190" stroke="{col}" stroke-width="3" stroke-dasharray="2 7" stroke-linecap="round"/>')
        text(x + 12, 160, "encrypted tunnel", 12, col, "start")
        # gateway box
        s.append(f'<rect x="{x - 110}" y="190" width="220" height="78" rx="12" fill="{PANEL}" stroke="{col}" stroke-width="2"/>')
        text(x, 220, f"gateway “{name}”", 16, C["wh"], weight="700")
        text(x, 242, f"{prov} · kill switch · NAT", 12, C["gr"])
        text(x, 258, "own bridge + network", 12, C["gr"])
        # containers
        n = len(kids)
        cw = 82
        total = n * cw + (n - 1) * 8
        x0 = x - total / 2
        s.append(f'<line x1="{x}" y1="268" x2="{x}" y2="312" stroke="{col}" stroke-width="2"/>')
        s.append(f'<line x1="{x0 + cw / 2}" y1="312" x2="{x0 + total - cw / 2}" y2="312" stroke="{col}" stroke-width="2"/>')
        for i, k in enumerate(kids):
            cx = x0 + i * (cw + 8)
            s.append(f'<line x1="{cx + cw / 2}" y1="312" x2="{cx + cw / 2}" y2="330" stroke="{col}" stroke-width="2"/>')
            s.append(f'<rect x="{cx}" y="330" width="{cw}" height="46" rx="8" fill="{PANEL}" stroke="{LINE}"/>')
            text(cx + cw / 2, 358, k, 13, C["wh"])
    text(550, 410, "Everything inside a gateway reaches the internet only through its tunnel. If the tunnel drops, it goes dark instead of leaking.", 13, C["gr"])

    # home network
    s.append(f'<rect x="60" y="450" width="980" height="130" rx="12" fill="{PANEL}" stroke="{C["ok"]}" stroke-width="2"/>')
    text(w // 2, 484, "Your home network", 18, C["ok"], weight="700")
    items = ["NAS", "router", "Home Assistant", "other containers", "your PC"]
    for i, it in enumerate(items):
        x = 100 + i * 185
        s.append(f'<rect x="{x}" y="504" width="160" height="40" rx="8" fill="{BG}" stroke="{LINE}"/>')
        text(x + 80, 529, it, 13)
    text(w // 2, 570, "reachable from every gateway, both ways, with no extra setup", 13, C["gr"])
    for x in (220, 550, 880):
        s.append(f'<line x1="{x}" y1="416" x2="{x}" y2="450" stroke="{C["ok"]}" stroke-width="2" marker-end="url(#a)" marker-start="url(#a)" stroke-dasharray="5 5"/>')
    s.append("</svg>")
    write("architecture.svg", "\n".join(s))


# ───────────────────────── hero / social preview ─────────────────────────
def hero():
    w, h = 1280, 640
    chips = ["WireGuard · OpenVPN", "kill switch", "named gateways", "port forwarding", "watchdog + failover", "pvm or vpn, any capitals"]
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" font-family="{SANS}">',
         '<defs><linearGradient id="g" x1="0" x2="1"><stop offset="0" stop-color="#5fd7ff"/><stop offset="0.5" stop-color="#af87ff"/><stop offset="1" stop-color="#ff87d7"/></linearGradient>',
         '<radialGradient id="glow" cx="0.2" cy="0.1" r="0.9"><stop offset="0" stop-color="#1f3a5f" stop-opacity="0.8"/><stop offset="1" stop-color="#0d1117" stop-opacity="0"/></radialGradient>',
         '<radialGradient id="glow2" cx="0.95" cy="1" r="0.8"><stop offset="0" stop-color="#4a2a5f" stop-opacity="0.7"/><stop offset="1" stop-color="#0d1117" stop-opacity="0"/></radialGradient></defs>',
         f'<rect width="{w}" height="{h}" fill="{BG}"/><rect width="{w}" height="{h}" fill="url(#glow)"/><rect width="{w}" height="{h}" fill="url(#glow2)"/>']
    # shield-ish emblem
    s.append('<g transform="translate(110,120)"><path d="M70 0 L140 26 V84 C140 130 108 160 70 176 C32 160 0 130 0 84 V26 Z" fill="none" stroke="url(#g)" stroke-width="7" stroke-linejoin="round"/>'
             '<path d="M44 84 L64 106 L100 62" fill="none" stroke="url(#g)" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/></g>')
    s.append(f'<text x="290" y="205" font-family="{FONT}" font-size="104" font-weight="800" fill="url(#g)">PVM</text>')
    s.append(f'<text x="294" y="262" font-size="34" fill="{C["wh"]}" font-weight="600">Proxmox VPN Manager</text>')
    s.append(f'<text x="294" y="306" font-size="21" fill="{C["gr"]}">A VPN dashboard for your containers. Kill switch included. Set it up once, it keeps itself working.</text>')
    x, y = 110, 372
    for c in chips:
        wd = 26 + len(c) * 12.2
        if x + wd > w - 90:
            x, y = 110, y + 58
        s.append(f'<rect x="{x}" y="{y}" width="{wd}" height="42" rx="21" fill="{PANEL}" stroke="{LINE}"/>')
        s.append(f'<text x="{x + wd / 2}" y="{y + 27}" text-anchor="middle" font-size="18" fill="{C["wh"]}">{esc(c)}</text>')
        x += wd + 14
    s.append(f'<rect x="110" y="520" width="1060" height="62" rx="12" fill="{PANEL}" stroke="{LINE}"/>')
    s.append(f'<text x="136" y="559" font-family="{FONT}" font-size="21" fill="{C["ok"]}">$</text>')
    s.append(f'<text x="164" y="559" font-family="{FONT}" font-size="19" fill="{C["wh"]}">curl -fsSL https://raw.githubusercontent.com/Kalinewb/pvm/main/install.sh | bash</text>')
    s.append("</svg>")
    write("hero.svg", "\n".join(s))


if __name__ == "__main__":
    dash()
    express()
    architecture()
    hero()
    try:
        subprocess.run(["rsvg-convert", "-w", "1280", os.path.join(OUT, "hero.svg"), "-o", os.path.join(OUT, "social-preview.png")], check=True)
        print("wrote social-preview.png")
    except Exception as e:  # noqa: BLE001
        print("no PNG:", e)
    print("wrote", ", ".join(n for n in sorted(os.listdir(OUT)) if n.endswith(".svg")))
