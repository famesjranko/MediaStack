#!/usr/bin/env bash
# Owns: action_* — The day-2 uninstall entry point.
# Sources: launcher globals, .env, setup.sh, and the shared action-result renderer.

action_uninstall() { _run_setup_return 1 "Uninstall" --uninstall; }
