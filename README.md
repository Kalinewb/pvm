# vpn-lxc

Put Proxmox containers behind a VPN with a kill switch, from a simple dashboard and menu.
WireGuard or OpenVPN, any provider (Mullvad, Proton, AirVPN, others). Set it up once; it keeps itself working.

## Install

Run on the Proxmox host as root:

```bash
curl -fsSL https://raw.githubusercontent.com/Kalinewb/vpn-lxc/main/install.sh | bash
```

Then start it with:

```bash
vpn-lxc
```

The installer downloads one file, checks its SHA-256 against `dist/vpn-lxc.sh.sha256`, and puts it at `/usr/local/sbin/vpn-lxc`.
To remove it: `curl -fsSL https://raw.githubusercontent.com/Kalinewb/vpn-lxc/main/install.sh | bash -s -- --uninstall`.
Prefer to read it first? The whole tool is [`dist/vpn-lxc.sh`](dist/vpn-lxc.sh).

Requirements: Proxmox VE (developed and tested on 9.x), containers running Debian or Ubuntu, a WireGuard or OpenVPN config from your provider.

## Use

    vpn-lxc              dashboard + menu (arrow keys, Enter; b = back, q = quit)
    vpn-lxc dashboard    print the dashboard once
    vpn-lxc live         auto-refreshing dashboard
    vpn-lxc status 126   full leak / kill-switch check of one container
    vpn-lxc switch 126 backup
    vpn-lxc watchdog     one watchdog round (a systemd timer runs this every 2 minutes)

## Two modes

* **Protect containers** – each container runs its own tunnel and kill switch.
* **VPN gateway** – one small container holds the tunnel; containers plugged into its private bridge go through it.

Both ask **Express** (default: only the VPN config is asked for) or **Custom**.

## Defaults

* Your home network is never behind the VPN: full access both ways. DNS to the LAN (53/853) is blocked so lookups can't leak around the tunnel.
* Everything else leaves only through the tunnel. IPv6 is blocked.
* The kill switch loads before the network, survives reboots, and the watchdog restarts / fails over to a backup config and notifies (ntfy / Gotify).
* Apps (qBittorrent, *arr, ...) are tied to the tunnel: they stop with it and start with it.
* Proton NAT-PMP forwarded ports are kept alive and pushed into qBittorrent.

## Layout

    src/*.sh           host-side code, in load order
    src/payload/       scripts and units that run inside the containers
    build.sh           joins everything into dist/vpn-lxc.sh (the file you copy to the host)
    check.sh           syntax + ShellCheck + build
    tests/unit.sh      function-level tests (run on the Proxmox host so nft can check the firewalls)
    tests/drive.py     drives the full-screen app in a pseudo terminal (keys, typed lines)
    tests/fake-*.py    stand-ins for ntfy/Gotify and the qBittorrent WebUI

Edit `src/`, never `dist/`. Run `./check.sh && bash tests/unit.sh dist/vpn-lxc.sh`.
