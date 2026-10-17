#!/usr/bin/env python3
"""Drive PVM in a pseudo terminal and print what each step shows.
usage: drive.py COLS ROWS [-s script] ITEM...
  ITEM  <up> <down> <left> <right> <enter> <space> <esc> <tab>   one key, no newline
        ~text                                                    typed characters, no newline
        anything else                                            typed as a line + Enter
Env: LAST=seconds to keep reading after the final item, IDLE=idle seconds that end a read, FULL=1 print whole screens"""
import pty, os, sys, time, fcntl, termios, struct, select, re
args = sys.argv[1:]
cols, rows = int(args.pop(0)), int(args.pop(0))
script = "/root/vpn.sh"
if args and args[0] == "-s": args.pop(0); script = args.pop(0)
KEYS = {"<up>":"\x1b[A","<down>":"\x1b[B","<right>":"\x1b[C","<left>":"\x1b[D","<enter>":"\r","<space>":" ","<esc>":"\x1b","<tab>":"\t","<home>":"\x1b[H","<end>":"\x1b[F"}
idle = float(os.environ.get("IDLE", "1.5"))
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(TERM="xterm-256color", COLORTERM="truecolor", PVM_ANIM="0", COLUMNS=str(cols), LINES=str(rows))
    os.execvp("bash", ["bash", script])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
def drain(t):
    out = b""; end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try: d = os.read(fd, 65536)
            except OSError: return out, True
            if not d: return out, True
            out += d; end = time.time() + idle
    return out, False
screens = []; out, dead = drain(8); screens.append(("start", out))
for it in args:
    if dead: break
    it = it.replace("\\e", "\x1b")
    if it in KEYS: os.write(fd, KEYS[it].encode())
    elif it.startswith("~"): os.write(fd, it[1:].encode())
    else: os.write(fd, (it + "\n").encode())
    out, dead = drain(8); screens.append((it, out))
if not dead:
    out, dead = drain(float(os.environ.get("LAST", "0.3"))); screens.append(("end", out))
try: os.kill(pid, 9)
except Exception: pass
def clean(b):
    t = b.decode("utf8", "replace").split("\x1b[H\x1b[2J")[-1]
    t = re.sub(r"\x1b\[(\d*)A\x1b\[J", "\n<redraw>\n", t)
    t = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b[78]", "", t).replace("\r", "")
    t = re.sub(r"(?:[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏][^\n⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]*?(?=[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]|$)){2,}", " ⠿ ", t)
    return t
for n, (it, b) in enumerate(screens):
    t = clean(b)
    if os.environ.get("FULL") != "1" and "<redraw>" in t: t = t.split("<redraw>")[-1]
    print(f"===== [{n}] after {it!r} =====")
    print("\n".join(l for l in t.split("\n") if l.strip()))
