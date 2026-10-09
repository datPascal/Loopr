#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
analytics_root="$repo_root/OpenStrap Code/analytics"
guard="$repo_root/scripts/analytics_oracle_guard.py"
expected_ref="f0d115308aa5e9e3c82ee113c3d52e59756121d4"

fail() {
  printf 'analytics oracle: FAIL: %s\n' "$1" >&2
  exit 1
}

if [[ "${1:-}" == "--self-test" ]]; then
  shift
  [[ "$#" -eq 0 ]] || fail "usage: scripts/test-analytics-oracle.sh [--self-test]"
  python3 "$guard" --self-test
  exit 0
fi
[[ "$#" -eq 0 ]] || fail "usage: scripts/test-analytics-oracle.sh [--self-test]"

[[ -d "$analytics_root" ]] || fail "pinned analytics tree is missing: $analytics_root"
[[ -f "$guard" ]] || fail "oracle parser is missing: $guard"

actual_ref="$(git -C "$analytics_root" rev-parse HEAD 2>/dev/null)" ||
  fail "cannot resolve pinned analytics HEAD"
[[ "$actual_ref" == "$expected_ref" ]] ||
  fail "analytics HEAD is $actual_ref, expected pinned $expected_ref"

if [[ -n "$(git -C "$analytics_root" status --porcelain --untracked-files=all)" ]]; then
  fail "pinned analytics worktree is dirty"
fi

dart_bin="${LOOPR_DART_BIN:-}"
if [[ -z "$dart_bin" ]]; then
  dart_bin="$(command -v dart || true)"
fi
[[ -n "$dart_bin" && -x "$dart_bin" ]] ||
  fail "Dart SDK is required; set LOOPR_DART_BIN or put dart on PATH"

sdk_version="$($dart_bin --version 2>&1)" ||
  fail "could not query Dart SDK version"
[[ "$sdk_version" == *"Dart SDK version: 3.5.4"* ]] ||
  fail "expected Dart SDK 3.5.4, got: $sdk_version"

python_bin="$(command -v python3 || true)"
[[ -n "$python_bin" && -x "$python_bin" ]] ||
  fail "python3 is required for JSON report validation"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/loopr-analytics-oracle.XXXXXX")"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

host_report="$work_dir/host.json"
utc_report="$work_dir/utc.json"
host_stderr="$work_dir/host.stderr"
utc_stderr="$work_dir/utc.stderr"

# Deliberately do not assign TZ for this invocation.  It observes the caller's
# host timezone.  The only TZ override below is attached to the UTC command and
# therefore cannot leak into this script's environment or the caller's shell.
host_status=0
if (
  cd "$analytics_root"
  "$dart_bin" test --reporter json --no-color --concurrency=1 --no-retry
) >"$host_report" 2>"$host_stderr"; then
  host_status=0
else
  host_status=$?
fi

utc_status=0
if (
  cd "$analytics_root"
  TZ=UTC "$dart_bin" test --reporter json --no-color --concurrency=1 --no-retry
) >"$utc_report" 2>"$utc_stderr"; then
  utc_status=0
else
  utc_status=$?
fi

"$python_bin" "$guard" validate \
  "$host_report" "$utc_report" "$host_status" "$utc_status"

printf 'analytics oracle: pinned ref = %s\n' "$expected_ref"
printf 'analytics oracle: host exit = %s; TZ=UTC exit = %s\n' "$host_status" "$utc_status"
