# Runtime proof of the Docker API boundary in a running stack: the proxy
# allows only its consumers' paths, listens on host loopback only, and no
# consumer keeps the raw socket. tests/unit/socket-proxy.sh proves the same
# policy statically on the rendered compose; this proves the daemon and the
# network enforce it.
assert_socket_proxy_policy() {
    if svc_stripped socket-proxy; then
        skip "socket-proxy: runtime policy" "stripped via MS_TEST_STRIP_SERVICES"
        return
    fi

    local proxy="http://127.0.0.1:23750" code

    # The proxy allows only a path allowlist, so every denial below is checked
    # against a real container ID: with a made-up one, an allowed path would
    # answer 404 and a denied one 403, but a real ID makes "allowed" visible as
    # 200. The proxy's own container is the read-only target; a throwaway
    # container made from the beszel-agent image (alpine, has sleep) is the
    # restart target, so no real service restarts.
    local pid pshort fixture="ms-proxy-probe" fixture_short fixture_image
    pid=$(dind_exec "docker inspect --format '{{.Id}}' socket-proxy" | tr -d '\r\n')
    pshort=${pid:0:12}
    fixture_image=$(dind_exec "docker inspect --format '{{.Config.Image}}' beszel-agent" | tr -d '\r\n')
    dind_exec "docker rm -f $fixture" >/dev/null 2>&1 || true
    if ! dind_exec "docker run -d --name $fixture --stop-timeout 1 --entrypoint sleep $fixture_image 600" >/dev/null 2>&1; then
        fail "socket-proxy: restart-target container started"
        return
    fi
    fixture_short=$(dind_exec "docker inspect --format '{{.Id}}' $fixture" | tr -d '\r\n')
    fixture_short=${fixture_short:0:12}

    # Each row is "<method> <path> <expected status>". The first block is the
    # exact set the consumers use. The second is denied: 403 is the proxy's
    # path denial, 405 its method denial (no regex exists for that verb).
    local method path want
    while read -r method path want; do
        code=$(dind_exec "curl -s -m 5 -o /dev/null -w '%{http_code}' -X $method '$proxy$path'" | tr -d '\r\n')
        path=${path//$pid/<full-id>}
        path=${path//$fixture_short/<target>}
        assert_eq "$want" "$code" "socket-proxy: $method ${path//$pshort/<id>} -> $want"
    done <<ROWS
GET /containers/json 200
GET /containers/json?all=1&filters=%7B%22health%22%3A%5B%22unhealthy%22%5D%7D 200
GET /containers/$pshort/stats?stream=0&one-shot=1 200
GET /containers/$pid/stats?stream=0&one-shot=1 200
GET /version 200
GET /info 200
POST /containers/$fixture_short/restart?t=1 204
GET /containers/$pshort/json 403
GET /containers/$pid/json 403
GET /containers/$pshort/logs?stdout=1&stderr=1 403
GET /containers/$pshort/top 403
GET /containers/$pshort/archive?path=/ 403
GET /containers/$pshort%2fjson 403
GET /containers/$pshort/stats%2f..%2fjson 403
GET /containers/socket-proxy/stats 403
GET /containers/socket-proxy/json 403
POST /containers/$fixture_short/stop 403
POST /containers/$fixture_short/kill 403
POST /containers/$fixture_short/start 403
POST /containers/$fixture_short/exec 403
POST /containers/create 403
DELETE /containers/$fixture_short 405
GET /images/json 403
GET /volumes 403
GET /networks 403
GET /events 403
GET /_ping 403
GET /system/df 403
ROWS

    # The restart row only proves the verb was forwarded; the container must
    # also have been restarted, and not stopped by the kill/stop rows above.
    local running
    running=$(dind_exec "docker inspect --format '{{.State.Running}}' $fixture" | tr -d '\r\n')
    assert_eq "true" "$running" "socket-proxy: restart target is still running after the denied stop/kill"
    dind_exec "docker rm -f $fixture" >/dev/null 2>&1 || true

    # The websocket attach endpoint streams a container's output even where
    # /logs is denied (linuxserver/socket-proxy allowed it under CONTAINERS=1,
    # answering 101). The handshake must be denied before any upgrade.
    local ws_status
    ws_status=$(
        docker exec -i "$DIND_NAME" python3 - "$pshort" <<'PY' | tr -d '\r\n'
import base64, os, socket, sys
s = socket.create_connection(("127.0.0.1", 23750), 5)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall((
    f"GET /containers/{sys.argv[1]}/attach/ws?logs=1&stdout=1&stderr=1 HTTP/1.1\r\n"
    f"Host: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nOrigin: http://x\r\n\r\n"
).encode())
s.settimeout(3)
print(s.recv(4096).split(b"\r\n")[0].decode())
PY
    )
    assert_eq "HTTP/1.1 403 Forbidden" "$ws_status" "socket-proxy: GET /containers/<id>/attach/ws with websocket headers -> 403"

    # Neither consumer keeps the raw socket, and the proxy holds it read-only.
    local svc mounts
    for svc in beszel-agent autoheal; do
        mounts=$(dind_exec "docker inspect --format '{{range .Mounts}}{{.Source}} {{end}}' $svc 2>/dev/null" | tr -d '\r\n')
        assert_not_contains "$mounts" "docker.sock" "socket-proxy: $svc has no raw socket mount"
    done
    mounts=$(dind_exec "docker inspect --format '{{range .Mounts}}{{.Source}} rw={{.RW}};{{end}}' socket-proxy" | tr -d '\r\n')
    assert_eq "/var/run/docker.sock rw=false;" "$mounts" "socket-proxy: the proxy mounts only the socket, read-only"

    # The proxy runs in the host network namespace: no Docker network carries
    # it. Its listeners are the API port and the image's healthcheck port, both
    # on 127.0.0.1 only. `ss` is not in the DinD image, so read the kernel's
    # LISTEN table (state 0A) directly; IPv6 is read too, so a [::] listener
    # would show up.
    local nets listeners
    nets=$(dind_exec "docker network ls --format '{{.Name}}'" | tr '\r\n' '  ')
    assert_not_contains " $nets" " socket-proxy" "socket-proxy: no socket-proxy Docker network exists"
    listeners=$(
        docker exec -i "$DIND_NAME" python3 - <<'PY'
import socket
for path, fam in (("/proc/net/tcp", socket.AF_INET), ("/proc/net/tcp6", socket.AF_INET6)):
    for line in open(path).read().splitlines()[1:]:
        f = line.split()
        if f[3] != "0A":
            continue
        addr, port = f[1].split(":")
        raw = bytes.fromhex(addr)
        if fam == socket.AF_INET:
            ip = socket.inet_ntop(fam, raw[::-1])
        else:
            ip = socket.inet_ntop(fam, b"".join(raw[i:i + 4][::-1] for i in range(0, 16, 4)))
        if int(port, 16) in (23750, 55555):
            print(f"{ip}:{int(port, 16)}")
PY
    )
    assert_eq "127.0.0.1:23750,127.0.0.1:55555" "$(sort <<<"$listeners" | paste -sd, -)" \
        "socket-proxy: listens on 127.0.0.1 only (API 23750, healthcheck 55555)"

    # Nothing but host-local callers reaches it: not a container on the
    # mediastack bridge (by gateway), and not the DinD host's own LAN address.
    # Each probe has a control with the same tool and address against a port
    # that is published on every interface (beszel hub, 8090), so a missing
    # tool or a broken route cannot make the probes pass vacuously.
    local gateway host_ip control_gw control_ip probe_gw probe_ip
    gateway=$(dind_exec "docker network inspect mediastack --format '{{(index .IPAM.Config 0).Gateway}}'" | tr -d '\r\n')
    host_ip=$(dind_exec "hostname -i" | awk '{print $1}' | tr -d '\r\n')
    control_gw=$(dind_exec "docker exec homepage wget -q -T 5 -O /dev/null http://$gateway:8090/api/health >/dev/null 2>&1; echo \$?" | tr -d '\r\n')
    control_ip=$(dind_exec "curl -s -m 5 -o /dev/null -w '%{http_code}' http://$host_ip:8090/" | tr -d '\r\n')
    probe_gw=$(dind_exec "docker exec homepage wget -q -T 3 -O /dev/null http://$gateway:23750/containers/json >/dev/null 2>&1; echo \$?" | tr -d '\r\n')
    probe_ip=$(dind_exec "curl -s -m 3 -o /dev/null -w '%{http_code}' http://$host_ip:23750/containers/json" | tr -d '\r\n')
    assert_eq "0" "$control_gw" "socket-proxy: probe tool reaches a published port via the bridge gateway $gateway from homepage"
    assert_contains " 200 302 " " $control_ip " "socket-proxy: probe tool reaches a published port on the host address $host_ip"
    if [[ -n "$probe_gw" && "$probe_gw" != "0" ]]; then
        pass "socket-proxy: homepage cannot reach the proxy via the bridge gateway port 23750 (wget exit $probe_gw)"
    else
        fail "socket-proxy: homepage cannot reach the proxy via the bridge gateway port 23750" "wget exit '$probe_gw'"
    fi
    assert_eq "000" "$probe_ip" "socket-proxy: the proxy refuses connections on the host address $host_ip"
}
