#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_root="$repo_root/Fixtures/Analytics"
determinism=0
if [[ "${1:-}" == "--determinism" ]]; then
  determinism=1
elif [[ -n "${1:-}" ]]; then
  case "$1" in
    /*) fixture_root="$1" ;;
    *) fixture_root="$repo_root/$1" ;;
  esac
  if [[ "${2:-}" == "--determinism" ]]; then determinism=1; fi
fi
if [[ ! -d "$fixture_root" ]]; then
  echo "analytics parity: fixture directory does not exist: $fixture_root" >&2
  exit 64
fi
if ! command -v dart >/dev/null 2>&1; then
  echo "analytics parity: dart SDK is required (run dart --version)" >&2
  exit 69
fi

swift_package="$repo_root/LooprPackages"
manifest="$repo_root/Fixtures/Analytics/tolerance-manifest.json"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/loopr-analytics-parity.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

# Build once, then invoke the exact same executable for every fixture. Calling
# `swift run` per side/per fixture repeatedly replans the package graph and can
# turn a deterministic 50-fixture comparison into minutes of build overhead.
swift build --package-path "$swift_package" --product AnalyticsParityCLI >/dev/null
swift_bin_dir="$(swift build --package-path "$swift_package" --show-bin-path)"
swift_runner="$swift_bin_dir/AnalyticsParityCLI"
if [[ ! -x "$swift_runner" ]]; then
  echo "analytics parity: Swift runner was not built: $swift_runner" >&2
  exit 69
fi

fixtures=()
while IFS= read -r fixture; do
  fixtures+=("$fixture")
done < <(find "$fixture_root" -type f -name '*.input.json' -print | sort)
if [[ "${#fixtures[@]}" -eq 0 ]]; then
  echo "analytics parity: no *.input.json fixtures under $fixture_root" >&2
  exit 65
fi

echo "analytics parity: ${#fixtures[@]} fixture(s)"
fixture_index=0
for fixture in "${fixtures[@]}"; do
  fixture_index=$((fixture_index + 1))
  stem="fixture-${fixture_index}"
  dart_output="$work_dir/$stem.dart.json"
  swift_output="$work_dir/$stem.swift.json"
  echo "[$fixture_index/${#fixtures[@]}] ${fixture#$repo_root/}"
  (
    cd "$repo_root/Tools/AnalyticsParity"
    dart run bin/parity_runner.dart "$fixture"
  ) >"$dart_output"
  "$swift_runner" run "$fixture" >"$swift_output"
  # Test-only failure injection.  CI can prove that a deliberately corrupted
  # Swift artifact is rejected by setting this environment variable; normal
  # runs never mutate either CLI's output.
  if [[ "${LOOPR_ANALYTICS_PARITY_CORRUPT_SWIFT_OUTPUT:-0}" == "1" ]]; then
    if ! grep -q '"algorithm_version":"' "$swift_output"; then
      echo "analytics parity: cannot corrupt Swift output (algorithm_version missing)" >&2
      exit 70
    fi
    perl -0pi -e 's/"algorithm_version":"[^"]+"/"algorithm_version":"__deliberate_corruption__"/' "$swift_output"
  fi
  "$swift_runner" compare "$dart_output" "$swift_output" "$manifest"
  if [[ "$determinism" -eq 1 ]]; then
    dart_repeat="$work_dir/$stem.dart.repeat.json"
    swift_repeat="$work_dir/$stem.swift.repeat.json"
    (
      cd "$repo_root/Tools/AnalyticsParity"
      dart run bin/parity_runner.dart "$fixture"
    ) >"$dart_repeat"
    "$swift_runner" run "$fixture" >"$swift_repeat"
    if ! cmp -s "$dart_output" "$dart_repeat"; then
      echo "analytics parity: FAIL nondeterministic Dart output for ${fixture#$repo_root/}" >&2
      exit 1
    fi
    if ! cmp -s "$swift_output" "$swift_repeat"; then
      echo "analytics parity: FAIL nondeterministic Swift output for ${fixture#$repo_root/}" >&2
      exit 1
    fi
  fi
done
echo "analytics parity: PASS"
