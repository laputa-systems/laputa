import http.server
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        agent = self.headers.get("User-Agent", "")
        body = b"forbidden\n" if agent == "" else b"payload\n"
        self.send_response(403 if agent == "" else 200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as port:
    port.write(str(server.server_address[1]))
server.serve_forever()
