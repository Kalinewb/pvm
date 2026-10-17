#!/usr/bin/env python3
"""Tiny stand-in for ntfy and Gotify: logs every POST to /tmp/notify.log and answers 200."""
import http.server


class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(n).decode(errors="replace").replace("\r\n", " ").replace("\n", " ")
        title = self.headers.get("Title")
        prio = self.headers.get("Priority")
        auth = self.headers.get("Authorization")
        with open("/tmp/notify.log", "a") as f:
            f.write("%s | Title=%s Prio=%s Auth=%s | %s\n" % (self.path, title, prio, auth, body[:200]))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *a):
        pass


http.server.HTTPServer(("127.0.0.1", 8099), H).serve_forever()
