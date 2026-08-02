# Shared step-builder for the wizard-ui PTY scenarios.
#
# Builds a wizard_pty.py steps-JSON on the DinD box from NAMED prompts in the shared SSOT
# (tests/lib/wizard_prompts.json) via tests/lib/wizard_steps_build.py, so every wizard prompt
# regex lives in ONE place — shared across the stage1/stage2/stage3 scenarios and the
# maintainer-private bare-metal harness. A prompt change is made once and all surfaces track it.
#
#   wizard_build_steps <steps_path> [<prompt_name> <send> ...]
#
# Each (name, send) pair emits {"expect": <regex-from-SSOT>} then a send, where the send token is:
#   ENTER  -> {"send": "\n"}        (accept the default / just press Enter)
#   NONE   -> no send               (an expect with no following input)
#   X      -> {"send": "X\n"}       (send the keystroke(s) X then Enter)
# No pairs => []. Args are controlled literal tokens in the scenario source (prompt names +
# shell-safe sends, no spaces), so word-splitting them into the builder is intended.
wizard_build_steps() {
    local steps_path="$1"
    shift
    dind_exec "python3 tests/lib/wizard_steps_build.py $* > $steps_path"
}
