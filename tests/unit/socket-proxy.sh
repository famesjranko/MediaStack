#!/usr/bin/env bash
# Docker API exposure contract for docker-compose.yml.
#
# Only portainer (root-equivalent by design, DECISION D11) and the socket-proxy
# may mount /var/run/docker.sock. beszel-agent and autoheal reach the Docker
# API through the proxy, which runs in the host network namespace, listens on
# host loopback only, and allows exactly the paths those two need, each as a
# per-method anchored regex. The policy lives in one checker over the rendered
# compose. Mutated copies of the render prove the checker rejects each
# violation, so a green baseline cannot be a no-op. A second part replays a
# path corpus through the shipped regexes with the image's own wrapping
# (^...$), the one place where a regex can be correct yet unanchored.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="socket-proxy"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/policy.py" <<'PY'
import copy
import json
import os
import re
import sys

SOCK = "/var/run/docker.sock"
SOCK_MOUNTERS = {"portainer", "socket-proxy"}
CONSUMERS = {"beszel-agent", "autoheal"}
IMAGE_PREFIX = "wollomatic/socket-proxy:"
PORT = "23750"
# <id> is a lowercase hex container ID: beszel-agent sends the 12-character
# short ID, autoheal the full 64. Names never appear in either consumer's calls.
ID = "[0-9a-f]{12,64}"
# The complete allowlist, one regex per entry. Nothing else may be allowed.
ALLOW = {
    "GET": sorted(["/containers/json", f"/containers/{ID}/stats", "/version", "/info"]),
    "POST": [f"/containers/{ID}/restart"],
}
# Flags the proxy may carry. Anything else is a violation: for example
# -proxycontainername turns on label-granted allowlists and
# -proxysocketendpoint replaces the TCP listener.
SINGLE_FLAGS = {
    "listenip": "127.0.0.1",
    "proxyport": PORT,
    "allowfrom": "127.0.0.1/32",
}
OTHER_FLAGS = {"allowhealthcheck", "watchdoginterval", "stoponwatchdog", "loglevel"}
# Pattern characters that make a regex broader than a literal path plus the
# hex-ID class: wildcards, alternation (the image wraps ^...$ around the whole
# pattern, so "a|b" would leave both branches half-anchored), groups, escapes.
FORBIDDEN_REGEX_CHARS = set(".*+?|()^$\\")


def mutate(d, name):
    s = d["services"]
    p = s["socket-proxy"]
    cmd = p["command"]

    def swap(old, new):
        cmd[cmd.index(old)] = new

    if name == "beszel-socket":
        s["beszel-agent"]["volumes"] = [{"type": "bind", "source": SOCK, "target": SOCK}]
    elif name == "autoheal-socket":
        s["autoheal"]["volumes"] = [{"type": "bind", "source": SOCK, "target": SOCK}]
    elif name == "proxy-socket-rw":
        p["volumes"][0]["read_only"] = False
    elif name == "proxy-network-returns":
        d["networks"]["socket-proxy"] = {"name": "socket-proxy", "internal": True}
    elif name == "proxy-on-bridge":
        del p["network_mode"]
        p["networks"] = {"mediastack": {}}
    elif name == "proxy-ports":
        p["ports"] = [{"host_ip": "127.0.0.1", "target": 23750, "published": "23750", "protocol": "tcp"}]
    elif name == "listen-all":
        swap("-listenip=127.0.0.1", "-listenip=0.0.0.0")
    elif name == "listen-unset":
        cmd.remove("-listenip=127.0.0.1")
    elif name == "port-changed":
        swap("-proxyport=23750", "-proxyport=2375")
    elif name == "allowfrom-wide":
        swap("-allowfrom=127.0.0.1/32", "-allowfrom=0.0.0.0/0")
    elif name == "allowfrom-unset":
        cmd.remove("-allowfrom=127.0.0.1/32")
    elif name == "allow-inspect":
        cmd.append(f"-allowGET=/containers/{ID}/json")
    elif name == "allow-logs":
        cmd.append(f"-allowGET=/containers/{ID}/logs")
    elif name == "allow-attach-ws":
        cmd.append(f"-allowGET=/containers/{ID}/attach/ws")
    elif name == "allow-stop":
        cmd.append(f"-allowPOST=/containers/{ID}/stop")
    elif name == "allow-kill":
        cmd.append(f"-allowPOST=/containers/{ID}/kill")
    elif name == "allow-create":
        cmd.append("-allowPOST=/containers/create")
    elif name == "allow-delete":
        cmd.append(f"-allowDELETE=/containers/{ID}")
    elif name == "allow-head":
        cmd.append("-allowHEAD=/_ping")
    elif name == "allow-wildcard":
        swap(f"-allowGET=/containers/{ID}/stats", "-allowGET=/containers/.*")
    elif name == "allow-alternation":
        swap(f"-allowPOST=/containers/{ID}/restart", f"-allowPOST=/containers/{ID}/restart|/containers/create")
    elif name == "allow-loose-id":
        swap(f"-allowPOST=/containers/{ID}/restart", "-allowPOST=/containers/[0-9a-f]+/restart")
    elif name == "allow-name-id":
        swap(f"-allowGET=/containers/{ID}/stats", "-allowGET=/containers/[0-9a-zA-Z_-]+/stats")
    elif name == "drop-version":
        cmd.remove("-allowGET=/version")
    elif name == "env-allowlist":
        p["environment"] = {"SP_ALLOW_DELETE": "/.*"}
    elif name == "label-allowlists":
        cmd.append("-proxycontainername=socket-proxy")
    elif name == "unix-endpoint":
        cmd.append("-proxysocketendpoint=/tmp/proxy.sock")
    elif name == "bind-mount-flag":
        cmd.append("-allowbindmountfrom=/tmp")
    elif name == "not-read-only":
        p["read_only"] = False
    elif name == "cap-add":
        p["cap_add"] = ["SYS_CHROOT"]
    elif name == "cap-drop-missing":
        del p["cap_drop"]
    elif name == "no-new-privileges-missing":
        p["security_opt"] = []
    elif name == "privileged":
        p["privileged"] = True
    elif name == "proxy-profile":
        p["profiles"] = ["autoheal"]
    elif name == "image-swap":
        p["image"] = "lscr.io/linuxserver/socket-proxy:latest"
    elif name == "healthcheck-unset":
        del p["healthcheck"]
    elif name == "beszel-on-lan-address":
        s["beszel-agent"]["environment"]["DOCKER_HOST"] = "tcp://192.168.1.10:23750"
    elif name == "docker-host-unset":
        del s["beszel-agent"]["environment"]["DOCKER_HOST"]
    elif name == "beszel-left-host":
        del s["beszel-agent"]["network_mode"]
    elif name == "autoheal-direct":
        del s["autoheal"]["environment"]["DOCKER_SOCK"]
    elif name == "autoheal-by-name":
        s["autoheal"]["environment"]["DOCKER_SOCK"] = "tcp://socket-proxy:2375"
    elif name == "autoheal-left-host":
        del s["autoheal"]["network_mode"]
        s["autoheal"]["networks"] = {"mediastack": {}}
    elif name == "autoheal-no-wait":
        del s["autoheal"]["depends_on"]["socket-proxy"]
    elif name:
        sys.exit("unknown mutation " + name)
    return d


def parse_flags(cmd):
    flags = {}
    for item in cmd:
        m = re.fullmatch(r"-{1,2}([A-Za-z]+)(?:=(.*))?", item, re.S)
        if not m:
            flags.setdefault("?", []).append(item)
            continue
        flags.setdefault(m.group(1), []).append(m.group(2))
    return flags


def go_match(regex, path):
    # The image compiles "^" + regex + "$" and matches the decoded path. Go's $
    # (no multiline flag) is end of text only, which is Python's \Z.
    return re.search("^" + regex + "\\Z", path) is not None


def check(d):
    out = []
    s = d["services"]
    for name, svc in s.items():
        for v in svc.get("volumes") or []:
            if isinstance(v, dict) and v.get("source") == SOCK and name not in SOCK_MOUNTERS:
                out.append(f"{name} mounts {SOCK}")
    p = s["socket-proxy"]

    # No Docker network carries the proxy: it runs in the host namespace.
    extra = sorted(set(d.get("networks") or {}) - {"mediastack"})
    if extra:
        out.append(f"networks other than mediastack remain: {extra}")
    for name, svc in s.items():
        for net in svc.get("networks") or {}:
            if net.startswith("socket-proxy"):
                out.append(f"{name} is on the {net} network")
    if p.get("network_mode") != "host":
        out.append("proxy is not in the host network namespace")
    if p.get("networks"):
        out.append("proxy joins a Docker network")
    if p.get("ports"):
        out.append("proxy publishes ports, which a host-network proxy never needs")

    if not str(p.get("image", "")).startswith(IMAGE_PREFIX):
        out.append(f"proxy image is not {IMAGE_PREFIX}*")
    if p.get("profiles"):
        out.append("proxy is not in the default profile")
    if p.get("privileged"):
        out.append("proxy is privileged")
    if p.get("environment"):
        out.append(f"proxy sets environment {sorted(p['environment'])}; its allowlist is command flags only")
    mounts = [v for v in p.get("volumes") or [] if isinstance(v, dict) and v.get("source") == SOCK]
    if len(mounts) != 1 or not mounts[0].get("read_only"):
        out.append("proxy must mount the socket exactly once, read-only")
    if len(p.get("volumes") or []) != 1:
        out.append("proxy mounts something besides the socket")
    if not p.get("read_only"):
        out.append("proxy root filesystem is not read-only")
    if p.get("cap_drop") != ["ALL"]:
        out.append("proxy does not drop ALL capabilities")
    if p.get("cap_add"):
        out.append("proxy adds capabilities")
    if "no-new-privileges:true" not in (p.get("security_opt") or []):
        out.append("proxy lacks no-new-privileges")
    if not p.get("healthcheck"):
        out.append("proxy has no healthcheck")

    flags = parse_flags(p.get("command") or [])
    for key, want in SINGLE_FLAGS.items():
        if flags.get(key) != [want]:
            out.append(f"proxy -{key} is {flags.get(key)}, expected [{want!r}]")
    allow_methods = {k[len("allow"):] for k in flags if re.fullmatch(r"allow[A-Z]+", k)}
    for key in flags:
        if key in SINGLE_FLAGS or key in OTHER_FLAGS or re.fullmatch(r"allow[A-Z]+", key):
            continue
        out.append(f"proxy carries unlisted flag {key}")
    for method in sorted(allow_methods | set(ALLOW)):
        got = sorted(flags.get("allow" + method) or [])
        for regex in got:
            if regex is None or set(regex) & FORBIDDEN_REGEX_CHARS:
                out.append(f"proxy allow{method} pattern {regex!r} uses a wildcard, alternation or group")
        if got != ALLOW.get(method, []):
            out.append(f"proxy allow{method} is {got}, expected {ALLOW.get(method, [])}")

    port = (flags.get("proxyport") or [""])[0]
    agent = s["beszel-agent"]
    if agent.get("network_mode") != "host":
        out.append("beszel-agent left the host network namespace")
    if (agent.get("environment") or {}).get("DOCKER_HOST") != f"tcp://127.0.0.1:{port}":
        out.append("beszel-agent DOCKER_HOST is not the proxy loopback port")
    heal = s["autoheal"]
    if heal.get("network_mode") != "host" or heal.get("networks"):
        out.append("autoheal is not host-network only")
    if (heal.get("environment") or {}).get("DOCKER_SOCK") != f"tcp://127.0.0.1:{port}":
        out.append("autoheal DOCKER_SOCK is not the proxy loopback port")
    for name in CONSUMERS:
        dep = (s[name].get("depends_on") or {}).get("socket-proxy") or {}
        if dep.get("condition") != "service_healthy":
            out.append(f"{name} does not wait for a healthy proxy")
    return out


def corpus(d):
    """Replay paths through the shipped regexes; return violations."""
    out = []
    flags = parse_flags(d["services"]["socket-proxy"]["command"])
    allow = {m: flags.get("allow" + m) or [] for m in ("GET", "POST", "DELETE", "PUT", "HEAD")}
    short, full = "0123456789ab", "0123456789abcdef" * 4
    yes = [
        ("GET", "/containers/json"), ("GET", "/version"), ("GET", "/info"),
        ("GET", f"/containers/{short}/stats"), ("GET", f"/containers/{full}/stats"),
        ("POST", f"/containers/{short}/restart"), ("POST", f"/containers/{full}/restart"),
    ]
    no = [
        ("GET", f"/containers/{short}/json"), ("GET", f"/containers/{short}/logs"),
        ("GET", f"/containers/{short}/attach/ws"), ("GET", f"/containers/{short}/archive"),
        ("GET", f"/containers/{short}/top"), ("GET", f"/containers/{short}/changes"),
        ("GET", f"/containers/{short}/export"),
        ("GET", "/images/json"), ("GET", "/events"), ("GET", "/_ping"), ("GET", "/system/df"),
        ("GET", "/volumes"), ("GET", "/networks"), ("GET", "/secrets"), ("GET", "/configs"),
        ("POST", f"/containers/{short}/stop"), ("POST", f"/containers/{short}/kill"),
        ("POST", f"/containers/{short}/start"), ("POST", f"/containers/{short}/exec"),
        ("POST", f"/containers/{short}/update"), ("POST", "/containers/create"),
        ("POST", "/exec/abc/start"), ("POST", "/build"), ("POST", "/images/create"),
        ("DELETE", f"/containers/{short}"), ("PUT", f"/containers/{short}/archive"),
        ("HEAD", "/containers/json"),
        # Wrong verb on an allowed path.
        ("POST", "/containers/json"), ("GET", f"/containers/{short}/restart"),
        ("POST", f"/containers/{short}/stats"), ("POST", "/version"),
        # Path forms, as the proxy sees them after decoding.
        ("GET", "/containers/json/"), ("GET", "//containers/json"), ("GET", "/containers//json"),
        ("GET", "/containers/json\n"), ("GET", "/containers/json\x00"), ("GET", "/Containers/json"),
        ("GET", "/containers/json/../x"), ("GET", f"/containers/{short}/stats/"),
        ("GET", f"/containers/{short}/stats\n/containers/{short}/logs"),
        ("GET", f"/containers/{short}/stats/../logs"), ("GET", f"/containers/{short}/../json"),
        ("GET", f"/containers/{short}/stats/../../{short}/json"),
        ("GET", f"/containers/{short[:-1]}/stats"), ("GET", f"/containers/{full}0/stats"),
        ("GET", f"/containers/{short.upper()}/stats"), ("GET", "/containers/autoheal/stats"),
        ("GET", "/containers/../stats"), ("GET", "/containers/%2e%2e/stats"),
        ("GET", "/v1.43/containers/json"), ("GET", "/v1.43/version"),
        ("GET", " /containers/json"), ("GET", "/containers/json "), ("GET", "/version/"),
        ("GET", "/info/x"), ("GET", "/infoo"), ("GET", "/xinfo"),
        ("POST", f"/containers/{short}/restart/"), ("POST", f"/containers/{short}/restart/x"),
        ("POST", f"/containers/{short}/restartx"), ("POST", f"/containers/{short}/restart\n"),
        ("POST", f"/containers/{short}/stop/../restart"),
        ("POST", f"/containers/{short[:-1]}/restart"), ("POST", f"/containers/{full}0/restart"),
        ("POST", "/containers/autoheal/restart"),
    ]
    for method, path in yes:
        if not any(go_match(r, path) for r in allow.get(method, [])):
            out.append(f"corpus: {method} {path!r} should be allowed")
    for method, path in no:
        if any(go_match(r, path) for r in allow.get(method, [])):
            out.append(f"corpus: {method} {path!r} should be denied")
    return out


data = json.load(open(sys.argv[1]))
data = mutate(copy.deepcopy(data), os.environ.get("MUTATE", ""))
print("\n".join(check(data) + corpus(data)))
PY

render() { # render <outfile> [compose args...]
    local out="$1"
    shift
    (cd "$REPO_ROOT" && docker compose --env-file .env.example "$@" config --format json) >"$out"
}

policy() { # policy [MUTATION] -> violations, one per line
    MUTATE="${1:-}" python3 "$TMP_DIR/policy.py" "$TMP_DIR/render.json" 2>&1
}

# Given the default stack with the autoheal profile rendered
if ! render "$TMP_DIR/render.json" --profile autoheal; then
    fail "compose renders with the autoheal profile"
    scenario_end "$CURRENT_SCENARIO"
    summary
    exit 1
fi

# When the policy checker reads the unmodified render
baseline="$(policy)"

# Then it reports no violation
assert_eq "" "$baseline" "baseline: socket policy holds on the shipped compose"

# Given a render with one policy violation each, rejected with a named reason
# When the checker reads the mutated render
# Then it names the violation
expect_violation() { # expect_violation <mutation> <text> <description>
    assert_contains "$(policy "$1")" "$2" "$3"
}
expect_violation beszel-socket "beszel-agent mounts" "beszel-agent mounting the socket is rejected"
expect_violation autoheal-socket "autoheal mounts" "autoheal mounting the socket is rejected"
expect_violation proxy-socket-rw "exactly once, read-only" "a writable socket mount on the proxy is rejected"
expect_violation proxy-network-returns "networks other than mediastack remain" "a proxy Docker network coming back is rejected"
expect_violation proxy-on-bridge "not in the host network namespace" "the proxy on a bridge is rejected"
expect_violation proxy-ports "publishes ports" "a published proxy port is rejected"
expect_violation listen-all "-listenip is ['0.0.0.0']" "a proxy listening on all interfaces is rejected"
expect_violation listen-unset "-listenip is None" "an implicit listen address is rejected"
expect_violation port-changed "-proxyport is ['2375']" "moving the proxy onto dockerd's port is rejected"
expect_violation allowfrom-wide "-allowfrom is ['0.0.0.0/0']" "a client filter open to every address is rejected"
expect_violation allowfrom-unset "-allowfrom is None" "an implicit client filter is rejected"
expect_violation allow-inspect "allowGET is" "allowing container inspect (Env of every container) is rejected"
expect_violation allow-logs "allowGET is" "allowing container logs is rejected"
expect_violation allow-attach-ws "allowGET is" "allowing the attach/ws log stream is rejected"
expect_violation allow-stop "allowPOST is" "allowing stop is rejected"
expect_violation allow-kill "allowPOST is" "allowing kill is rejected"
expect_violation allow-create "allowPOST is" "allowing container create is rejected"
expect_violation allow-delete "allowDELETE is" "allowing DELETE is rejected"
expect_violation allow-head "allowHEAD is" "allowing HEAD is rejected"
expect_violation allow-wildcard "wildcard, alternation or group" "a wildcard pattern is rejected"
expect_violation allow-alternation "wildcard, alternation or group" "a top-level alternation (half-anchored by the image) is rejected"
expect_violation allow-alternation "should be denied" "the alternation also fails the path corpus"
expect_violation allow-loose-id "allowPOST is" "an unbounded container ID class is rejected"
expect_violation allow-loose-id "should be denied" "an unbounded ID class also fails the path corpus"
expect_violation allow-name-id "allowGET is" "a container-name ID class is rejected"
expect_violation drop-version "allowGET is" "dropping a consumer's path is rejected"
expect_violation drop-version "should be allowed" "a dropped path also fails the path corpus"
expect_violation env-allowlist "sets environment" "an SP_ALLOW_* environment allowlist is rejected"
expect_violation label-allowlists "unlisted flag proxycontainername" "label-granted allowlists are rejected"
expect_violation unix-endpoint "unlisted flag proxysocketendpoint" "replacing the TCP listener with a socket is rejected"
expect_violation bind-mount-flag "unlisted flag allowbindmountfrom" "an unreviewed proxy flag is rejected"
expect_violation not-read-only "not read-only" "a writable proxy filesystem is rejected"
expect_violation cap-add "adds capabilities" "added proxy capabilities are rejected"
expect_violation cap-drop-missing "drop ALL" "a proxy that keeps capabilities is rejected"
expect_violation no-new-privileges-missing "no-new-privileges" "a proxy without no-new-privileges is rejected"
expect_violation privileged "privileged" "a privileged proxy is rejected"
expect_violation proxy-profile "default profile" "a profile-gated proxy is rejected"
expect_violation image-swap "proxy image is not" "another proxy image is rejected"
expect_violation healthcheck-unset "no healthcheck" "a proxy without a healthcheck is rejected"
expect_violation beszel-on-lan-address "not the proxy loopback port" "beszel-agent aimed at a LAN address is rejected"
expect_violation docker-host-unset "not the proxy loopback port" "beszel-agent without the proxy address is rejected"
expect_violation beszel-left-host "beszel-agent left the host" "beszel-agent off the host network is rejected"
expect_violation autoheal-direct "DOCKER_SOCK is not the proxy" "autoheal without the proxy address is rejected"
expect_violation autoheal-by-name "DOCKER_SOCK is not the proxy" "autoheal aimed at a proxy service name is rejected"
expect_violation autoheal-left-host "not host-network only" "autoheal on the mediastack bridge is rejected"
expect_violation autoheal-no-wait "autoheal does not wait" "autoheal that does not wait for a healthy proxy is rejected"

# Given AUTOHEAL_ENABLED=false, so the autoheal profile is not rendered
render "$TMP_DIR/no-autoheal.json" || fail "compose renders without optional profiles"

# When the default stack is read
default_services="$(python3 -c '
import json, sys
print(" ".join(sorted(json.load(open(sys.argv[1]))["services"])))' "$TMP_DIR/no-autoheal.json")"

# Then the proxy and its remaining consumer are still there, autoheal is not
assert_contains " $default_services " " socket-proxy " "default stack still runs the proxy for beszel-agent"
assert_contains " $default_services " " beszel-agent " "default stack still runs beszel-agent"
assert_not_contains " $default_services " " autoheal " "autoheal stays out of the default stack"

# Given the uninstall path
# When it takes the stack down
# Then it addresses every profile, so the default-profile proxy stops with it
assert_file_contains "$REPO_ROOT/scripts/setup/checks/destroy.sh" 'docker compose --profile "*" down' \
    "uninstall brings down every profile, including the proxy"

scenario_end "$CURRENT_SCENARIO"
summary
