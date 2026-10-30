#!/usr/bin/env bash
# The standalone WireGuard fixture must prepare its own package index.
set -uo pipefail
UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO=wireguard-add-after-https
scenario_begin "$CURRENT_SCENARIO"
TEST_APT_DIR=$(mktemp -d)
export TEST_APT_DIR
trap 'rm -rf "$TEST_APT_DIR"' EXIT
mkdir "$TEST_APT_DIR/bin"
cat >"$TEST_APT_DIR/bin/apt-get" <<'BASH'
#!/usr/bin/env bash
case " $* " in
    *" update "*)
        echo update >>"$TEST_APT_DIR/calls"
        [[ "${TEST_APT_UPDATE_RC:-0}" == 0 ]] || exit "$TEST_APT_UPDATE_RC"
        touch "$TEST_APT_DIR/index"
        ;;
    *" install "*)
        echo install >>"$TEST_APT_DIR/calls"
        [[ -f "$TEST_APT_DIR/index" ]] || exit 100
        ;;
    *) exit 2 ;;
esac
BASH
cat >"$TEST_APT_DIR/bin/ufw" <<'BASH'
#!/usr/bin/env bash
echo ufw >>"$TEST_APT_DIR/calls"
BASH
chmod +x "$TEST_APT_DIR/bin/apt-get" "$TEST_APT_DIR/bin/ufw"
dind_exec() { PATH="$TEST_APT_DIR/bin:$PATH" bash -c "$1"; }
eval "$(sed -n '/^wireguard_add_enable_ufw()/,/^}/p' "$REPO_ROOT/tests/scenarios/wireguard-add-after-https.sh")"

# Given a fresh guest with no package index and no earlier installer scenario.
: >"$TEST_APT_DIR/calls"

# When the real fixture helper prepares UFW.
wireguard_add_enable_ufw
rc=$?

# Then it refreshes the index before installing and enabling the firewall.
assert_eq 0 "$rc" 'standalone WireGuard fixture prepares UFW from an empty package index'
assert_eq $'update\ninstall\nufw' "$(cat "$TEST_APT_DIR/calls")" 'package preparation precedes firewall enablement'

# Given a package index refresh that fails.
: >"$TEST_APT_DIR/calls"
export TEST_APT_UPDATE_RC=29

# When the fixture tries to prepare UFW.
wireguard_add_enable_ufw
rc=$?

# Then it reports failure without installing packages or changing the firewall.
assert_eq 29 "$rc" 'package index failure reaches the scenario'
assert_eq update "$(cat "$TEST_APT_DIR/calls")" 'failed package refresh stops dependent changes'
summary
