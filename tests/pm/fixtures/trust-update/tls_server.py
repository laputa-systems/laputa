#!/usr/bin/env python3
## Disposable fixture HTTPS server for trust-update transport tests.
## Serves files from a document root over TLS with a fixture chain.
## Never used in production; the guest proof reaches this same server over
## the virtual network instead of running a TLS server inside the guest.
##
## Usage: tls_server.py CERTFILE KEYFILE PORTFILE DOCROOT [--drip BYTES] [--delay-ms MS]
## Writes the bound 127.0.0.1 port to PORTFILE, then serves until killed.
## Unknown paths and path escapes get 404. With --drip, bodies stream in
## BYTES-sized chunks with MS delay between chunks (for kill testing).

import http.server
import os
import socketserver
import ssl
import sys
import time


def main() -> int:
    args = sys.argv[1:]
    certfile, keyfile, portfile, docroot = args[0], args[1], args[2], args[3]
    drip = 65536
    delay_ms = 0
    i = 4
    while i < len(args):
        if args[i] == "--drip":
            drip = int(args[i + 1])
            i += 2
        elif args[i] == "--delay-ms":
            delay_ms = int(args[i + 1])
            i += 2
        else:
            print(f"unknown flag: {args[i]}", file=sys.stderr)
            return 2
    docroot = os.path.realpath(docroot)

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _resolve(self) -> str | None:
            if not self.path.startswith("/"):
                return None
            candidate = os.path.realpath(os.path.join(docroot, self.path[1:]))
            if candidate != docroot and not candidate.startswith(docroot + os.sep):
                return None
            if not os.path.isfile(candidate):
                return None
            return candidate

        def _serve(self, head_only: bool) -> None:
            resolved = self._resolve()
            if resolved is None:
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            size = os.path.getsize(resolved)
            self.send_response(200)
            self.send_header("Content-Length", str(size))
            self.send_header("Connection", "close")
            self.end_headers()
            if head_only:
                return
            with open(resolved, "rb") as handle:
                while True:
                    chunk = handle.read(drip)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    if delay_ms:
                        time.sleep(delay_ms / 1000.0)

        def do_GET(self) -> None:  # noqa: N802
            self._serve(False)

        def do_HEAD(self) -> None:  # noqa: N802
            self._serve(True)

        def log_message(self, *ignored: object) -> None:
            pass

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile, keyfile)
    with socketserver.ThreadingTCPServer(
        ("127.0.0.1", 0), Handler, bind_and_activate=False
    ) as server:
        server.allow_reuse_address = True
        server.server_bind()
        server.server_activate()
        server.socket = context.wrap_socket(server.socket, server_side=True)
        server.daemon_threads = True
        with open(portfile, "w", encoding="utf-8") as handle:
            handle.write(str(server.server_address[1]))
        server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
