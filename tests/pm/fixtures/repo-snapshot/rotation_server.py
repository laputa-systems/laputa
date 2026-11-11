import hashlib
import http.server
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
port_file = pathlib.Path(sys.argv[2])
index_url = 'indexes/' + hashlib.sha256((root / 'index.json').read_bytes()).hexdigest() + '.json'
generations = {
    'gen1': 'snapshot-gen1',
    'gen2': 'snapshot-gen2',
    'gen3': 'snapshot-gen3-backdated',
}


class Handler(http.server.BaseHTTPRequestHandler):
    selected = 'gen1'

    def do_GET(self):
        path = self.path.lstrip('/')
        if path.startswith('select/'):
            name = path[len('select/'):]
            if name not in generations:
                self.send_error(404)
                return
            Handler.selected = name
            self.send_response(200)
            self.end_headers()
            return
        if path == 'repo/snapshot.json':
            body = (root / generations[Handler.selected] / 'metadata').read_bytes()
        elif path == 'repo/snapshot.sig':
            body = (root / generations[Handler.selected] / 'metadata.sig').read_bytes()
        elif path == f'repo/{index_url}':
            body = (root / 'index.json').read_bytes()
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)


server = http.server.HTTPServer(('0.0.0.0', 0), Handler)
port_file.write_text(str(server.server_port))
server.serve_forever()
