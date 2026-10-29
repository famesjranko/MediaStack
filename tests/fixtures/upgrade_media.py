"""Local media and torrent fixtures; no tracker, metadata service or download."""

from __future__ import annotations

import hashlib
import os
import pathlib
import subprocess
import time
import urllib.parse
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from upgrade_state import StateClient

TITLE = "MediaStack Upgrade Fixture"
USER = "upgrade-fixture-user"
MOVIE_PATH = f"/data/media/movies/{TITLE} (2000)/{TITLE} (2000).mp4"
TORRENT_NAME = "mediastack-upgrade-resume"
PIECE = b"MediaStack resume fixture\n".ljust(16384, b".")
OTHER_PIECE = b"Missing piece\n".ljust(16384, b".")
BACKUP = pathlib.Path("config/qbittorrent/qBittorrent/BT_backup")


def bencode(value: Any) -> bytes:
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    if isinstance(value, list):
        return b"l" + b"".join(bencode(item) for item in value) + b"e"
    if isinstance(value, dict):
        return b"d" + b"".join(bencode(k) + bencode(value[k]) for k in sorted(value)) + b"e"
    raise TypeError("unsupported torrent value")


INFO = {
    b"name": TORRENT_NAME.encode(),
    b"piece length": len(PIECE),
    b"pieces": hashlib.sha1(PIECE).digest() + hashlib.sha1(OTHER_PIECE).digest(),
    b"private": 1,
    b"files": [
        {b"length": len(PIECE), b"path": [b"present.bin"]},
        {b"length": len(OTHER_PIECE), b"path": [b"missing.bin"]},
    ],
}
TORRENT_HASH = hashlib.sha1(bencode(INFO)).hexdigest()


def wait_for(probe: Any, description: str) -> Any:
    for _ in range(90):
        value = probe()
        if value:
            return value
        time.sleep(1)
    raise ValueError(f"fixture not ready: {description}")


def movie(client: StateClient) -> dict[str, Any] | None:
    items = client.call("jellyfin", "/Items?Recursive=true&IncludeItemTypes=Movie&Fields=Path")
    return next((item for item in items["Items"] if item.get("Path") == MOVIE_PATH), None)


def seed_watch_state(client: StateClient) -> None:
    target = pathlib.Path(client.env["DATA_DIR"]) / MOVIE_PATH.removeprefix("/data/")
    target.parent.mkdir(parents=True, exist_ok=True)
    os.chown(target.parent, 1000, 1000)
    if not target.is_file() or not target.stat().st_size:
        clip = subprocess.run(
            [
                "docker",
                "exec",
                "jellyfin",
                "/usr/lib/jellyfin-ffmpeg/ffmpeg",
                "-v",
                "error",
                "-f",
                "lavfi",
                "-i",
                "color=c=black:s=32x32:r=1",
                "-t",
                "1",
                "-c:v",
                "mpeg4",
                "-movflags",
                "frag_keyframe+empty_moov",
                "-f",
                "mp4",
                "pipe:1",
            ],
            check=True,
            stdout=subprocess.PIPE,
        )
        target.write_bytes(clip.stdout)
        os.chown(target, 1000, 1000)
    # Disable remote metadata for this library before scanning the generated clip.
    library = next(
        row
        for row in client.call("jellyfin", "/Library/VirtualFolders")
        if row["CollectionType"] == "movies"
    )
    options = library["LibraryOptions"]
    options["TypeOptions"] = [{"Type": "Movie", "MetadataFetchers": [], "ImageFetchers": []}]
    client.call(
        "jellyfin",
        "/Library/VirtualFolders/LibraryOptions",
        {"Id": library["ItemId"], "LibraryOptions": options},
        "POST",
    )
    client.call("jellyfin", "/Library/Refresh", method="POST")
    item = wait_for(lambda: movie(client), "Jellyfin movie scan")
    user = next(u for u in client.call("jellyfin", "/Users") if u["Name"] == USER)
    client.call(
        "jellyfin",
        f"/Users/{user['Id']}/PlayedItems/{item['Id']}?datePlayed=2020-01-02T03%3A04%3A05Z",
        method="POST",
    )


def torrent(client: StateClient) -> dict[str, Any] | None:
    rows = client.qbt(f"torrents/info?hashes={TORRENT_HASH}")
    return rows[0] if len(rows) == 1 else None


def qbt_post(client: StateClient, endpoint: str, **values: Any) -> None:
    client.qbt_request(endpoint, urllib.parse.urlencode(values).encode())


def seed_torrent(client: StateClient) -> None:
    if torrent(client):
        return
    root = pathlib.Path(client.env["DATA_DIR"]) / "torrents/migration" / TORRENT_NAME
    root.mkdir(parents=True, exist_ok=True)
    (root / "present.bin").write_bytes(PIECE)
    for path in (root.parent, root, root / "present.bin"):
        os.chown(path, 1000, 1000)
    boundary = "mediastack-upgrade-fixture"
    fields = {
        "savepath": "/data/torrents/migration",
        "paused": "true",
        "stopped": "true",
        "autoTMM": "false",
        "tags": "upgrade-fixture",
    }
    data = b""
    for name, value in fields.items():
        data += (
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'
        ).encode()
    data += (
        f'--{boundary}\r\nContent-Disposition: form-data; name="torrents"; '
        'filename="fixture.torrent"\r\nContent-Type: application/x-bittorrent\r\n\r\n'
    ).encode()
    data += bencode({b"info": INFO}) + f"\r\n--{boundary}--\r\n".encode()
    client.qbt_request("torrents/add", data, f"multipart/form-data; boundary={boundary}")
    wait_for(lambda: torrent(client), "torrent registration")
    qbt_post(client, "torrents/recheck", hashes=TORRENT_HASH)
    wait_for(lambda: (torrent(client) or {}).get("progress") == 0.5, "one verified torrent piece")
    qbt_post(client, "torrents/setDownloadLimit", hashes=TORRENT_HASH, limit=123456)
    qbt_post(client, "torrents/setUploadLimit", hashes=TORRENT_HASH, limit=234567)
    # Flush resume data, then require the real process to load it on startup.
    subprocess.run(["docker", "compose", "restart", "qbittorrent"], check=True)
    wait_qbt(client)


def wait_qbt(client: StateClient) -> None:
    def ready() -> bool:
        try:
            return bool(torrent(client))
        except OSError:
            return False

    wait_for(ready, "qBittorrent resume load")


def snapshot(client: StateClient) -> dict[str, Any]:
    user = next(u for u in client.call("jellyfin", "/Users") if u["Name"] == USER)
    item = movie(client)
    if not item:
        raise ValueError("Jellyfin lost the fixture movie")
    # Jellyfin's per-item endpoint can return stale userdata after a library
    # mark. The bulk query reads the persisted state for the explicit user.
    details = client.call(
        "jellyfin", f"/Items?UserId={user['Id']}&Ids={item['Id']}&EnableUserData=true"
    )["Items"]
    if len(details) != 1 or details[0]["Id"] != item["Id"]:
        raise ValueError("Jellyfin lost the fixture watch state")
    watched = details[0]["UserData"]
    if not watched["Played"] or watched["PlayCount"] < 1:
        raise ValueError("Jellyfin lost the fixture watch state")
    row = torrent(client)
    if not row or row["state"] not in ("pausedDL", "stoppedDL") or row["progress"] != 0.5:
        raise ValueError("qBittorrent lost the paused fixture or its verified piece")
    files = [BACKUP / f"{TORRENT_HASH}.{suffix}" for suffix in ("torrent", "fastresume")]
    if not all(path.is_file() and path.stat().st_size for path in files):
        raise ValueError("qBittorrent lost torrent or resume files")
    return {
        "jellyfin/watch-state": {
            "userId": user["Id"],
            "itemId": item["Id"],
            **{
                key: watched.get(key)
                for key in ("Played", "PlayCount", "PlaybackPositionTicks", "LastPlayedDate")
            },
        },
        "qbittorrent/torrent": {
            key: row[key]
            for key in (
                "hash",
                "name",
                "size",
                "save_path",
                "progress",
                "amount_left",
                "tags",
                "dl_limit",
                "up_limit",
            )
        },
        # Peer availability changes independently of saved download state.
        "qbittorrent/files": [
            {key: row[key] for key in ("name", "size", "progress", "priority")}
            for row in client.qbt(f"torrents/files?hash={TORRENT_HASH}")
        ],
        "qbittorrent/metainfo": hashlib.sha256(files[0].read_bytes()).hexdigest(),
    }
