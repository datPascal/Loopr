#!/bin/bash

set -euo pipefail
umask 077

lane_name="test-fast"
full_lane=0
visual_lane=0
visual_dry_run=0
phase06_visual_lane=0
if [[ "${1:-}" == "--loopr-full" ]]; then
    lane_name="test-all"
    full_lane=1
elif [[ "${1:-}" == "--loopr-visual" ]]; then
    lane_name="test-visual"
    visual_lane=1
    if [[ "${2:-}" == "--phase06" ]]; then
        phase06_visual_lane=1
        if [[ "${3:-}" == "--loopr-dry-run" ]]; then
            visual_dry_run=1
        fi
    elif [[ "${2:-}" == "--loopr-dry-run" ]]; then
        visual_dry_run=1
    fi
fi

inherited_functions=""
if inherited_functions="$(builtin compgen -A function)"; then
    builtin printf '%s: inherited exported Bash functions are not allowed: %s\n' "$lane_name" "$inherited_functions" >&2
    builtin exit 1
else
    compgen_status=$?
    if (( compgen_status != 1 )); then
        builtin printf '%s: could not inspect inherited exported Bash functions\n' "$lane_name" >&2
        builtin exit 1
    fi
fi

if [[ -n "${LOOPR_TEST_LANE+x}" || -n "${LOOPR_TEST_MODE+x}" ||
    -n "${LOOPR_TEST_ONLY_TESTING+x}" || -n "${LOOPR_TEST_FOCUS+x}" ]]; then
    builtin printf '%s: inherited test-lane control variables are not allowed\n' "$lane_name" >&2
    builtin exit 1
fi

lock_reexec=0
if [[ -n "${LOOPR_TEST_LOCK_HELD+x}" ]]; then
    valid_lock_marker=0
    if (( visual_lane )); then
        if (( visual_dry_run )); then
            if (( phase06_visual_lane )); then
                if [[ "$#" -eq 4 && "${1:-}" == "--loopr-visual" &&
                    "${2:-}" == "--phase06" && "${3:-}" == "--loopr-dry-run" &&
                    "${4:-}" == "--loopr-lock-held" ]]; then
                    valid_lock_marker=1
                fi
            elif [[ "$#" -eq 3 && "${1:-}" == "--loopr-visual" &&
                "${2:-}" == "--loopr-dry-run" && "${3:-}" == "--loopr-lock-held" ]]; then
                valid_lock_marker=1
            fi
        elif (( phase06_visual_lane )); then
            if [[ "$#" -eq 3 && "${1:-}" == "--loopr-visual" &&
                "${2:-}" == "--phase06" && "${3:-}" == "--loopr-lock-held" ]]; then
                valid_lock_marker=1
            fi
        elif [[ "$#" -eq 2 && "${1:-}" == "--loopr-visual" &&
            "${2:-}" == "--loopr-lock-held" ]]; then
            valid_lock_marker=1
        fi
    elif (( full_lane )); then
        if [[ "$#" -eq 2 && "${1:-}" == "--loopr-full" &&
            "${2:-}" == "--loopr-lock-held" ]]; then
            valid_lock_marker=1
        fi
    elif [[ "$#" -eq 1 && "${1:-}" == "--loopr-lock-held" ]]; then
        valid_lock_marker=1
    fi
    if [[ "${LOOPR_TEST_LOCK_HELD}" != 1 || "$valid_lock_marker" -ne 1 ]]; then
        builtin printf '%s: inherited lock/mode control is not a valid internal re-exec marker\n' "$lane_name" >&2
        builtin exit 1
    fi
    lock_reexec=1
fi

xcodebuild_bin=/usr/bin/xcodebuild
xcrun_bin=/usr/bin/xcrun
jq_bin=/usr/bin/jq
lockf_bin=/usr/bin/lockf
ps_bin=/bin/ps
awk_bin=/usr/bin/awk
stat_bin=/usr/bin/stat
id_bin=/usr/bin/id
lsof_bin=/usr/sbin/lsof
chmod_bin=/bin/chmod
mkdir_bin=/bin/mkdir
mktemp_bin=/usr/bin/mktemp
dirname_bin=/usr/bin/dirname

fail() {
    printf '%s: %s\n' "$lane_name" "$1" >&2
    exit 1
}

for tool_path in "$xcodebuild_bin" "$xcrun_bin" "$jq_bin" "$lockf_bin" "$ps_bin" "$awk_bin" \
    "$stat_bin" "$id_bin" "$lsof_bin" "$chmod_bin" "$mkdir_bin" "$mktemp_bin" "$dirname_bin"; do
    if [[ "$tool_path" != /* || ! -f "$tool_path" || ! -x "$tool_path" ]]; then
        fail "required absolute tool is unavailable or not executable: $tool_path"
    fi
done

run_command() {
    local label="$1"
    shift

    printf '%s: starting %s\n' "$lane_name" "$label"
    if "$@"; then
        printf '%s: %s passed\n' "$lane_name" "$label"
    else
        local status=$?
        printf '%s: %s failed with exit %d; stopping without retry\n' "$lane_name" "$label" "$status" >&2
        exit "$status"
    fi
}

assert_no_active_test_processes() {
    local process_list=""
    local active_processes=""

    if ! process_list="$("$ps_bin" -axo pid=,comm=,args= 2>&1)"; then
        fail "could not inspect the repo-wide process table around lock acquisition: $process_list"
    fi
    # Actions are exact whitespace-delimited fields, never slash boundaries. A literal path
    # component named "test" surrounded by spaces is conservatively indistinguishable from one.
    if ! active_processes="$("$awk_bin" '
function has_action(action, field) {
    for (field = 3; field <= NF; field++) {
        if ($field == action) {
            return 1
        }
    }
    return 0
}
{
    if (NF < 2 || $1 !~ /^[0-9]+$/ || $2 == "") {
        print "process guard parser error: malformed ps record: " $0
        exit 2
    }
    executable = $2
    sub("^.*/", "", executable)
    if (executable == "xctest" || executable ~ /[.]xctest$/ ||
        (executable == "xcodebuild" && (has_action("test") || has_action("test-without-building"))) ||
        (executable == "swift" && has_action("test"))) {
        print $0
    }
}
' <<< "$process_list" 2>&1)"; then
        fail "could not parse the repo-wide process table around lock acquisition: $active_processes"
    fi
    if [[ -n "$active_processes" ]]; then
        fail "refusing to start while test processes are already active repo-wide: $active_processes"
    fi
}

require_test_result() {
    local label="$1"
    local result_path="$2"
    local expected_plan="$3"
    local expected_targets_csv="$4"
    local summary_json=""
    local summary_values=""
    local tests_json=""
    local test_values=""
    local coverage_json=""
    local coverage_value=""
    local total_test_count=""
    local passed_tests=""
    local failed_tests=""
    local skipped_tests=""
    local expected_failures=""
    local result_status=""
    local target_values=""
    local destination_records=""
    local test_case_count=""

    if [[ ! -d "$result_path" || -L "$result_path" ]]; then
        fail "$label did not produce the expected non-symlink .xcresult bundle: $result_path"
    fi
    printf '%s: inspecting %s with Xcode 26 xcresulttool\n' "$lane_name" "$result_path"

    if ! summary_json="$("$xcrun_bin" xcresulttool get test-results summary --schema-version 0.1.0 --path "$result_path" 2>&1)"; then
        fail "$label .xcresult inspection failed: $summary_json"
    fi
    if ! summary_values="$("$jq_bin" -er --arg selected_udid "$selected_udid" --arg selected_device "$selected_device" --arg selected_runtime "$selected_runtime" '
def nonnegative_integer:
  if type != "number" then false else (. == floor and . >= 0) end;
# CoreSimulator runtime identifiers carry the selected precision; xcresult may add numeric patch components.
def version_prefix_matches($actual; $selected):
  ($actual | split(".")) as $actual_parts
  | ($selected | split(".")) as $selected_parts
  | all($actual_parts[]; test("^[0-9]+$"))
    and all($selected_parts[]; test("^[0-9]+$"))
    and ($actual_parts | length) >= ($selected_parts | length)
    and all(range(0; ($selected_parts | length)); $actual_parts[.] == $selected_parts[.]);
if type != "object" then
  error("summary root is not an object")
elif ((has("title") and has("environmentDescription") and has("topInsights") and has("result") and has("totalTestCount") and has("passedTests") and has("failedTests") and has("skippedTests") and has("expectedFailures") and has("statistics") and has("devicesAndConfigurations") and has("testFailures")) | not) then
  error("summary is missing a required Xcode 26 field")
elif ((.title | type) != "string" or (.environmentDescription | type) != "string" or (.topInsights | type) != "array" or (.statistics | type) != "array" or (.devicesAndConfigurations | type) != "array" or (.testFailures | type) != "array") then
  error("summary has an unexpected Xcode 26 field type")
elif ((.result | type) != "string") then
  error("summary result is not a string")
elif ((.result == "Passed" or .result == "Failed" or .result == "Skipped" or .result == "Expected Failure" or .result == "unknown") | not) then
  error("summary result has an unknown value")
elif ((.totalTestCount | nonnegative_integer) | not) or ((.passedTests | nonnegative_integer) | not) or ((.failedTests | nonnegative_integer) | not) or ((.skippedTests | nonnegative_integer) | not) or ((.expectedFailures | nonnegative_integer) | not) then
  error("summary test counts are not non-negative integers")
elif .totalTestCount <= 0 then
  error("summary reported no executed tests")
elif .failedTests != 0 or .skippedTests != 0 or .expectedFailures != 0 then
  error("summary reported failures, skips, or expected failures")
elif .passedTests != .totalTestCount or .result != "Passed" then
  error("summary did not report an all-passed result")
elif (.testFailures | length) != 0 then
  error("summary contains test failures")
elif (.devicesAndConfigurations | length) == 0 then
  error("summary contains no device/configuration evidence")
elif any(.devicesAndConfigurations[]; type != "object") then
  error("summary device/configuration entry has an unexpected type")
elif any(.devicesAndConfigurations[]; ((has("device") and has("testPlanConfiguration") and has("passedTests") and has("failedTests") and has("skippedTests") and has("expectedFailures")) | not)) then
  error("summary device/configuration entry is missing a required field")
elif any(.devicesAndConfigurations[]; ((.device | type) != "object" or (.testPlanConfiguration | type) != "object")) then
  error("summary device/configuration child has an unexpected type")
elif any(.devicesAndConfigurations[]; ((.device | (has("deviceId") and has("deviceName") and has("architecture") and has("modelName") and has("platform") and has("osVersion"))) | not)) then
  error("summary device is missing a required Xcode 26 field")
elif any(.devicesAndConfigurations[]; ((.device.deviceId | type) != "string" or (.device.deviceName | type) != "string" or (.device.architecture | type) != "string" or (.device.modelName | type) != "string" or (.device.platform | type) != "string" or (.device.osVersion | type) != "string")) then
  error("summary device has an unexpected Xcode 26 field type")
elif any(.devicesAndConfigurations[]; ((.testPlanConfiguration | (has("configurationId") and has("configurationName"))) | not)) then
  error("summary test-plan configuration is missing a required Xcode 26 field")
elif any(.devicesAndConfigurations[]; ((.testPlanConfiguration.configurationId | type) != "string" or (.testPlanConfiguration.configurationName | type) != "string")) then
  error("summary test-plan configuration has an unexpected Xcode 26 field type")
elif any(.devicesAndConfigurations[]; ((.passedTests | nonnegative_integer) | not) or ((.failedTests | nonnegative_integer) | not) or ((.skippedTests | nonnegative_integer) | not) or ((.expectedFailures | nonnegative_integer) | not)) then
  error("summary device/configuration counts are not non-negative integers")
elif any(.devicesAndConfigurations[]; ((.device.deviceId | ascii_downcase) != ($selected_udid | ascii_downcase) or .device.deviceName != $selected_device or .device.platform != "iOS Simulator" or (version_prefix_matches(.device.osVersion; $selected_runtime) | not))) then
  error("summary device evidence does not match the selected iOS 26 simulator")
else
  [.totalTestCount, .passedTests, .failedTests, .skippedTests, .expectedFailures, .result] | @tsv
end
' <<< "$summary_json" 2>&1)"; then
        fail "$label .xcresult summary failed schema/evidence validation: $summary_values"
    fi

    IFS=$'\t' read -r total_test_count passed_tests failed_tests skipped_tests expected_failures result_status <<< "$summary_values"
    if [[ ! "$total_test_count" =~ ^[0-9]+$ || ! "$passed_tests" =~ ^[0-9]+$ ||
        ! "$failed_tests" =~ ^[0-9]+$ || ! "$skipped_tests" =~ ^[0-9]+$ ||
        ! "$expected_failures" =~ ^[0-9]+$ ]]; then
        fail "$label .xcresult summary counts were not exact integers"
    fi

    if ! tests_json="$("$xcrun_bin" xcresulttool get test-results tests --schema-version 0.1.0 --path "$result_path" 2>&1)"; then
        fail "$label .xcresult test-tree inspection failed: $tests_json"
    fi
    if ! test_values="$("$jq_bin" -er --arg expected_plan "$expected_plan" \
        --arg expected_targets "$expected_targets_csv" \
        --arg selected_udid "$selected_udid" \
        --arg selected_device "$selected_device" \
        --arg selected_runtime "$selected_runtime" '
# Keep destination matching exact while allowing only numeric xcresult patch components.
def version_prefix_matches($actual; $selected):
  ($actual | split(".")) as $actual_parts
  | ($selected | split(".")) as $selected_parts
  | all($actual_parts[]; test("^[0-9]+$"))
    and all($selected_parts[]; test("^[0-9]+$"))
    and ($actual_parts | length) >= ($selected_parts | length)
    and all(range(0; ($selected_parts | length)); $actual_parts[.] == $selected_parts[.]);
. as $test_tree |
([$test_tree | .. | objects | select(has("nodeType"))]) as $nodes |
if ($test_tree | type) != "object" then
  error("test-tree root is not an object")
elif ((($test_tree | has("testPlanConfigurations") and has("devices") and has("testNodes")) | not)) then
  error("test-tree is missing a required Xcode 26 field")
elif (($test_tree.testPlanConfigurations | type) != "array" or ($test_tree.devices | type) != "array" or ($test_tree.testNodes | type) != "array") then
  error("test-tree has an unexpected Xcode 26 root field type")
elif ($test_tree.testPlanConfigurations | length) == 0 or ($test_tree.devices | length) == 0 or ($test_tree.testNodes | length) == 0 then
  error("test-tree has no test plan, destination, or test nodes")
elif any($test_tree.testPlanConfigurations[]; type != "object") then
  error("test-plan configuration has an unexpected type")
elif any($test_tree.testPlanConfigurations[]; ((has("configurationId") and has("configurationName")) | not)) then
  error("test-plan configuration is missing a required field")
elif any($test_tree.testPlanConfigurations[]; ((.configurationId | type) != "string" or (.configurationName | type) != "string")) then
  error("test-plan configuration has an unexpected field type")
elif any($test_tree.devices[]; type != "object") then
  error("destination entry has an unexpected type")
elif any($test_tree.devices[]; ((has("deviceId") and has("deviceName") and has("architecture") and has("modelName") and has("platform") and has("osVersion")) | not)) then
  error("destination entry is missing a required field")
elif any($test_tree.devices[]; ((.deviceId | type) != "string" or (.deviceName | type) != "string" or (.architecture | type) != "string" or (.modelName | type) != "string" or (.platform | type) != "string" or (.osVersion | type) != "string")) then
  error("destination entry has an unexpected field type")
elif any($nodes[]; ((has("name") and has("nodeType")) | not)) then
  error("test node is missing a required field")
elif any($nodes[]; ((.name | type) != "string" or (.nodeType | type) != "string")) then
  error("test node has an unexpected required field type")
elif any($nodes[]; .nodeType as $node_type | (["Test Plan", "Unit test bundle", "UI test bundle", "Test Suite", "Test Case", "Device", "Test Plan Configuration", "Arguments", "Repetition", "Test Case Run", "Failure Message", "Source Code Reference", "Attachment", "Expression", "Test Value", "Runtime Warning"] | index($node_type)) == null) then
  error("test tree contains an unknown Xcode 26 node type")
elif any($nodes[]; (has("children") and ((.children | type) != "array"))) then
  error("test node children has an unexpected type")
elif any($nodes[]; (has("result") and ((.result | type) != "string"))) then
  error("test node result has an unexpected type")
elif any($nodes[]; (has("result") and (.result as $node_result | (["Passed", "Failed", "Skipped", "Expected Failure", "unknown"] | index($node_result)) == null))) then
  error("test tree contains an unknown test result")
 # Xcode 26.3 emits results on every test node; an absent result is fail-closed.
elif any($nodes[]; (has("result") | not)) then
  error("an emitted Xcode 26.3 test node lacks a result")
elif any($nodes[]; .result != "Passed") then
  error("test tree contains a non-passed target or test node")
elif ([$test_tree.devices[] | select((.deviceId | ascii_downcase) == ($selected_udid | ascii_downcase) and .deviceName == $selected_device and .platform == "iOS Simulator" and version_prefix_matches(.osVersion; $selected_runtime))] | length) != ($test_tree.devices | length) then
  error("test tree destination evidence does not match the selected iOS 26 simulator")
else
  ([$test_tree | .. | objects | select(.nodeType == "Test Plan") | .name] | unique | sort) as $plans |
  ([$test_tree | .. | objects | select(.nodeType == "Unit test bundle" or .nodeType == "UI test bundle") | .name] | unique | sort) as $bundles |
  ([$test_tree | .. | objects | select(.nodeType == "Unit test bundle" or .nodeType == "UI test bundle") | {name: .name, test_case_count: ([.. | objects | select(.nodeType == "Test Case")] | length)}]) as $bundle_cases |
  ($expected_targets | split(",") | map(select(length > 0)) | unique | sort) as $required |
  if $plans != [$expected_plan] then
    error("test tree has an unexpected test-plan set")
  elif $bundles != $required then
    error("test tree does not have the exact accepted test-target set")
  elif any($bundle_cases[]; .test_case_count <= 0) then
    error("an expected test target contains no test cases")
  elif ([ $nodes[] | select(.nodeType == "Test Case") ] | length) == 0 then
    error("test tree contains no test cases")
  else
    [($bundles | join(",")), ([$test_tree.devices[] | select((.deviceId | ascii_downcase) == ($selected_udid | ascii_downcase) and .deviceName == $selected_device and .platform == "iOS Simulator" and version_prefix_matches(.osVersion; $selected_runtime))] | length), ([ $nodes[] | select(.nodeType == "Test Case") ] | length)] | @tsv
  end
end
' <<< "$tests_json" 2>&1)"; then
        fail "$label .xcresult test-tree failed schema/evidence validation: $test_values"
    fi

    if ! coverage_json="$("$xcrun_bin" xcresulttool get content-availability --schema-version 0.1.0 --path "$result_path" 2>&1)"; then
        fail "$label .xcresult content-availability inspection failed: $coverage_json"
    fi
    if ! coverage_value="$("$jq_bin" -er '
if type != "object" then
  error("content-availability root is not an object")
elif ((has("hasCoverage") and has("hasDiagnostics") and has("hasTestResults") and has("logs")) | not) then
  error("content-availability is missing a required Xcode 26 field")
elif ((.hasCoverage | type) != "boolean" or (.hasDiagnostics | type) != "boolean" or (.hasTestResults | type) != "boolean" or (.logs | type) != "array") then
  error("content-availability has an unexpected Xcode 26 field type")
elif .hasCoverage != true then
  error("xcresulttool reports that code coverage is unavailable")
elif .hasTestResults != true then
  error("xcresulttool reports that test results are unavailable")
else
  "coverage"
end
' <<< "$coverage_json" 2>&1)"; then
        fail "$label .xcresult coverage/schema validation failed: $coverage_value"
    fi

    IFS=$'\t' read -r target_values destination_records test_case_count <<< "$test_values"
    printf '%s: %s result verified: %d executed, zero failures, zero skips, targets=%s, destination-records=%s, test-cases=%s, coverage=%s\n' \
        "$lane_name" "$label" "$total_test_count" "$target_values" "$destination_records" "$test_case_count" "$coverage_value"
}

script_dir="$(builtin cd -- "$($dirname_bin "${BASH_SOURCE[0]}")" && builtin pwd -P)"
repo_root="$(builtin cd -- "$script_dir/.." && builtin pwd -P)"
project="$repo_root/Loopr/Loopr.xcodeproj"
package_dir="$repo_root/LooprPackages"
results_dir="$repo_root/TestResults"
visual_script_path="$script_dir/test-visual.sh"
phase06_validator_path="$script_dir/verify-phase06.sh"
package_test_targets='DomainKitTests,ProtocolKitTests,StorageKitTests,BluetoothKitTests,SyncKitTests,AnalyticsKitTests,HealthKitBridgeTests,WorkoutKitTests,NotificationKitTests,SharedSurfaceKitTests,CoachingKitTests,AIKitTests,ImportKitTests,DeviceActionsKitTests,DesignSystemTests,ProfileKitTests,OnboardingKitTests,DeviceCenterKitTests,TodayKitTests,CoachKitTests,SleepKitTests,HeartKitTests,BodyKitTests,RouteKitTests,JournalKitTests,CycleKitTests,RecordsKitTests,StressKitTests,SettingsKitTests,DataKitTests'
local_source_packages_dir="$repo_root/build/native-surface/SourcePackages"
derived_data_path="$repo_root/build/derived-data/$lane_name"
xcode_package_args=()
xcodebuild_command=("$xcodebuild_bin")

if [[ -f "$local_source_packages_dir/workspace-state.json" &&
      -d "$local_source_packages_dir/checkouts/GRDB.swift" ]]; then
    xcode_package_args=(
        -clonedSourcePackagesDirPath "$local_source_packages_dir"
        -disableAutomaticPackageResolution
    )
    xcodebuild_command+=("${xcode_package_args[@]}")
    printf '%s: using verified repository-local Swift package checkout %s\n' \
        "$lane_name" "$local_source_packages_dir"
fi

if [[ ! -d "$project" ]]; then
    fail "Xcode project is missing: $project"
fi
if (( ! visual_lane )) && [[ ! -f "$package_dir/Package.swift" ]]; then
    fail "standalone package manifest is missing: $package_dir/Package.swift"
fi
if (( ! visual_lane )) && [[ ! -x "$phase06_validator_path" ]]; then
    fail "Phase 06 target/config validator is missing or not executable: $phase06_validator_path"
fi
if (( visual_lane )) && [[ ! -f "$visual_script_path" ]]; then
    fail "visual script is missing: $visual_script_path"
fi

if ! current_uid="$($id_bin -u 2>/dev/null)"; then
    fail "could not determine the current uid for secure output validation"
fi
if [[ -L "$results_dir" ]]; then
    fail "TestResults must not be a symlink: $results_dir"
fi
if [[ -e "$results_dir" ]]; then
    if [[ ! -d "$results_dir" ]]; then
        fail "TestResults exists but is not a directory: $results_dir"
    fi
else
    if ! "$mkdir_bin" "$results_dir"; then
        fail "could not create TestResults directory: $results_dir"
    fi
fi
if [[ -L "$results_dir" || ! -d "$results_dir" ]]; then
    fail "TestResults is not a regular directory: $results_dir"
fi
if ! results_uid="$($stat_bin -f '%u' "$results_dir" 2>/dev/null)" || [[ "$results_uid" != "$current_uid" ]]; then
    fail "TestResults is not owned by the current uid ($current_uid): $results_dir"
fi
if ! results_mode="$($stat_bin -f '%Lp' "$results_dir" 2>/dev/null)" || [[ ! "$results_mode" =~ ^[0-7]+$ ]]; then
    fail "could not inspect TestResults permissions: $results_dir"
fi
results_mode_value=$((8#$results_mode))
if (( results_mode_value & 0022 )); then
    fail "TestResults must not be group/world writable: $results_dir"
fi

# All canonical Loopr test scripts use this stable path and the fd 9 lockf protocol.
test_lock="$results_dir/.loopr-test.lock"
script_path="$script_dir/test-fast.sh"

validate_lock_file() {
    local lock_uid=""
    local lock_links=""
    local lock_mode=""

    if [[ -L "$test_lock" || ! -f "$test_lock" ]]; then
        fail "shared lock must be a regular non-symlink file: $test_lock"
    fi
    if ! lock_links="$($stat_bin -f '%l' "$test_lock" 2>/dev/null)" || [[ "$lock_links" != "1" ]]; then
        fail "shared lock must have exactly one hard link before chmod/open: $test_lock"
    fi
    if ! lock_uid="$($stat_bin -f '%u' "$test_lock" 2>/dev/null)" || [[ "$lock_uid" != "$current_uid" ]]; then
        fail "shared lock is not owned by the current uid ($current_uid): $test_lock"
    fi
    if ! "$chmod_bin" 600 "$test_lock"; then
        fail "could not set restrictive permissions on shared lock: $test_lock"
    fi
    if [[ -L "$test_lock" || ! -f "$test_lock" ]]; then
        fail "shared lock changed into a non-regular file: $test_lock"
    fi
    if ! lock_links="$($stat_bin -f '%l' "$test_lock" 2>/dev/null)" || [[ "$lock_links" != "1" ]]; then
        fail "shared lock must retain exactly one hard link after chmod/open: $test_lock"
    fi
    if ! lock_mode="$($stat_bin -f '%Lp' "$test_lock" 2>/dev/null)" || [[ "$lock_mode" != "600" ]]; then
        fail "shared lock must have mode 600: $test_lock"
    fi
}

assert_fd9_lock_identity() {
    local path_identity=""
    local path_links=""
    local fd_listing=""
    local line=""
    local fd_device_raw=""
    local fd_inode=""
    local fd_device=""

    if [[ -L "$test_lock" || ! -f "$test_lock" ]]; then
        fail "shared lock path changed while fd 9 was held: $test_lock"
    fi
    if ! path_links="$($stat_bin -f '%l' "$test_lock" 2>/dev/null)" || [[ "$path_links" != "1" ]]; then
        fail "shared lock path link count changed while fd 9 was held: $test_lock"
    fi
    if ! path_identity="$($stat_bin -f '%d:%i' "$test_lock" 2>/dev/null)"; then
        fail "could not inspect shared lock device/inode: $test_lock"
    fi
    # $$ is only lsof's selector for this live fd; no PID is persisted as lock state.
    if ! fd_listing="$($lsof_bin -a -p "$$" -d 9 -F Di 2>&1)"; then
        fail "could not inspect fd 9 lock evidence: $fd_listing"
    fi
    while IFS= read -r line; do
        case "$line" in
            D*) fd_device_raw="${line#D}" ;;
            i*) fd_inode="${line#i}" ;;
        esac
    done <<< "$fd_listing"
    if [[ -z "$fd_device_raw" || -z "$fd_inode" ]]; then
        fail "fd 9 lock evidence is missing device/inode fields: $fd_listing"
    fi
    if [[ "$fd_device_raw" =~ ^0x[0-9A-Fa-f]+$ ]]; then
        fd_device=$((fd_device_raw))
    elif [[ "$fd_device_raw" =~ ^[0-9]+$ ]]; then
        fd_device="$fd_device_raw"
    else
        fail "fd 9 lock evidence has an invalid device value: $fd_device_raw"
    fi
    if [[ ! "$fd_inode" =~ ^[0-9]+$ ]]; then
        fail "fd 9 lock evidence has an invalid inode value: $fd_inode"
    fi
    if [[ "$fd_device:$fd_inode" != "$path_identity" ]]; then
        fail "fd 9 does not reference the secure shared lock path (fd=$fd_device:$fd_inode path=$path_identity)"
    fi
    printf '%s: fd 9 lock evidence verified for %s\n' "$lane_name" "$test_lock"
}

assert_fd9_lock_held() {
    if ! "$lockf_bin" -s -t 0 9; then
        fail "fd 9 is not lock-held by this process: $test_lock"
    fi
    assert_fd9_lock_identity
}

if [[ -L "$test_lock" || ( -e "$test_lock" && ! -f "$test_lock" ) ]]; then
    fail "shared lock must not be a symlink or non-regular file: $test_lock"
fi
if [[ ! -e "$test_lock" ]]; then
    if ! (umask 077; : >> "$test_lock"); then
        fail "could not create shared lock file: $test_lock"
    fi
fi
validate_lock_file

if (( lock_reexec )); then
    if (( full_lane )); then
        if [[ "$#" -ne 2 || "${1:-}" != "--loopr-full" || "${2:-}" != "--loopr-lock-held" ]]; then
            fail "shared-lock re-exec marker is invalid"
        fi
    elif (( visual_lane )); then
        if (( visual_dry_run )); then
            if (( phase06_visual_lane )); then
                if [[ "$#" -ne 4 || "${1:-}" != "--loopr-visual" ||
                    "${2:-}" != "--phase06" || "${3:-}" != "--loopr-dry-run" ||
                    "${4:-}" != "--loopr-lock-held" ]]; then
                    fail "visual Phase 06 dry-run shared-lock re-exec marker is invalid"
                fi
            elif [[ "$#" -ne 3 || "${1:-}" != "--loopr-visual" ||
                "${2:-}" != "--loopr-dry-run" || "${3:-}" != "--loopr-lock-held" ]]; then
                fail "visual dry-run shared-lock re-exec marker is invalid"
            fi
        elif (( phase06_visual_lane )); then
            if [[ "$#" -ne 3 || "${1:-}" != "--loopr-visual" ||
                "${2:-}" != "--phase06" || "${3:-}" != "--loopr-lock-held" ]]; then
                fail "visual Phase 06 shared-lock re-exec marker is invalid"
            fi
        elif [[ "$#" -ne 2 || "${1:-}" != "--loopr-visual" ||
            "${2:-}" != "--loopr-lock-held" ]]; then
            fail "visual shared-lock re-exec marker is invalid"
        fi
    elif [[ "$#" -ne 1 || "${1:-}" != "--loopr-lock-held" ]]; then
        fail "shared-lock re-exec marker is invalid"
    fi
    assert_fd9_lock_held
    assert_no_active_test_processes
    if (( visual_lane )); then
        if (( visual_dry_run )); then
            if (( phase06_visual_lane )); then
                exec /bin/bash "$visual_script_path" --loopr-lock-held --phase06 --dry-run
            else
                exec /bin/bash "$visual_script_path" --loopr-lock-held --dry-run
            fi
        elif (( phase06_visual_lane )); then
            exec /bin/bash "$visual_script_path" --loopr-lock-held --phase06
        else
            exec /bin/bash "$visual_script_path" --loopr-lock-held
        fi
    fi
else
    if (( full_lane )); then
        if [[ "$#" -ne 1 || "${1:-}" != "--loopr-full" ]]; then
            fail "test-all internal mode marker is invalid"
        fi
    elif (( visual_lane )); then
        if (( visual_dry_run )); then
            if (( phase06_visual_lane )); then
                if [[ "$#" -ne 3 || "${1:-}" != "--loopr-visual" ||
                    "${2:-}" != "--phase06" || "${3:-}" != "--loopr-dry-run" ]]; then
                    fail "visual Phase 06 dry-run internal mode marker is invalid"
                fi
            elif [[ "$#" -ne 2 || "${1:-}" != "--loopr-visual" ||
                "${2:-}" != "--loopr-dry-run" ]]; then
                fail "visual dry-run internal mode marker is invalid"
            fi
        elif (( phase06_visual_lane )); then
            if [[ "$#" -ne 2 || "${1:-}" != "--loopr-visual" ||
                "${2:-}" != "--phase06" ]]; then
                fail "visual Phase 06 internal mode marker is invalid"
            fi
        elif [[ "$#" -ne 1 || "${1:-}" != "--loopr-visual" ]]; then
            fail "visual internal mode marker is invalid"
        fi
    elif [[ "$#" -ne 0 ]]; then
        fail "test-fast.sh does not accept command-line arguments"
    fi
    assert_no_active_test_processes
    if ! exec 9>>"$test_lock"; then
        fail "could not open shared lock file for locking: $test_lock"
    fi
    validate_lock_file
    # fd mode keeps the kernel lock across exec and releases it on process death.
    if ! "$lockf_bin" -s -t 0 9; then
        exec 9>&-
        fail "shared test lock is already held; refusing to wait or retry: $test_lock"
    fi
    assert_fd9_lock_identity
    export LOOPR_TEST_LOCK_HELD=1
    if (( full_lane )); then
        exec /bin/bash "$script_path" --loopr-full --loopr-lock-held
    elif (( visual_lane )); then
        if (( visual_dry_run )); then
            if (( phase06_visual_lane )); then
                exec /bin/bash "$script_path" --loopr-visual --phase06 --loopr-dry-run --loopr-lock-held
            else
                exec /bin/bash "$script_path" --loopr-visual --loopr-dry-run --loopr-lock-held
            fi
        elif (( phase06_visual_lane )); then
            exec /bin/bash "$script_path" --loopr-visual --phase06 --loopr-lock-held
        else
            exec /bin/bash "$script_path" --loopr-visual --loopr-lock-held
        fi
    else
        exec /bin/bash "$script_path" --loopr-lock-held
    fi
fi

if [[ -z "${IOS_SIMULATOR_UDID:-}" || -z "${IOS_SIMULATOR_NAME:-}" || -z "${IOS_SIMULATOR_DESTINATION:-}" ]]; then
    fail "device-bound lane requires IOS_SIMULATOR_UDID, IOS_SIMULATOR_NAME, and IOS_SIMULATOR_DESTINATION from ios-simulator-worker.sh"
fi
if [[ "$IOS_SIMULATOR_DESTINATION" != "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" ]]; then
    fail "leased simulator destination does not match IOS_SIMULATOR_UDID"
fi
if ! available_devices_json="$("$xcrun_bin" simctl list devices available --json 2>&1)"; then
    fail "could not list available iOS simulators: $available_devices_json"
fi

if ! simulator_record="$("$jq_bin" -r --arg leased_udid "$IOS_SIMULATOR_UDID" '
[
  .devices
  | to_entries[]
  | .key as $runtime_key
  | select($runtime_key | test("^com\\.apple\\.CoreSimulator\\.SimRuntime\\.iOS-[0-9]+(-[0-9]+)*$"))
  | ($runtime_key | sub("^com\\.apple\\.CoreSimulator\\.SimRuntime\\.iOS-"; "") | split("-") | join(".")) as $runtime
  | select($runtime | test("^26(\\.[0-9]+)*$"))
  | .value[]
  | select(.isAvailable == true and .udid == $leased_udid)
  | {
      runtime: $runtime,
      name: .name,
      udid: .udid,
      isolated: (if .name == "Loopr iPhone 17" then 1 else 0 end)
    }
]
| if length == 0 then empty
  else max_by([.isolated] + (.runtime | split(".") | map(tonumber)))
  | [.runtime, .name, .udid] | @tsv
  end
' <<< "$available_devices_json" 2>&1)"; then
    fail "could not parse available simulator JSON: $simulator_record"
fi

if [[ -z "$simulator_record" ]]; then
    fail "no available Loopr-isolated or standard iPhone 17 simulator with an iOS 26 runtime was found"
fi

IFS=$'\t' read -r selected_runtime selected_device selected_udid <<< "$simulator_record"
if [[ -z "$selected_runtime" || -z "$selected_device" || -z "$selected_udid" ]]; then
    fail "simulator discovery returned an incomplete record: $simulator_record"
fi
if [[ ! "$selected_runtime" =~ ^26(\.[0-9]+)*$ ]]; then
    fail "simulator discovery returned a non-iOS-26 runtime: $selected_runtime"
fi
if [[ ! "$selected_udid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    fail "simulator discovery returned an invalid UDID: $selected_udid"
fi

destination="platform=iOS Simulator,id=$selected_udid"
printf '%s: selected iOS simulator %s, runtime %s, UDID %s\n' \
    "$lane_name" \
    "$selected_device" "$selected_runtime" "$selected_udid"

watch_destination=""
if (( full_lane )); then
    if ! watch_simulator_record="$("$jq_bin" -r '
[
  .devices
  | to_entries[]
  | .key as $runtime_key
  | select($runtime_key | test("^com\\.apple\\.CoreSimulator\\.SimRuntime\\.watchOS-[0-9]+(-[0-9]+)*$"))
  | ($runtime_key | sub("^com\\.apple\\.CoreSimulator\\.SimRuntime\\.watchOS-"; "") | split("-") | join(".")) as $runtime
  | select($runtime | test("^26(\\.[0-9]+)*$"))
  | .value[]
  | select(.isAvailable == true and .name == "Apple Watch Series 11 (46mm)")
  | {runtime: $runtime, name: .name, udid: .udid}
]
| if length == 0 then empty else max_by(.runtime | split(".") | map(tonumber)) | [.runtime, .name, .udid] | @tsv end
' <<< "$available_devices_json" 2>&1)"; then
        fail "could not parse available Apple Watch simulator JSON: $watch_simulator_record"
    fi
    if [[ -z "$watch_simulator_record" ]]; then
        fail "no available Apple Watch Series 11 (46mm) simulator with a watchOS 26 runtime was found"
    fi
    IFS=$'\t' read -r selected_watch_runtime selected_watch_device selected_watch_udid <<< "$watch_simulator_record"
    if [[ ! "$selected_watch_udid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
        fail "watch simulator discovery returned an invalid UDID: $selected_watch_udid"
    fi
    watch_destination='generic/platform=watchOS Simulator'
    printf '%s: selected watch simulator %s, runtime %s, UDID %s\n' \
        "$lane_name" \
        "$selected_watch_device" "$selected_watch_runtime" "$selected_watch_udid"
fi

app_result_stem="app-unit"
app_test_label="app unit tests"
app_result_label="app unit-test"
app_expected_targets="LooprTests"
package_result_stem="package-unit"
lane_success_label="fast unit lane"
if (( full_lane )); then
    app_result_stem="app-all"
    app_test_label="app, integration, and UI tests"
    app_result_label="app, integration, and UI-test"
    app_expected_targets="LooprTests,LooprUITests"
    package_result_stem="package-all"
    lane_success_label="full simulator lane"
fi

if ! run_dir="$("$mktemp_bin" -d "$results_dir/$lane_name.XXXXXX")"; then
    fail "could not reserve a unique result directory under $results_dir"
fi

app_result="$run_dir/$app_result_stem.xcresult"
package_result="$run_dir/$package_result_stem.xcresult"
if [[ -e "$app_result" || -e "$package_result" ]]; then
    fail "reserved result path already exists under $run_dir"
fi

app_test_args=(-project "$project" -scheme Loopr -destination "$destination" -derivedDataPath "$derived_data_path")
if (( ! full_lane )); then
    app_test_args+=(-only-testing:LooprTests)
fi
app_test_args+=(
    -resultBundlePath "$app_result"
    -enableCodeCoverage YES
    -parallel-testing-enabled NO
    -maximum-concurrent-test-simulator-destinations 1
    'OTHER_LDFLAGS=$(inherited) -framework AppIntents'
    CODE_SIGNING_ALLOWED=NO
)

run_command "scheme discovery" \
    "${xcodebuild_command[@]}" -list -project "$project"

run_command "Phase 06 target/config inventory" \
    "$phase06_validator_path"

run_command "unsigned generic app build" \
    "${xcodebuild_command[@]}" build \
        -project "$project" \
        -scheme Loopr \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$derived_data_path" \
        CODE_SIGNING_ALLOWED=NO

if (( full_lane )); then
    run_command "single watch simulator build" \
        "${xcodebuild_command[@]}" build \
            -project "$project" \
            -scheme LooprWatch \
            -destination "$watch_destination" \
            -derivedDataPath "$derived_data_path" \
            CODE_SIGNING_ALLOWED=NO
fi

printf '%s: %s result bundle: %s\n' "$lane_name" "$app_result_label" "$app_result"
# The source defines no changed-package algorithm, so use the safe full fast-unit fallback.
# Fast mode selects the complete app unit-test target; full mode leaves test selection unrestricted.
run_command "$app_test_label" \
    "${xcodebuild_command[@]}" test "${app_test_args[@]}"

require_test_result "$app_test_label" "$app_result" "Loopr" "$app_expected_targets"

if ! cd -- "$package_dir"; then
    fail "could not enter standalone package directory: $package_dir"
fi

printf '%s: standalone package unit-test result bundle: %s\n' "$lane_name" "$package_result"
run_command "standalone package unit tests" \
    "${xcodebuild_command[@]}" test \
        -scheme LooprPackages-Package \
        -destination "$destination" \
        -derivedDataPath "$derived_data_path" \
        -resultBundlePath "$package_result" \
        -enableCodeCoverage YES \
        -parallel-testing-enabled NO \
        -maximum-concurrent-test-simulator-destinations 1 \
        ENABLE_APP_INTENTS_METADATA_EXTRACTION=NO \
        'OTHER_LDFLAGS=$(inherited) -framework AppIntents' \
        CODE_SIGNING_ALLOWED=NO

require_test_result "standalone package unit tests" "$package_result" "LooprPackages-Package" "$package_test_targets"

printf '%s: %s passed; result bundles are under %s\n' "$lane_name" "$lane_success_label" "$run_dir"
