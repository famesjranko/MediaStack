"""Deterministic tracker site behind the `mstest` Jackett definition.

Jackett loads tests/fixtures/torznab/mstest.yml as a custom Cardigann
definition and parses this page for every Torznab search. The four releases
never change, so a scenario can prove Jackett -> Sonarr/Radarr registration,
caps discovery, persisted indexer settings and a real search round trip
without reaching any public tracker. Runs under python:3.12-alpine inside DinD
on the MediaStack network as the `torznab-fixture` container.
"""

from __future__ import annotations

from http.server import BaseHTTPRequestHandler, HTTPServer

# (category id in mstest.yml, title, size, seeders, leechers, published)
RELEASES = [
    ("tv-hd", "Fixture Show S01E01 1080p WEB-DL x264-MSTEST", "1.4 GB", 12, 3, "2026-01-01"),
    ("tv", "Fixture Show S01E02 720p HDTV x264-MSTEST", "900 MB", 8, 1, "2026-01-02"),
    ("movies-hd", "Fixture Movie 2025 1080p BluRay x264-MSTEST", "8.1 GB", 20, 5, "2026-01-03"),
    ("movies", "Fixture Movie 2024 720p WEB-DL x264-MSTEST", "2.2 GB", 15, 2, "2026-01-04"),
]

# A minimal, syntactically valid bencoded torrent so a download link resolves.
TORRENT = (
    b"d8:announce21:http://fixture/announce4:infod6:lengthi1e4:name7:fixture"
    b"12:piece lengthi16384e6:pieces20:00000000000000000000ee"
)


def results_page() -> bytes:
    rows = "".join(
        f'<tr><td class="cat">{cat}</td>'
        f'<td class="title"><a href="/details/{n}">{title}</a></td>'
        f'<td class="dl"><a href="/dl/{n}.torrent">download</a></td>'
        f'<td class="size">{size}</td><td class="seeders">{seeders}</td>'
        f'<td class="leechers">{leechers}</td><td class="date">{published} 10:00:00</td></tr>'
        for n, (cat, title, size, seeders, leechers, published) in enumerate(RELEASES, start=1)
    )
    html = f'<html><body><table class="results"><tbody>{rows}</tbody></table></body></html>'
    return html.encode()


class FixtureHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path.startswith("/dl/"):
            body, content_type = TORRENT, "application/x-bittorrent"
        else:
            body, content_type = results_page(), "text/html; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        return


def main() -> None:
    HTTPServer(("0.0.0.0", 8080), FixtureHandler).serve_forever()


if __name__ == "__main__":
    main()
