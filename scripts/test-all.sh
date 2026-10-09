#!/bin/bash

set -euo pipefail
umask 077

inherited_functions=""
if inherited_functions="$(builtin compgen -A function)"; then
    builtin printf 'test-all: inherited exported Bash functions are not allowed: %s\n' "$inherited_functions" >&2
    builtin exit 1
else
    compgen_status=$?
    if (( compgen_status != 1 )); then
        builtin printf 'test-all: could not inspect inherited exported Bash functions\n' >&2
        builtin exit 1
    fi
fi

if [[ -n "${LOOPR_TEST_LOCK_HELD+x}" || -n "${LOOPR_TEST_LANE+x}" ||
    -n "${LOOPR_TEST_MODE+x}" || -n "${LOOPR_TEST_ONLY_TESTING+x}" ||
    -n "${LOOPR_TEST_FOCUS+x}" ]]; then
    builtin printf 'test-all: inherited test-lane control variables are not allowed\n' >&2
    builtin exit 1
fi

if [[ "$#" -ne 0 ]]; then
    builtin printf 'test-all: does not accept command-line arguments\n' >&2
    builtin exit 1
fi

# Full-lane selection is fixed by this wrapper, never inherited from the caller.
dirname_bin=/usr/bin/dirname
if [[ ! -f "$dirname_bin" || ! -x "$dirname_bin" ]]; then
    builtin printf 'test-all: required absolute tool is unavailable or not executable: %s\n' "$dirname_bin" >&2
    builtin exit 1
fi
script_dir="$(builtin cd -- "$($dirname_bin "${BASH_SOURCE[0]}")" && builtin pwd -P)"
exec /bin/bash "$script_dir/test-fast.sh" --loopr-full
