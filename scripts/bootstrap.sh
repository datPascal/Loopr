#!/bin/bash

set -euo pipefail

fail() {
    printf 'bootstrap: %s\n' "$1" >&2
    exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

for command_name in xcode-select xcrun jq plutil awk; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        fail "required macOS tool is unavailable: $command_name"
    fi
done

if ! active_developer_dir="$(xcode-select -p 2>&1)"; then
    fail "xcode-select -p failed: $active_developer_dir"
fi
if ! active_developer_dir="$(cd "$active_developer_dir" && pwd -P)"; then
    fail "active developer directory is unavailable: $active_developer_dir"
fi

xcrun_command="$(command -v xcrun)"
if ! xcodebuild_path="$("$xcrun_command" --find xcodebuild 2>&1)"; then
    fail "xcrun could not resolve xcodebuild through the active developer directory: $xcodebuild_path"
fi
if ! simctl_path="$("$xcrun_command" --find simctl 2>&1)"; then
    fail "xcrun could not resolve simctl through the active developer directory: $simctl_path"
fi

for tool_path in "$xcodebuild_path" "$simctl_path"; do
    if [[ ! -x "$tool_path" ]]; then
        fail "resolved developer tool is not executable: $tool_path"
    fi
    if ! tool_directory="$(cd "$(dirname "$tool_path")" && pwd -P)"; then
        fail "could not inspect resolved developer tool: $tool_path"
    fi
    tool_name="${tool_path##*/}"
    case "$tool_directory/$tool_name" in
        "$active_developer_dir"/*) ;;
        *) fail "resolved developer tool is outside the active developer directory: $tool_path" ;;
    esac
done

if ! xcode_version_output="$("$xcodebuild_path" -version 2>&1)"; then
    fail "xcodebuild -version failed: $xcode_version_output"
fi

xcode_version="$(awk '$1 == "Xcode" && NF == 2 { version = $2 } END { print version }' <<< "$xcode_version_output")"
xcode_build="$(awk '$1 == "Build" && $2 == "version" && NF == 3 { build = $3 } END { print build }' <<< "$xcode_version_output")"

if [[ ! "$xcode_version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    fail "could not parse a complete Xcode version from: $xcode_version_output"
fi
if [[ ! "$xcode_build" =~ ^[A-Za-z0-9]+$ ]]; then
    fail "could not parse a valid nonempty Xcode build identifier from: $xcode_version_output"
fi

xcode_major="${xcode_version%%.*}"
if (( xcode_major < 26 )); then
    fail "Xcode $xcode_version is too old for the iOS 26 source requirements"
fi

if ! xcode_sdks="$("$xcodebuild_path" -showsdks 2>&1)"; then
    fail "xcodebuild -showsdks failed: $xcode_sdks"
fi

ios_simulator_sdk_record="$(awk '
function version_is_newer(a, b, ap, bp, na, nb, i, ai, bi) {
    na = split(a, ap, ".")
    nb = split(b, bp, ".")
    for (i = 1; i <= na || i <= nb; i++) {
        ai = (i <= na) ? ap[i] + 0 : 0
        bi = (i <= nb) ? bp[i] + 0 : 0
        if (ai != bi) return ai > bi
    }
    return 0
}

{
    for (i = 1; i < NF; i++) {
        if ($i == "-sdk" && $(i + 1) ~ /^iphonesimulator26([.][0-9]+)*$/) {
            candidate_id = $(i + 1)
            candidate_version = candidate_id
            sub(/^iphonesimulator/, "", candidate_version)
            if (best_version == "" || version_is_newer(candidate_version, best_version)) {
                best_id = candidate_id
                best_version = candidate_version
            }
        }
    }
}

END {
    if (best_id != "") print best_id "\t" best_version
}
' <<< "$xcode_sdks")"
if [[ -z "$ios_simulator_sdk_record" ]]; then
    fail "the active Xcode toolchain has no iphonesimulator 26 SDK identifier"
fi

IFS=$'\t' read -r ios_simulator_sdk_identifier ios_simulator_sdk_expected_version <<< "$ios_simulator_sdk_record"
if ! ios_simulator_sdk_version="$("$xcrun_command" --sdk "$ios_simulator_sdk_identifier" --show-sdk-version 2>&1)"; then
    fail "xcrun could not inspect SDK $ios_simulator_sdk_identifier: $ios_simulator_sdk_version"
fi
if [[ "$ios_simulator_sdk_version" != "$ios_simulator_sdk_expected_version" ]]; then
    fail "SDK $ios_simulator_sdk_identifier reports version $ios_simulator_sdk_version, expected $ios_simulator_sdk_expected_version"
fi
if ! ios_simulator_sdk_path="$("$xcrun_command" --sdk "$ios_simulator_sdk_identifier" --show-sdk-path 2>&1)" ||
    [[ ! -d "$ios_simulator_sdk_path" ]]; then
    fail "xcrun did not return a usable path for SDK $ios_simulator_sdk_identifier: $ios_simulator_sdk_path"
fi

printf 'Active developer directory: %s\n' "$active_developer_dir"
printf 'Resolved xcodebuild: %s\n' "$xcodebuild_path"
printf 'Resolved simctl: %s\n' "$simctl_path"
printf 'Xcode: %s (build %s)\n' "$xcode_version" "$xcode_build"
printf 'iOS Simulator SDK: %s (version %s)\n' "$ios_simulator_sdk_identifier" "$ios_simulator_sdk_version"

# This bounded seam permits the required missing-runtime check without editing the script.
requested_ios_version="${LOOPR_BOOTSTRAP_IOS_VERSION:-26}"
if [[ ! "$requested_ios_version" =~ ^26(\.[0-9]+){0,2}$ ]]; then
    fail "LOOPR_BOOTSTRAP_IOS_VERSION must name an iOS 26 version (for example 26 or 26.2), got: $requested_ios_version"
fi

if ! available_devices_json="$("$xcrun_command" simctl list devices available --json 2>&1)"; then
    fail "xcrun simctl could not list available devices: $available_devices_json"
fi

if ! simulator_record="$(jq -r --arg requested "$requested_ios_version" '
[
  .devices
  | to_entries[]
  | .key as $runtime_key
  | select($runtime_key | test("^com\\.apple\\.CoreSimulator\\.SimRuntime\\.iOS-[0-9]+(-[0-9]+)*$"))
  | ($runtime_key | sub("^com\\.apple\\.CoreSimulator\\.SimRuntime\\.iOS-"; "") | split("-") | join(".")) as $runtime
  | select(if $requested == "26" then ($runtime | test("^26(\\.[0-9]+)*$")) else $runtime == $requested end)
  | .value[]
  | select(.isAvailable == true and (.deviceTypeIdentifier | startswith("com.apple.CoreSimulator.SimDeviceType.iPhone-")))
  | {runtime: $runtime, name: .name, udid: .udid}
]
| if length == 0 then empty else max_by(.runtime | split(".") | map(tonumber)) | [.runtime, .name, .udid] | @tsv end
' <<< "$available_devices_json" 2>&1)"; then
    fail "could not parse xcrun simctl JSON: $simulator_record"
fi

if [[ -z "$simulator_record" ]]; then
    fail "no available iPhone simulator was found for OS $requested_ios_version; inspect 'xcrun simctl list devices available --json' or set LOOPR_BOOTSTRAP_IOS_VERSION to an installed iOS 26 version"
fi

IFS=$'\t' read -r selected_runtime selected_device selected_udid <<< "$simulator_record"
if [[ ! "$selected_udid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    fail "selected simulator has an invalid UDID: $selected_udid"
fi
printf 'iOS simulator: runtime %s, device %s, UDID %s\n' "$selected_runtime" "$selected_device" "$selected_udid"

package_lock="$repo_root/LooprPackages/Package.resolved"
xcode_lock="$repo_root/Loopr/Loopr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
expected_identity='grdb.swift'
expected_location='https://github.com/groue/GRDB.swift.git'
expected_version='7.11.1'
expected_revision='b83108d10f42680d78f23fe4d4d80fc88dab3212'

lock_value() {
    local keypath="$1"
    local lock_path="$2"
    plutil -extract "$keypath" raw -o - -- "$lock_path" 2>/dev/null
}

validate_lock() {
    local lock_path="$1"
    local pin_count
    local document_version
    local kind
    local identity
    local location
    local version
    local revision

    if [[ -L "$lock_path" || ! -f "$lock_path" ]]; then
        printf 'lock must be a regular non-symlink file: %s\n' "$lock_path" >&2
        return 1
    fi
    if [[ ! -r "$lock_path" ]]; then
        printf 'lock is not readable: %s\n' "$lock_path" >&2
        return 1
    fi

    if ! plutil -convert json -o /dev/null -- "$lock_path" >/dev/null 2>&1; then
        printf 'invalid JSON lock: %s\n' "$lock_path" >&2
        return 1
    fi

    if ! document_version="$(lock_value version "$lock_path")" || [[ "$document_version" != '3' ]]; then
        printf 'expected SwiftPM lock format version 3 in: %s\n' "$lock_path" >&2
        return 1
    fi

    if ! pin_count="$(lock_value pins "$lock_path")" || [[ "$pin_count" != '1' ]]; then
        printf 'expected exactly one SwiftPM pin in: %s\n' "$lock_path" >&2
        return 1
    fi

    if lock_value pins.1.identity "$lock_path" >/dev/null 2>&1; then
        printf 'unexpected second SwiftPM pin in: %s\n' "$lock_path" >&2
        return 1
    fi

    if ! kind="$(lock_value pins.0.kind "$lock_path")" ||
        ! identity="$(lock_value pins.0.identity "$lock_path")" ||
        ! location="$(lock_value pins.0.location "$lock_path")" ||
        ! version="$(lock_value pins.0.state.version "$lock_path")" ||
        ! revision="$(lock_value pins.0.state.revision "$lock_path")"; then
        printf 'GRDB pin is incomplete in: %s\n' "$lock_path" >&2
        return 1
    fi

    [[ "$kind" == 'remoteSourceControl' ]] || {
        printf 'unexpected pin kind in %s: %s\n' "$lock_path" "$kind" >&2
        return 1
    }
    [[ "$identity" == "$expected_identity" ]] || {
        printf 'unexpected package identity in %s: %s\n' "$lock_path" "$identity" >&2
        return 1
    }
    [[ "$location" == "$expected_location" ]] || {
        printf 'unexpected package location in %s: %s\n' "$lock_path" "$location" >&2
        return 1
    }
    [[ "$version" == "$expected_version" ]] || {
        printf 'unexpected GRDB version in %s: %s\n' "$lock_path" "$version" >&2
        return 1
    }
    [[ "$revision" == "$expected_revision" ]] || {
        printf 'unexpected GRDB revision in %s: %s\n' "$lock_path" "$revision" >&2
        return 1
    }
}

if ! validate_lock "$package_lock"; then
    fail "GRDB resolution is not the accepted FND-02 pin in LooprPackages/Package.resolved"
fi
if ! validate_lock "$xcode_lock"; then
    fail "GRDB resolution is not the accepted FND-02 pin in the Xcode workspace lock"
fi

printf 'GRDB: %s at %s (consistent in both FND-02 locks)\n' "$expected_version" "$expected_revision"
printf 'bootstrap: dependency and tool validation passed\n'
