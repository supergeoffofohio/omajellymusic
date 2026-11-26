"""Authenticated, loopback-only audio streaming for the persistent player."""
import http.server
import re
import threading
import urllib.error
import urllib.parse
from typing import Any

from omajelly.client import HttpMethod, JellyfinClient
from omajelly.common import JellyfinError, clean_text


class ThreadedServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        self.request_slots = threading.BoundedSemaphore(4)
        super().__init__(*args, **kwargs)

    def process_request(self, request: Any, client_address: Any) -> None:
        if not self.request_slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request: Any, client_address: Any) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.request_slots.release()


def proxy_handler(
    client: JellyfinClient, routes: dict[str, str]
) -> type[http.server.BaseHTTPRequestHandler]:
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_HEAD(self) -> None:
            self.proxy(HttpMethod.HEAD)

        def do_GET(self) -> None:
            self.proxy(HttpMethod.GET)

        def proxy(self, method: HttpMethod) -> None:
            expected_host = "127.0.0.1:" + str(self.server.server_address[1])
            if self.headers.get("Host", "") != expected_host or self.headers.get(
                "Origin"
            ):
                self.send_error(403)
                return
            parsed_path = urllib.parse.urlsplit(self.path)
            upstream_path = routes.get(parsed_path.path)
            if upstream_path is None or parsed_path.query:
                self.send_error(404)
                return
            range_header = self.headers.get("Range", "")
            if range_header and not re.fullmatch(
                r"bytes=\d*-\d*(?:,\d*-\d*)*", range_header
            ):
                self.send_error(416)
                return
            try:
                response = client.open(
                    upstream_path, method=method, range_header=range_header
                )
            except urllib.error.HTTPError as error:
                status = error.code
                error.close()
                self.send_error(status if 400 <= status <= 599 else 502)
                return
            except JellyfinError:
                self.send_error(502)
                return
            try:
                self.send_response(int(getattr(response, "status", response.getcode())))
                for name in [
                    "Content-Type",
                    "Content-Length",
                    "Content-Range",
                    "Accept-Ranges",
                    "Last-Modified",
                    "ETag",
                ]:
                    value = response.headers.get(name)
                    if value:
                        self.send_header(name, clean_text(value, 512))
                self.send_header("Connection", "close")
                self.end_headers()
                if method is HttpMethod.GET:
                    while True:
                        chunk = response.read(64 * 1024)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                response.close()

        def log_message(self, format: str, *args: Any) -> None:
            return

    return Handler
