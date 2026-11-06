#!/usr/bin/env python3
"""Focused longevity checks between the complete baseline and final fast lanes.

Two phases, so a compile never holds a simulator and a test run never holds a compile slot:

  build <step>   build-for-testing the app and the package scheme for the generic simulator.
                 Run it through ops/ios-build-queue.sh (submit, then wait).
  test <step>    test-without-building the step's app unit suites, UI suites and package
                 targets. Run it through ops/ios-simulator-worker.sh (add --stock for steps
                 marked "stock", such as the bedtime Live Activity).

The step table below is the single list of what each step proves. A listed suite that does
not run fails the step with "Selected suites did not execute", so keep the lists true.

Steps lv10-4 and lv10-4e also enforce the entrance hitch budget. EntrancePerformanceUITests only
measures (XCTest sets up the signpost probe for a raw XCTOSSignpostMetric and nothing else), so
after the UI suites pass the test phase reads the app-ui result bundle with
`xcresulttool get test-results metrics` and fails the step when any tab's hitch time ratio is above
5 ms of hitch per second, or when a tab reports no hitch ratio at all.
"""
import fcntl
import json
import os
import platform
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

# LOOPR_REPO_ROOT lets the lead test a worker worktree with the lead copy of this table.
ROOT = Path(os.environ.get("LOOPR_REPO_ROOT") or Path(__file__).resolve().parents[1])

# step id -> unit: LooprTests suites, ui: LooprUITests suites, packages: package test targets,
# package_suites: suites that must appear in the package bundle, stock: needs a stock worker.
STEPS = {
    "lv01": {"unit": ["FoodMacroBurstFlightTests"], "ui": [], "packages": ["DesignSystemTests"], "package_suites": []},
    "lv03": {"unit": ["RoutineSourceProviderTests", "RoutineJournalMigrationTests", "RoutineFileHandlerTests"], "ui": [], "packages": ["RoutineKitTests", "StorageKitTests", "JournalKitTests", "FoodKitTests"], "package_suites": []},
    "lv08a": {"unit": [], "ui": [], "packages": ["AnalyticsKitTests", "StorageKitTests", "DataKitTests"], "package_suites": []},
    "lv11": {"unit": ["AppleHealthSourcesSummaryTests"], "ui": [], "packages": ["HealthKitBridgeTests"], "package_suites": []},
    "lv02": {"unit": ["FiveTabRoutingTests", "LongevityShellTabsTests", "LongevityShellRoutesTests", "LiveActivityLifecycleTests", "TodayAgentSlotsTests", "AgentSourcesTests", "SIHeartnavNavigationTests", "LongevityShellDataTests"], "ui": ["FiveTabShellUITests", "FiveTabUITests", "LongevityShellRoutesUITests", "LongevityShellDataUITests", "AskUITests", "TodayAgentUITests"], "packages": ["DesignSystemTests"], "package_suites": []},
    "lv04-4": {"unit": ["BedtimeActivityWindowTests", "BedtimeActivityStepsTests", "BedtimeActivityRuntimeTests", "LiveActivityLifecycleTests"], "ui": ["BedtimeLiveActivityUITests"], "packages": ["SettingsKitTests"], "package_suites": [], "stock": True},
    "lv04-2": {"unit": ["TodayDialFixtureClockTests", "TodayDialInputBuilderTests", "TodayAgentSlotsTests"], "ui": ["TodayDialUITests", "SIMorningCaptureUITests", "TodayAgentUITests"], "packages": ["TodayKitTests", "DesignSystemTests"], "package_suites": []},
    "lv04-3": {"unit": ["TodayNoteRailLoaderTests", "TodayNoteMorningInputTests", "TodayDialInputBuilderTests"], "ui": ["TodayNoteRailUITests", "TodayDialUITests", "SIMorningCaptureUITests"], "packages": ["TodayKitTests", "CoachKitTests", "RoutineKitTests"], "package_suites": []},
    "lv04-5": {"unit": ["TodayNoteRailLoaderTests", "TodayNoteMorningInputTests", "TodayDialInputBuilderTests", "TodayAgentSlotsTests"], "ui": ["TodayNoteRailUITests", "TodayDialUITests", "SIMorningCaptureUITests", "TodayAgentUITests"], "packages": ["TodayKitTests", "CoachKitTests", "RoutineKitTests"], "package_suites": []},
    "lv04": {"unit": ["TodayDialInputBuilderTests"], "ui": [], "packages": ["TodayKitTests"], "package_suites": []},
    "lv05-3": {"unit": ["FoodLongevityLoaderTests", "FoodMacroBurstFlightTests"], "ui": ["FoodLongevityUITests", "FoodOverviewUITests", "FoodCaptureUITests"], "packages": ["FoodKitTests", "DesignSystemTests"], "package_suites": []},
    "lv05-2b": {"unit": ["RoutineSupplementSourceTests", "FoodLongevityLoaderTests", "RoutineSourceProviderTests"], "ui": ["FoodLongevityUITests", "FoodOverviewUITests"], "packages": ["RoutineKitTests", "FoodKitTests"], "package_suites": []},
    "lv05-5": {"unit": ["FoodLabModelTests", "FoodLongevityLoaderTests"], "ui": ["FoodLabModeUITests", "FoodOverviewUITests", "FoodLongevityUITests"], "packages": ["FoodKitTests"], "package_suites": []},
    "lv05": {"unit": [], "ui": [], "packages": ["FoodKitTests", "AIKitTests", "StorageKitTests"], "package_suites": []},
    "lv06-2": {"unit": ["FitnessOverviewLoaderTests"], "ui": ["FitnessTabUITests"], "packages": ["TrainKitTests", "DesignSystemTests"], "package_suites": []},
    "lv06-3": {"unit": ["FitnessCapacityFlowTests", "FitnessOverviewLoaderTests"], "ui": ["FitnessCapacityUITests", "FitnessTabUITests"], "packages": ["TrainKitTests"], "package_suites": []},
    "lv06-4": {"unit": ["FitnessCapacityFlowTests", "FitnessOverviewLoaderTests"], "ui": ["FitnessCapacityUITests", "FitnessTabUITests", "TrainOverviewUITests"], "packages": ["TrainKitTests", "DesignSystemTests"], "package_suites": []},
    "lv06": {"unit": [], "ui": [], "packages": ["TrainKitTests", "StorageKitTests", "FoodKitTests"], "package_suites": []},
    "lv07-1": {"unit": ["ProtocolTabLoaderTests", "ProtocolTabFixtureTests"], "ui": ["ProtocolTabUITests"], "packages": ["JournalKitTests", "DesignSystemTests"], "package_suites": []},
    "lv07-4": {"unit": ["ProtocolFilesRoutingTests", "ProtocolRulesLoaderTests", "ProtocolExperimentLoaderTests"], "ui": ["ProtocolRulesUITests", "ProtocolExperimentUITests", "ProtocolTabUITests"], "packages": ["RoutineKitTests", "JournalKitTests", "NotificationKitTests"], "package_suites": []},
    "lv07-5": {"unit": ["ProtocolTabLoaderTests", "ProtocolFilesRoutingTests", "ProtocolExperimentLoaderTests"], "ui": ["ProtocolTabUITests", "ProtocolRulesUITests", "ProtocolExperimentUITests"], "packages": ["JournalKitTests"], "package_suites": []},
    "lv07": {"unit": [], "ui": [], "packages": ["RoutineKitTests", "StorageKitTests", "FoodKitTests"], "package_suites": []},
    "lv08b-1": {"unit": ["DataTabOverviewTests"], "ui": ["DataTabUITests", "LongevityShellDataUITests"], "packages": ["DataKitTests"], "package_suites": []},
    "lv08b-2": {"unit": ["LabsRoutesTests"], "ui": ["LabsUITests"], "packages": ["DataKitTests"], "package_suites": []},
    "lv08b-3": {"unit": ["MethodRouteTests"], "ui": ["MethodPagesUITests"], "packages": ["DataKitTests", "DesignSystemTests"], "package_suites": []},
    "lv05-4": {"unit": ["FoodLabRecognitionTests", "FoodLabModelTests"], "ui": ["FoodLabModeUITests", "FoodCaptureUITests"], "packages": ["AnalyticsKitTests"], "package_suites": []},
    "lv07-3": {"unit": ["ProtocolExperimentLoaderTests"], "ui": ["ProtocolExperimentUITests", "ProtocolTabUITests"], "packages": ["RoutineKitTests", "JournalKitTests"], "package_suites": []},
    "lv08b-4": {"unit": ["PublishDataLoaderTests", "PublishLaunchTests"], "ui": ["PublishDashboardUITests"], "packages": ["DataKitTests"], "package_suites": []},
    "lv08b-5": {"unit": ["BodyLogHealthMappingTests", "BodyLogProviderTests", "BodyLogSummaryLoaderTests", "BodyLogRouteTests", "BodyLogFixtureTests"], "ui": ["BodyLogUITests"], "packages": ["BodyKitTests", "StorageKitTests"], "package_suites": []},
    "lv08b-7": {"unit": ["DataIntegrationTests", "DataTabOverviewTests", "MethodRouteTests"], "ui": ["DataIntegrationUITests", "DataTabUITests", "LongevityShellDataUITests", "LabsUITests", "MethodPagesUITests", "FoodLabModeUITests"], "packages": ["DataKitTests"], "package_suites": []},
    "lv08b-6": {"unit": ["MethodRouteTests", "DataIntegrationTests"], "ui": ["MethodPagesUITests", "DataIntegrationUITests"], "packages": ["DesignSystemTests", "DataKitTests"], "package_suites": []},
    "lv08b": {"unit": [], "ui": [], "packages": ["DataKitTests", "AnalyticsKitTests", "DesignSystemTests"], "package_suites": []},
    "lv10-5": {"unit": ["UpgradeFromBuild21AppTests"], "ui": [], "packages": ["StorageKitTests"], "package_suites": []},
    "lv10-6": {"unit": ["CalendarPrivacyTests", "DiagnosticsExportTests", "KeychainStorageTests", "LogRedactionTests", "NetworkDestinationTests", "PrivacyManifestTests", "ReleaseCopyTests", "ReleaseManifestTests", "UsageDescriptionTests", "FoodPhotoPrivacyTests"], "ui": [], "packages": ["DesignSystemTests", "SleepKitTests", "JournalKitTests", "DataKitTests", "TrainKitTests", "BodyKitTests", "WorkoutKitTests"], "package_suites": []},
    "lv10-polish": {"unit": ["DataTabOverviewTests", "ProtocolExperimentLoaderTests", "MetricContentCatalogTests", "MetricValueFormatTests", "MetricTrendNarrativeTests"], "ui": [], "packages": ["DesignSystemTests", "DataKitTests", "JournalKitTests", "RoutineKitTests", "AIKitTests"], "package_suites": []},
    "lv10-int": {"unit": ["WeeklyReviewTests", "TodayCompanionRoutingTests", "AppleHealthSourceRowTests", "PersistentDeletionTests", "TodayNoteRailLoaderTests"], "ui": ["WeeklyReviewUITests", "TodayNoteRailUITests", "DataIntegrationUITests"], "packages": ["CoachKitTests", "NotificationKitTests", "DataKitTests", "SettingsKitTests", "DesignSystemTests", "TodayKitTests"], "package_suites": []},
    "lv10-4": {"unit": [], "ui": ["LaunchPerformanceTests", "ScrollPerformanceUITests", "EntrancePerformanceUITests"], "packages": ["DesignSystemTests"], "package_suites": []},
    "lv10-4e": {"unit": [], "ui": ["EntrancePerformanceUITests"], "packages": [], "package_suites": []},
    "lv09-3": {"unit": ["LongevityAgentToolTests", "LongevityAgentStoreTests", "LongevityAgentAccessTests", "AgentAccessEnforcementTests", "AgentConfirmationTests", "AgentRequestLogTests"], "ui": [], "packages": ["AIKitTests"], "package_suites": []},
    "lv09-4": {"unit": ["LongevityAgentAccessTests", "AskSheetTests", "AgentAccessEnforcementTests"], "ui": [], "packages": ["CoachKitTests", "AIKitTests"], "package_suites": []},
    "icp1": {"unit": ["FixtureCoherenceTests", "PublishDataLoaderTests", "DataIntegrationTests", "ProtocolTabLoaderTests", "TodayAgentSlotsTests", "LongevityShellDataTests", "LongevityShellTabsTests", "ReleasePrivacyTests", "ReleaseCopyTests"], "ui": ["DataTabUITests", "ProtocolTabUITests", "JournalFiveTabUITests"], "packages": ["DataKitTests", "JournalKitTests", "RoutineKitTests", "CoachKitTests", "NotificationKitTests", "AnalyticsKitTests", "DesignSystemTests", "TodayKitTests"], "package_suites": []},
    "lv09": {"unit": [], "ui": [], "packages": ["CoachKitTests"], "package_suites": []},
    "lv10-4": {"unit": [], "ui": ["LaunchPerformanceTests", "ScrollPerformanceUITests", "EntrancePerformanceUITests"], "packages": ["DesignSystemTests"], "package_suites": []},
    "lv10-4e": {"unit": [], "ui": ["EntrancePerformanceUITests"], "packages": [], "package_suites": []},
}

# Steps whose app-ui bundle is checked against the entrance hitch budget, in ms of hitch per second.
HITCH_STEPS = ("lv10-4", "lv10-4e")
HITCH_BUDGET_MS_PER_SECOND = 5.0
ENTRANCE_TABS = ("today", "food", "fitness", "protocol", "data")

DERIVED = os.environ.get("LOOPR_DERIVED_DATA_PATH", "/private/tmp/loopr-lv/dd-lanes")
COMMON = ["-derivedDataPath", DERIVED, "-parallel-testing-enabled", "NO",
          "-maximum-concurrent-test-simulator-destinations", "1", "-enableCodeCoverage", "YES",
          "OTHER_LDFLAGS=$(inherited) -framework AppIntents", "CODE_SIGNING_ALLOWED=NO"]


def architecture():
    # Same flags as scripts/lv-compile.sh, so the test phase can reuse a worker's DerivedData.
    if platform.machine() != "arm64":
        raise RuntimeError(f"Unsupported simulator host architecture: {platform.machine()}")
    return ["ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO", "COMPILER_INDEX_STORE_ENABLE=NO"]


def app_command():
    return ["xcodebuild", "-project", str(ROOT / "Loopr/Loopr.xcodeproj"), "-scheme", "Loopr"] + COMMON + architecture()


def package_command():
    return ["xcodebuild", "-scheme", "LooprPackages-Package"] + COMMON + architecture() + ["ENABLE_APP_INTENTS_METADATA_EXTRACTION=NO"]


def evidence_folder(step, phase):
    requested = os.environ.get("LOOPR_RESULT_DIRECTORY")
    if requested:
        folder = Path(requested)
        if not folder.is_absolute() or folder.exists() or folder.is_symlink():
            raise RuntimeError("LOOPR_RESULT_DIRECTORY must be an unused absolute path")
        folder.mkdir(mode=0o700, parents=False)
        return folder
    base = Path("/private/tmp/loopr-lv/results")
    base.mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix=f"{step}-{phase}.", dir=base))


def run(args, folder, name, cwd=ROOT):
    with (folder / f"{name}.log").open("w") as log:
        result = subprocess.run(args, cwd=cwd, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"{name} failed: {folder / (name + '.log')}")


def suites_in(node):
    found = set()
    if isinstance(node, dict):
        if node.get("nodeType") == "Test Suite":
            found.add(node["name"])
        for value in node.values():
            found.update(suites_in(value))
    elif isinstance(node, list):
        for value in node:
            found.update(suites_in(value))
    return found


def inspect(bundle, folder, expected=()):
    report = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)]))
    (folder / (bundle.stem + "-summary.json")).write_text(json.dumps(report, indent=2) + "\n")
    if report["result"] != "Passed" or report["totalTestCount"] <= 0 or report["passedTests"] != report["totalTestCount"] \
            or any(report[key] for key in ("failedTests", "skippedTests", "expectedFailures")):
        raise RuntimeError(f"Test counts did not pass: {bundle}")
    if expected:
        tree = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)]))
        missing = set(expected) - suites_in(tree)
        if missing:
            raise RuntimeError(f"Selected suites did not execute: {sorted(missing)}")
    summary = {"bundle": str(bundle), **{key: report[key] for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}}
    print(summary, flush=True)
    return summary


def hitch_milliseconds_per_second(value, unit):
    """The hitch ratio in ms of hitch per second, or None for a unit this check does not know."""
    return {"ms/s": value, "s/s": value * 1_000, "%": value * 10}.get(unit.strip().lower())


def check_entrance_hitch(bundle, folder):
    """Fail when an entrance tab's hitch time ratio is above the budget, and print each tab's value."""
    metrics = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "metrics", "--path", str(bundle), "--compact"]))
    (folder / (bundle.stem + "-metrics.json")).write_text(json.dumps(metrics, indent=2) + "\n")
    worst = {}
    for test in metrics:
        suite, _, name = test["testIdentifier"].partition("/")
        if suite != "EntrancePerformanceUITests":
            continue
        tab = name.removeprefix("test").removesuffix("()").removesuffix("Entrance").lower()
        for run in test["testRuns"]:
            for metric in run["metrics"]:
                label = "".join(c for c in (metric.get("identifier", "") + metric["displayName"]).lower() if c.isalpha())
                if "hitch" not in label or "ratio" not in label:
                    continue
                for value in metric["measurements"]:
                    converted = hitch_milliseconds_per_second(value, metric["unitOfMeasurement"])
                    if converted is None:
                        raise RuntimeError(f"Entrance {tab}: unknown hitch ratio unit {metric['unitOfMeasurement']!r}")
                    worst[tab] = max(worst.get(tab, converted), converted)
    problems = []
    for tab in ENTRANCE_TABS:
        if tab not in worst:
            problems.append(f"{tab}: no hitch ratio reported")
            print(f"Entrance {tab}: no hitch ratio reported", flush=True)
            continue
        over = worst[tab] > HITCH_BUDGET_MS_PER_SECOND
        print(f"Entrance {tab}: {worst[tab]:.2f} ms/s (budget {HITCH_BUDGET_MS_PER_SECOND:g}){' OVER' if over else ''}", flush=True)
        if over:
            problems.append(f"{tab}: {worst[tab]:.2f} ms/s")
    if problems:
        raise RuntimeError(f"Entrance hitch budget of {HITCH_BUDGET_MS_PER_SECOND:g} ms/s failed: {'; '.join(problems)}")


def build(step):
    if not os.environ.get("IOS_BUILD_SLOT"):
        raise RuntimeError("Run the build phase through ops/ios-build-queue.sh")
    folder = evidence_folder(step, "build")
    print(f"Evidence: {folder}", flush=True)
    env = dict(os.environ, LOOPR_DERIVED_DATA_PATH=DERIVED)
    with (folder / "build.log").open("w") as log:
        result = subprocess.run([str(ROOT / "scripts/lv-compile.sh"), step], cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"build failed: {folder / 'build.log'}")
    print(f"Step {step} built: {folder}", flush=True)


def test(step):
    udid = os.environ.get("IOS_SIMULATOR_UDID")
    destination = os.environ.get("IOS_SIMULATOR_DESTINATION")
    if not udid or destination != f"platform=iOS Simulator,id={udid}" or not os.environ.get("IOS_SIMULATOR_NAME"):
        raise RuntimeError("Run the test phase through ios-simulator-worker.sh")
    results = ROOT / "TestResults"
    results.mkdir(exist_ok=True)
    descriptor = os.open(results / ".loopr-test.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        metadata = os.fstat(lock.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_nlink != 1:
            raise RuntimeError("Invalid shared test lock")
        fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for process in subprocess.check_output(["ps", "-ww", "-axo", "pid=,args="], text=True).splitlines():
            if "/xcodebuild " in process and " test" in process and ("-scheme Loopr " in process or "-scheme LooprPackages-Package " in process):
                raise RuntimeError(f"Another Loopr test run is active: {process.strip()}")
        folder = evidence_folder(step, "test")
        print(f"Evidence: {folder}", flush=True)
        plan = STEPS[step]
        reports = []
        run(["xcrun", "simctl", "bootstatus", udid, "-b"], folder, "simulator-boot")
        subprocess.run(["xcrun", "simctl", "ui", udid, "content_size", "large"], check=False)
        if plan["unit"]:
            bundle = folder / "app-unit.xcresult"
            run(app_command() + ["-destination", destination, "-resultBundlePath", str(bundle)]
                + [f"-only-testing:LooprTests/{name}" for name in plan["unit"]] + ["test-without-building"], folder, "app-unit")
            reports.append(inspect(bundle, folder, plan["unit"]))
        if plan["ui"]:
            bundle = folder / "app-ui.xcresult"
            run(app_command() + ["-destination", destination, "-resultBundlePath", str(bundle)]
                + [f"-only-testing:LooprUITests/{name}" for name in plan["ui"]] + ["test-without-building"], folder, "app-ui")
            reports.append(inspect(bundle, folder, plan["ui"]))
            if step in HITCH_STEPS:
                check_entrance_hitch(bundle, folder)
        if plan["packages"]:
            bundle = folder / "packages.xcresult"
            run(package_command() + ["-destination", destination, "-resultBundlePath", str(bundle)]
                + [f"-only-testing:{name}" for name in plan["packages"]] + ["test-without-building"], folder, "packages", ROOT / "LooprPackages")
            reports.append(inspect(bundle, folder, plan["package_suites"]))
        (folder / "report.json").write_text(json.dumps(reports, indent=2) + "\n")
        print(f"Step {step} passed: {folder / 'report.json'}", flush=True)


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("build", "test") or sys.argv[2] not in STEPS:
        raise SystemExit(f"Usage: test-longevity-step.py build|test <{'|'.join(STEPS)}>")
    build(sys.argv[2]) if sys.argv[1] == "build" else test(sys.argv[2])


if __name__ == "__main__":
    main()
