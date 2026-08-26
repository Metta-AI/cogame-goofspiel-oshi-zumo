#!/usr/bin/env python3
"""Static server for the renderer fixture, plus one deliberately hanging path.

`tools/ci/renderer_fixture.html` loads the SHIPPED bundle in an iframe and
then drives `GozuRenderer.attachReplay` directly with a synthetic payload --
the wasm entry is the only thing it bypasses. But the shell inside that iframe
still runs its own `?replay=` fetch on load, and `viewer_smoke.mjs` installs
its postMessage bridge stub in EVERY frame, so a shell that reports "missing
?replay=" (or loads a second, competing replay) would decide the harness's
verdict before the fixture had drawn anything.

So the fixture points the shell at `/hang`, which accepts the connection and
never answers. The shell sits on "LOADING" (its own 20 s fetch timeout), posts
nothing but `loading`, and the fixture owns the signal: it sets
`data-replay-loaded="true"` on the TOP document once it has driven every
width, which is what the harness waits for.

  python3 tools/ci/fixture_server.py <dir> <port>
"""

import http.server
import os
import socketserver
import sys
import time


def main() -> int:
    directory = sys.argv[1] if len(sys.argv) > 1 else "."
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8731

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=directory, **kwargs)

        def do_GET(self):  # noqa: N802 - stdlib naming
            if self.path.split("?")[0] == "/hang":
                # Accepted, never answered: the shell's own fetch timeout is
                # what eventually gives up, long after the fixture is done.
                time.sleep(120)
                return
            super().do_GET()

        def log_message(self, *args):
            pass

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("127.0.0.1", port), Handler) as srv:
        print(f"serving {os.path.abspath(directory)} on 127.0.0.1:{port}",
              flush=True)
        srv.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
