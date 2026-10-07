"""Поддельный сервис здоровья для tests/deploy.e2e.ps1.
GET /<артефакт>/health: 200 и JSON {"version": <version.json релиза>}, если в <корень>/<артефакт>/current есть файл
`healthy`; иначе 503. Порт печатается первой строкой."""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parts = [p for p in self.path.split("/") if p]
        if len(parts) != 2 or parts[1] != "health":
            self.send_response(404)
            self.end_headers()
            return
        current = ROOT / parts[0] / "current"
        if not (current / "healthy").exists():
            self.send_response(503)
            self.end_headers()
            return
        version_file = current / "version.json"
        version = json.loads(version_file.read_text(encoding="utf-8-sig")) if version_file.exists() else None
        body = json.dumps({"status": "ok", "version": version}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
