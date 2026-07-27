"""Launch KlariVision in its own native macOS application window."""

from __future__ import annotations

import threading

import webview

from klarivision.local_app import create_server


def main() -> None:
    """Start the local analysis service and show it in a native webview."""
    server = create_server(port=0)
    worker = threading.Thread(target=server.serve_forever, name="klarivision-server", daemon=True)
    worker.start()
    host, port = server.server_address[:2]
    try:
        webview.create_window(
            "KlariVision",
            f"http://{host}:{port}/",
            width=1280,
            height=820,
            min_size=(900, 620),
        )
        webview.start(gui="cocoa")
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=2)


if __name__ == "__main__":
    main()
