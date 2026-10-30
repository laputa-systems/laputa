import http.server
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
port_file = pathlib.Path(sys.argv[2])

class Handler(http.server.BaseHTTPRequestHandler):
    generation = 0

    def do_GET(self):
        path = self.path.lstrip('/')
        if path == 'snapshot.json':
            Handler.generation += 1
            path = 'snapshot-gen2/metadata' if Handler.generation == 1 else 'snapshot-gen1/metadata'
        elif path == 'snapshot.sig':
            path = 'snapshot-gen2/metadata.sig' if Handler.generation == 1 else 'snapshot-gen1/metadata.sig'
        elif path == 'tampered/snapshot.json':
            path = 'snapshot-gen1/metadata'
        elif path == 'tampered/snapshot.sig':
            path = 'snapshot-gen1/metadata.sig'
        elif path == 'tampered/index.json':
            body = (root / 'index.json').read_bytes().replace(b'fixture-payload', b'tampered-payload')
            self.send_response(200)
            self.end_headers()
            self.wfile.write(body)
            return
        if path not in {'snapshot-gen1/metadata', 'snapshot-gen1/metadata.sig', 'snapshot-gen2/metadata', 'snapshot-gen2/metadata.sig', 'index.json'}:
            self.send_error(404)
            return
        body = (root / path).read_bytes()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

server = http.server.HTTPServer(('0.0.0.0', 0), Handler)
port_file.write_text(str(server.server_port))
server.serve_forever()
