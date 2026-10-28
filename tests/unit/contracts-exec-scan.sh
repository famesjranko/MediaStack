#!/usr/bin/env bash
# tests/unit/contracts-exec-scan.sh
#
# Proves that tests/contracts/exec_scan.py fails closed: each docker exec form
# it cannot read is an error, never a skip. It covers the refused forms
# (`docker compose exec`, `docker container exec`, an unknown exec flag, exec
# in a `for` list), the forms it reads (a command substitution inside double
# quotes, a variable bound once, an array behind sudo), the possible calls it
# cannot read (`sh -c "docker exec ..."`, `$DOCKER exec`, docker global
# flags), the variables it cannot follow (several values, read), and the
# dry-run sandbox exclusion, which holds only for one variable in one file.
# Each case scans a small script against the real inventory, scoped as
# tests/contracts/check.py scopes it. Pure python3, no Docker.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="contracts-exec-scan"
scenario_begin "$CURRENT_SCENARIO"

results=$(
    python3 -I - "$REPO_ROOT" <<'PY'
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "tests/contracts"))
import check  # noqa: E402
import exec_scan  # noqa: E402
import inventory  # noqa: E402

FOUND = inventory.load_exec()
PROBE = "scripts/lib/probe.sh"
RELOAD = "fail2ban fail2ban-client reload"


def scan(text, relative=PROBE):
    """The entry ids reached and the errors, as check.py scans one file."""
    text = text.replace("\\\n", " ")
    spans = check._script_file(relative, text).spans
    result = exec_scan.ExecScan(FOUND)
    script = exec_scan.Script(relative, text, lambda position: check._scope(spans, position))
    exec_scan.scan_script(result, script)
    return [entry.id for entry, _ in result.calls], result.errors


def kinds(errors):
    return [error.split(":", 1)[0] for error in errors]


class RefusedForms(unittest.TestCase):
    def test_compose_exec_is_refused(self):
        # Given a docker compose exec into fail2ban, which the shim does not record.
        text = f"probe() {{ docker compose exec {RELOAD}; }}\n"

        # When the script is scanned.
        calls, errors = scan(text)

        # Then no call is read and the form is refused as unparseable.
        self.assertEqual(calls, [])
        self.assertEqual(errors, [f"unparseable exec: {PROBE}: docker compose exec {RELOAD}; }}"])

    def test_container_exec_is_refused(self):
        # Given a docker container exec into fail2ban, which the shim does not record.
        text = f"probe() {{ docker container exec {RELOAD}; }}\n"

        # When the script is scanned.
        calls, errors = scan(text)

        # Then no call is read and the form is refused as unparseable.
        self.assertEqual(calls, [])
        self.assertEqual(errors, [f"unparseable exec: {PROBE}: docker container exec {RELOAD}; }}"])

    def test_unknown_exec_flag_is_refused(self):
        # Given a docker exec with a flag the scan does not know.
        text = f"probe() {{ docker exec --frobnicate {RELOAD}; }}\n"

        # When the script is scanned.
        calls, errors = scan(text)

        # Then the flag is not skipped: the call is unparseable.
        self.assertEqual((calls, kinds(errors)), ([], ["unparseable exec"]))

    def test_exec_in_a_for_list_is_refused(self):
        # Given a variable subcommand whose for list holds exec.
        text = f'probe() {{\n    local kind\n    for kind in ps exec; do docker "$kind" {RELOAD}; done\n}}\n'

        # When the script is scanned.
        calls, errors = scan(text)

        # Then the call is unparseable.
        self.assertEqual((calls, kinds(errors)), ([], ["unparseable exec"]))


class ReadForms(unittest.TestCase):
    def test_command_substitution_in_double_quotes_is_a_call(self):
        # Given a docker exec inside "$( ... )".
        text = f'probe() {{ out="$(docker exec {RELOAD})"; }}\n'

        # When the script is scanned.
        calls, errors = scan(text)

        # Then it is read as the reload call, with no error.
        self.assertEqual((calls, errors), (["client-reload"], []))

    def test_array_behind_sudo_is_read(self):
        # Given sudo docker "${args[@]}" with args assigned once to an exec.
        text = f'probe() {{\n    local args=(exec {RELOAD})\n    sudo docker "${{args[@]}}"\n}}\n'

        # When the script is scanned.
        calls, errors = scan(text)

        # Then it is read as the reload call.
        self.assertEqual((calls, errors), (["client-reload"], []))

    def test_array_assigned_twice_is_unparseable(self):
        # Given an args array assigned a harmless value, then an exec.
        text = (f'probe() {{\n    local args=(ps)\n    args=(exec {RELOAD})\n'
                '    docker "${args[@]}"\n}\n')

        # When the script is scanned.
        calls, errors = scan(text)

        # Then neither value is taken: the call is unparseable.
        self.assertEqual((calls, kinds(errors)), ([], ["unparseable exec"]))

    def test_container_assigned_one_name_twice_is_read(self):
        # Given a container variable assigned fail2ban twice.
        text = ('probe() {\n    local box=fail2ban\n    box=fail2ban\n'
                '    docker exec "$box" fail2ban-client reload\n}\n')

        # When the script is scanned.
        calls, errors = scan(text)

        # Then the call is read as the reload call.
        self.assertEqual((calls, errors), (["client-reload"], []))

    def test_container_assigned_two_names_is_unparseable(self):
        # Given a container variable assigned npm and then fail2ban.
        text = ('probe() {\n    local box=npm\n    box=fail2ban\n'
                '    docker exec "$box" fail2ban-client reload\n}\n')

        # When the script is scanned.
        calls, errors = scan(text)

        # Then neither name is taken: the call is unparseable.
        self.assertEqual((calls, kinds(errors)), ([], ["unparseable exec"]))

    def test_container_set_by_read_is_unparseable(self):
        # Given a container variable assigned fail2ban and then set by read.
        text = ('probe() {\n    local box=fail2ban\n    read -r box\n'
                '    docker exec "$box" fail2ban-client reload\n}\n')

        # When the script is scanned.
        calls, errors = scan(text)

        # Then the assignment is not trusted: the call is unparseable.
        self.assertEqual((calls, kinds(errors)), ([], ["unparseable exec"]))

    def test_container_from_a_for_list_counts_every_value(self):
        # Given a container variable assigned npm and looped over fail2ban.
        text = ('probe() {\n    local box=npm\n'
                '    for box in fail2ban; do docker exec "$box" fail2ban-client reload; done\n}\n')

        # When the script is scanned.
        calls, errors = scan(text)

        # Then the variable may name two services: the call is unparseable.
        self.assertEqual((calls, kinds(errors)), ([], ["unparseable exec"]))


class PossibleCalls(unittest.TestCase):
    def test_each_unread_form_is_an_error(self):
        # Given lines that may run a docker exec in a way the scan does not read.
        lines = [f'sh -c "docker exec {RELOAD}"', f'bash -c "docker exec {RELOAD}"',
                 f'eval "docker exec {RELOAD}"', f"$DOCKER exec {RELOAD}",
                 f"docker -H unix:///run/x.sock exec {RELOAD}",
                 f"docker --context remote exec {RELOAD}", f"docker-compose exec {RELOAD}"]

        for line in lines:
            with self.subTest(line=line):
                # When a script with the line is scanned.
                calls, errors = scan(f"probe() {{ {line}; }}\n")

                # Then no call is read and the line is a possible call not parsed.
                self.assertEqual((calls, kinds(errors)), ([], ["possible exec call not parsed"]))

    def test_unbound_subcommand_behind_a_wrapper_is_unparseable(self):
        # Given sudo and timeout before docker with an unbound variable subcommand.
        lines = ['sudo docker "${args[@]}"', f'timeout 5 docker "$sub" {RELOAD}']

        for line in lines:
            with self.subTest(line=line):
                # When a script with the line is scanned.
                calls, errors = scan(f"probe() {{ {line}; }}\n")

                # Then the call is unparseable.
                self.assertEqual((calls, kinds(errors)), ([], ["unparseable exec"]))

    def test_comment_is_passed_over(self):
        # Given a comment that names a docker exec.
        text = "    # Inspect with: docker exec npm nginx -t\n"

        # When the script is scanned.
        found = scan(text)

        # Then nothing is read and nothing fails.
        self.assertEqual(found, ([], []))

    def test_message_is_passed_over_only_where_listed(self):
        # Given the listed npm message line.
        line = 'log_error "Unknown corruption - inspect: docker exec npm nginx -t"\n'

        # When it is scanned in its own file and in another file.
        own = scan(line, "scripts/services/npm/health.sh")
        other = scan(line)

        # Then only its own file passes it over.
        self.assertEqual(own, ([], []))
        self.assertEqual(kinds(other[1]), ["possible exec call not parsed"])


class DryRunExclusion(unittest.TestCase):
    def test_sandbox_variable_is_excluded_only_in_dry_run(self):
        # Given the sandbox exec into "$cname".
        line = 'probe() { docker exec -u mstest "$cname" mkdir -p /x; }\n'

        # When it is scanned in scripts/lib/dry-run.sh and in another file.
        own = scan(line, "scripts/lib/dry-run.sh")
        other = scan(line)

        # Then only dry-run.sh excludes it.
        self.assertEqual(own, ([], []))
        self.assertEqual(kinds(other[1]), ["unparseable exec"])

    def test_other_variable_in_dry_run_is_checked(self):
        # Given an exec into another unbound variable in scripts/lib/dry-run.sh.
        line = 'probe() { docker exec "$other" fail2ban-client reload; }\n'

        # When it is scanned.
        calls, errors = scan(line, "scripts/lib/dry-run.sh")

        # Then the exclusion does not cover it: the call is unparseable.
        self.assertEqual((calls, kinds(errors)), ([], ["unparseable exec"]))


class Lines(unittest.TestResult):
    def addSuccess(self, test):
        super().addSuccess(test)
        print(f"PASS\t{test.id().rsplit('.', 1)[-1]}")

    def _bad(self, test, err):
        print(f"FAIL\t{getattr(test, 'id', lambda: str(test))().rsplit('.', 1)[-1]}")
        print(self._exc_info_to_string(err, test), file=sys.stderr)

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self._bad(test, err)

    def addError(self, test, err):
        super().addError(test, err)
        self._bad(test, err)

    def addSubTest(self, test, subtest, err):
        super().addSubTest(test, subtest, err)
        if err is not None:
            self._bad(subtest, err)


result = Lines()
unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]).run(result)
sys.exit(0 if result.wasSuccessful() and result.testsRun else 1)
PY
)
rc=$?

while IFS=$'\t' read -r status name; do
    case "$status" in
        PASS) pass "$name" ;;
        FAIL) fail "$name" ;;
    esac
done <<<"$results"
[[ "$results" == *PASS* ]] || fail "contract exec scan cases ran" "no case reported a result"
((rc == 0)) || fail "contract exec scan suite exits cleanly" "python exited $rc"

scenario_end "$CURRENT_SCENARIO"
summary
