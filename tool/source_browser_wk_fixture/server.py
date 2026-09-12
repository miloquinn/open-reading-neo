#!/usr/bin/env python3
import http.server
import socketserver
import threading
import time


class ReusableThreadingServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        port = self.server.server_address[1]
        if port == 18766 and self.path.startswith("/frame"):
            text = """<!doctype html><script>
localStorage.setItem("frameObserved", localStorage.getItem("seed") || "");
localStorage.setItem("frameWrite", "iframe");
</script>"""
        else:
            frame = (
                '<iframe src="http://127.0.0.1:18766/frame"></iframe>'
                if port == 18765
                else ""
            )
            text = f"""<!doctype html><html data-seed=""><script>
document.documentElement.dataset.seed = localStorage.getItem("seed") || "";
localStorage.setItem("pageWrite", "{port}");
</script>{frame}</html>"""
        body = text.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


servers = [ReusableThreadingServer(("127.0.0.1", port), Handler) for port in (18765, 18766)]
for server in servers:
    threading.Thread(target=server.serve_forever, daemon=True).start()

while True:
    time.sleep(60)
