#!/usr/bin/env python3
"""Plan Jellyfin network config changes.

Reads the current Jellyfin network config JSON on stdin and emits the line
protocol consumed by configure_jellyfin_networking:
    SKIP
    DRIFT + warning lines
    APPLY + JSON body
    APPLY_WITH_DRIFT + warning lines + --- + JSON body
"""
import json
import os
import sys


def main() -> int:
    config = json.load(sys.stdin)
    remote_ready = os.environ["REMOTE_READY"] == "true"
    host = os.environ["HOST_ADDR"]
    domain = os.environ["DOMAIN_VAL"]

    want_auto = True
    npm_proxy_ip = os.environ.get("NPM_PROXY_IP") or "172.28.0.10"
    want_published = [f"internal=http://{host}:8096"]
    if remote_ready:
        want_published.append(f"external=https://jellyfin.{domain}")

    cur_auto = config.get("AutoDiscovery", True)
    cur_proxies = config.get("KnownProxies", [])
    cur_published = config.get("PublishedServerUriBySubnet", [])

    managed_proxy_values = {"npm", "172.28.0.10", npm_proxy_ip}

    def desired_known_proxies(current):
        if not isinstance(current, list):
            current = []
        out = []
        managed_added = False
        for entry in current:
            if entry in managed_proxy_values:
                if remote_ready and not managed_added:
                    out.append(npm_proxy_ip)
                    managed_added = True
                continue
            out.append(entry)
        if remote_ready and not managed_added:
            out.append(npm_proxy_ip)
        return out

    want_proxies = desired_known_proxies(cur_proxies)

    def is_our_published_entry(entry):
        if entry.startswith("internal=http://") and entry.endswith(":8096"):
            published_host = entry[len("internal=http://") : -len(":8096")]
            if published_host == "localhost":
                return True
            return (
                all(char.isdigit() or char == "." for char in published_host)
                and published_host.count(".") == 3
            )
        return entry.startswith("external=https://jellyfin.")

    changes = {}
    drift = []
    skip_all = True

    if cur_auto == want_auto:
        pass
    elif cur_auto is not True:
        drift.append(f"AutoDiscovery is {cur_auto} (expected {want_auto})")

    if cur_proxies == want_proxies:
        pass
    else:
        changes["KnownProxies"] = want_proxies
        skip_all = False

    if cur_published == want_published:
        pass
    elif not cur_published:
        changes["PublishedServerUriBySubnet"] = want_published
        skip_all = False
    elif all(is_our_published_entry(entry) for entry in cur_published):
        changes["PublishedServerUriBySubnet"] = want_published
        skip_all = False
    else:
        drift.append(
            "PublishedServerUriBySubnet is {} (expected {})".format(
                cur_published, want_published
            )
        )

    if drift and not changes:
        print("DRIFT")
        for item in drift:
            print(item)
    elif skip_all and not changes:
        print("SKIP")
    else:
        for key, value in changes.items():
            config[key] = value
        if drift:
            print("APPLY_WITH_DRIFT")
            for item in drift:
                print(item)
            print("---")
        else:
            print("APPLY")
        print(json.dumps(config))
    return 0


if __name__ == "__main__":
    sys.exit(main())
