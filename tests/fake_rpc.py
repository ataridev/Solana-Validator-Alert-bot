#!/usr/bin/env python3
"""Fake Solana RPC: answers every POST with the current contents of the reply
file and logs the method called. The file is read per request, not up front."""
import http.server
import json
import os
import socketserver
import sys

REPLY_FILE = sys.argv[1]
LOG_FILE = sys.argv[2]
PORT = int(sys.argv[3])


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            method = json.loads(raw).get("method", "?")
        except Exception:
            method = "?"
        with open(LOG_FILE, "a") as f:
            f.write(method + "\n")

        # Per-method reply if present (reply_getEpochInfo, ...), else the default
        path = os.path.join(os.path.dirname(REPLY_FILE), "reply_" + method)
        if not os.path.exists(path):
            path = REPLY_FILE
        with open(path, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
    httpd.serve_forever()
