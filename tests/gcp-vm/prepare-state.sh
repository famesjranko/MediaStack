#!/usr/bin/env bash
# Give the shared migration oracle the same local indexer as the DinD fixtures.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

mkdir -p config/jackett/cardigann/definitions
cp tests/fixtures/torznab/mstest.yml config/jackett/cardigann/definitions/mstest.yml
python3 - <<'PY'
from pathlib import Path
import yaml

path = Path("config.yml")
config = yaml.safe_load(path.read_text())
config["indexers"] = [{"id": "mstest", "type": "general"}]
path.write_text(yaml.safe_dump(config, sort_keys=False))
PY

# Pin this auxiliary image because the source SHA also binds the fixture runtime.
docker run -d --name torznab-fixture --network mediastack \
    --read-only --cap-drop ALL --security-opt no-new-privileges \
    --user "$(id -u):$(id -g)" \
    -v "$PWD/tests/fixtures/torznab/server.py:/srv/server.py:ro" \
    python:3.12-alpine@sha256:5789aa194f757888f41fa3d48e14b6feaa1b57c0af0b56fcb1372d6474d3bff0 \
    python3 -I /srv/server.py >/dev/null

ready=0
for ((attempt = 0; attempt < 15; attempt++)); do
    if docker exec torznab-fixture python3 -c \
        'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8080/search", timeout=3).read()' >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 2
done
((ready)) || {
    echo 'Local tracker fixture did not become ready' >&2
    exit 1
}

# Jackett loads custom definitions at startup, before its configurator registers them.
docker restart jackett >/dev/null
ready=0
for ((attempt = 0; attempt < 60; attempt++)); do
    if [[ "$(docker inspect --format '{{.State.Health.Status}}' jackett)" == healthy ]]; then
        ready=1
        break
    fi
    sleep 2
done
((ready)) || {
    echo 'Jackett did not become healthy after loading the fixture' >&2
    exit 1
}
timeout 300 ./scripts/configure.sh --only jackett,sonarr,radarr
