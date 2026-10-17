#!/usr/bin/env python3
"""Stand-in for qBittorrent's WebUI API (enough to test vpnguard-qbit-port).
Login: admin / adminadmin. A setPreferences call is appended to /tmp/qbit-prefs.log."""
import http.server
import json
import os
import urllib.parse


class H(http.server.BaseHTTPRequestHandler):
    def _body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        return self.rfile.read(n).decode(errors="replace")

    def do_POST(self):
        body = urllib.parse.parse_qs(self._body())
        if self.path.endswith("/auth/login"):
            ok = body.get("username") == ["admin"] and body.get("password") == ["adminadmin"]
            style204 = os.environ.get("QBIT_STYLE") == "204"
            self.send_response(204 if (ok and style204) else 200)
            if ok:
                self.send_header("Set-Cookie", "SID=abc123; path=/")
            self.end_headers()
            if not (ok and style204):
                self.wfile.write(b"Ok." if ok else b"Fails.")
        elif self.path.endswith("/app/setPreferences"):
            if "SID=abc123" not in (self.headers.get("Cookie") or ""):
                self.send_response(403)
                self.end_headers()
                return
            prefs = json.loads(body.get("json", ["{}"])[0])
            with open("/tmp/qbit-prefs.log", "a") as f:
                f.write(json.dumps(prefs) + "\n")
            self.send_response(200)
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *a):
        pass


http.server.HTTPServer(("0.0.0.0", int(os.environ.get("QBIT_PORT", "8080"))), H).serve_forever()
