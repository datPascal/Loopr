#!/usr/bin/env python3
"""Focused five-tab checks between the complete baseline and final fast lanes."""
import fcntl
import json
import os
import platform
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
STEPS = {
    "ft05-5": ["TodayAgentSlotsTests", "AgentAccessEnforcementTests", "AgentConfirmationTests", "AgentRequestLogTests", "AgentBriefingGateTests", "AgentSourcesTests", "AgentChartsTests", "PatternsRuntimeTests", "PatternsRestartTests", "PatternsDeletionExportTests", "AgentChatToolModeTests", "UserReminderTests", "PatternsInvalidationTests", "HealthMetricPinsTests", "AskSheetTests", "AgentToolReadTests", "FiveTabRoutingTests", "PersistentDeletionTests", "PlatformDeletionTests"],
    "train-4": ["TrainProgramIntegrationTests", "CalendarPrivacyTests"],
    "train-3": ["TrainSessionFlowTests", "TrainRestCueTests", "TrainAdjustmentPersistenceTests", "LiveActivityLifecycleTests", "ActiveWorkoutAccessoryTests"],
    "train-2": [],
    "train-1": ["TrainLifecycleTests", "TrainOverviewIntegrationTests", "FoodLifecycleTests", "YourDataTests", "DataRepositoryIntegrityTests", "PersistentDeletionTests", "PlatformDeletionTests"],
    "food-6": [],
    "food-5": ["FoodAssociationRuntimeTests", "HabitInsightsIntegrationTests", "PrivacyManifestTests"],
    "food-4": ["FoodProviderRuntimeTests", "FoodPhotoPrivacyTests", "FoodCaptureIntegrationTests", "FoodLifecycleTests", "FoodOverviewIntegrationTests"],
    "food-3": ["FoodCaptureIntegrationTests", "FoodOverviewIntegrationTests", "FoodLifecycleTests"],
    "food-2-ui": [],
    "food-2-model": ["FoodOverviewIntegrationTests"],
    "food-2": ["FoodOverviewIntegrationTests", "FoodLifecycleTests", "JournalAutoFillIntegrationTests"],
    "food-1": ["FoodLifecycleTests", "YourDataTests", "DataRepositoryIntegrityTests", "PersistentDeletionTests", "PlatformDeletionTests"],
    "journal-1": ["JournalCheckInPersistenceTests"],
    "journal-3": ["MetricHabitAssociationTests", "HabitInsightsIntegrationTests", "JournalCheckInPersistenceTests", "JournalAutoFillIntegrationTests"],
    "journal-2": ["JournalAutoFillIntegrationTests", "JournalCheckInPersistenceTests"],
    "1": ["FiveTabRoutingTests", "SIHeartnavNavigationTests", "HandsFreeRoutingTests", "CoachProductionTests", "CoachPolishTests"],
    "2": ["HealthMetricPinsTests", "HealthMetricLoadingTests", "MetricContentCatalogTests", "MetricValueFormatTests", "MetricTrendNarrativeTests", "FixtureMetricHistoryProviderTests"],
    "3": ["MetricHabitAssociationTests", "MetricContentCatalogTests", "MetricValueFormatTests", "MetricTrendNarrativeTests", "FixtureMetricHistoryProviderTests", "MetricCorrelationMathTests", "MetricDetailRulesTests", "MetricDetailModelTests", "FixtureCorrelationTests", "MetricCorrelationCopyTests", "MetricLearningCountTests", "SIVitalsMetricDetailTests"],
    "4": ["YourDataTests", "DataRepositoryIntegrityTests", "PersistentDeletionTests", "PlatformDeletionTests"],
}

# Train steps follow the FT-04 commit mapping: train-1 is FT-04.1 (storage, rules, overview),
# train-2 FT-04.2 (library, builder), train-3 FT-04.3 (live session), train-4 FT-04.4
# (programs). A suite that is listed but does not exist fails the step with "Selected
# suites did not execute", so keep the lists true.
TRAIN_UI = {
    "ft05-5": ["TodayAgentUITests", "AgentSourcesUITests", "PatternsUITests", "CoachChatUITests", "CoachChatStateUITests", "CoachEntryUITests", "WakeAlarmUITests", "AskUITests", "FiveTabUITests", "SettingsAlertsUITests"],
    "train-1": ["TrainOverviewUITests"],
    "train-2": ["TemplateBuilderUITests"],
    "train-3": ["TrainSessionFlowUITests"],
    "train-4": ["TrainProgramUITests"],
}
TRAIN_PACKAGES = {
    "ft05-5": ["TodayKitTests", "SleepKitTests", "DesignSystemTests", "NotificationKitTests", "JournalKitTests", "OnboardingKitTests"],
    "train-1": ["TrainKitTests", "StorageKitTests", "DataKitTests"],
    "train-2": ["TrainKitTests", "DesignSystemTests"],
    "train-3": ["TrainKitTests", "WorkoutKitTests"],
    "train-4": ["TrainKitTests"],
}
TRAIN_PACKAGE_SUITES = {"train-1": ["TrainStoreTests"]}

def main():
    step = sys.argv[1] if len(sys.argv) == 2 else ""
    if step not in STEPS:
        raise RuntimeError("Expected 1 through 4, journal-1, journal-2, journal-3, food-1, food-2, food-2-ui, food-2-model, food-3, food-4, food-5, food-6, train-1 through train-4, or ft05-5")
    udid = os.environ.get("IOS_SIMULATOR_UDID")
    destination = os.environ.get("IOS_SIMULATOR_DESTINATION")
    if not udid or destination != f"platform=iOS Simulator,id={udid}" or not os.environ.get("IOS_SIMULATOR_NAME"):
        raise RuntimeError("Run through ios-simulator-worker.sh")
    subprocess.run(["pgrep", "-fl", "xcodebuild"], check=False)
    subprocess.run(["df", "-h", "/"], check=True)
    results = ROOT / "TestResults"
    results.mkdir(exist_ok=True)
    descriptor = os.open(results / ".loopr-test.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        metadata = os.fstat(lock.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_nlink != 1:
            raise RuntimeError("Invalid shared test lock")
        fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        processes = subprocess.check_output(["ps", "-ww", "-axo", "pid=,args="], text=True)
        for process in processes.splitlines():
            command = process.split(None, 1)[1] if " " in process.strip() else ""
            # A build queued behind lockf is waiting, not running; the running xcodebuild has its own line.
            if command.startswith("/usr/bin/lockf "):
                continue
            if "/xcodebuild " in process and ("-scheme Loopr " in process or "-scheme LooprPackages-Package " in process):
                raise RuntimeError(f"Another Loopr xcodebuild is active: {process.strip()}")
        requested = os.environ.get("LOOPR_RESULT_DIRECTORY")
        if requested:
            folder = Path(requested)
            if not folder.is_absolute() or folder.exists() or folder.is_symlink():
                raise RuntimeError("LOOPR_RESULT_DIRECTORY must be an unused absolute path")
            folder.mkdir(mode=0o700)
        else:
            folder = Path(tempfile.mkdtemp(prefix=f"five-tab-step-{step}.", dir=results))
        print(f"Evidence: {folder}", flush=True)
        common = ["-derivedDataPath", os.environ.get("LOOPR_DERIVED_DATA_PATH", "/tmp/loopr-dd-five-tabs"), "-jobs", "4", "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1", "-enableCodeCoverage", "YES", "OTHER_LDFLAGS=$(inherited) -framework AppIntents", "CODE_SIGNING_ALLOWED=NO"]
        # Focused checks build the architecture used by the leased simulator.
        # The full FAST lane retains its generic multi-architecture build.
        architecture = platform.machine()
        if architecture not in ("arm64", "x86_64"):
            raise RuntimeError(f"Unsupported simulator host architecture: {architecture}")
        common += [f"ARCHS={architecture}"]
        app = ["xcodebuild", "-project", str(ROOT / "Loopr/Loopr.xcodeproj"), "-scheme", "Loopr"] + common
        def command(args, name, cwd=ROOT):
            with (folder / f"{name}.log").open("w") as log:
                result = subprocess.run(args, cwd=cwd, stdout=log, stderr=subprocess.STDOUT)
            if result.returncode:
                raise RuntimeError(f"{name} failed: {folder / (name + '.log')}")
        reports = []
        def inspect(bundle, expected_suites=()):
            report = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)]))
            (folder / (bundle.stem + "-summary.json")).write_text(json.dumps(report, indent=2) + "\n")
            if report["result"] != "Passed" or report["totalTestCount"] <= 0 or report["passedTests"] != report["totalTestCount"] or any(report[key] for key in ("failedTests", "skippedTests", "expectedFailures")):
                raise RuntimeError(f"Test counts did not pass: {bundle}")
            if expected_suites:
                tree = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)]))
                def suites(node):
                    found = set()
                    if isinstance(node, dict):
                        if node.get("nodeType") == "Test Suite":
                            found.add(node["name"])
                        for value in node.values():
                            found.update(suites(value))
                    elif isinstance(node, list):
                        for value in node:
                            found.update(suites(value))
                    return found
                missing = set(expected_suites) - suites(tree)
                if missing:
                    raise RuntimeError(f"Selected suites did not execute: {sorted(missing)}")
            reports.append({"bundle": str(bundle), **{key: report[key] for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}})
            print(reports[-1], flush=True)
        command(app + ["-destination", "generic/platform=iOS Simulator", "build-for-testing"], "build")
        command(["xcrun", "simctl", "bootstatus", udid, "-b"], "simulator-boot")
        if STEPS[step]:
            unit = folder / "app-unit.xcresult"
            command(app + ["-destination", destination, "-resultBundlePath", str(unit)] + [f"-only-testing:LooprTests/{target}" for target in STEPS[step]] + ["test-without-building"], "app-unit")
            inspect(unit, STEPS[step])
        if step in ("1", "journal-1", "journal-2", "journal-3", "food-2", "food-2-ui", "food-3", "food-4", "food-5", "food-6"):
            suite = "FoodReviewInteractionUITests" if step == "food-6" else "FoodAssociationUITests" if step == "food-5" else "FoodReviewUITests" if step == "food-4" else "FoodCaptureUITests" if step == "food-3" else "FoodOverviewUITests" if step.startswith("food-2") else "JournalFiveTabUITests" if step.startswith("journal-") else "FiveTabShellUITests"
            ui = folder / "shell-ui.xcresult"
            ui_suites = [suite]
            if step == "food-4": ui_suites.append("FoodCaptureUITests")
            if step == "food-6": ui_suites += ["FoodReviewUITests", "FoodCaptureUITests", "FoodOverviewUITests", "FoodAssociationUITests"]
            command(app + ["-destination", destination, "-resultBundlePath", str(ui)] + [f"-only-testing:LooprUITests/{name}" for name in ui_suites] + ["test-without-building"], "shell-ui")
            inspect(ui, ui_suites)
        if step in ("1", "2", "4", "journal-1", "journal-2", "journal-3", "food-1", "food-2", "food-2-model", "food-3", "food-4", "food-5", "food-6"):
            package = folder / "design-system.xcresult"
            selection = ["-only-testing:DesignSystemTests"]
            if step.startswith("journal-"): selection.append("-only-testing:JournalKitTests")
            if step == "food-6": selection = ["-only-testing:FoodKitTests", "-only-testing:DesignSystemTests"]
            if step == "food-5": selection = ["-only-testing:FoodKitTests", "-only-testing:JournalKitTests", "-only-testing:DesignSystemTests"]
            if step == "food-4": selection = ["-only-testing:AIKitTests", "-only-testing:FoodKitTests", "-only-testing:StorageKitTests", "-only-testing:DesignSystemTests"]
            if step == "food-3": selection = ["-only-testing:FoodKitTests", "-only-testing:StorageKitTests", "-only-testing:DesignSystemTests"]
            if step == "food-1": selection = ["-only-testing:FoodKitTests", "-only-testing:StorageKitTests"]
            if step.startswith("food-2"): selection = [f"-only-testing:{name}Tests" for name in ("FoodKit", "StorageKit", "DesignSystem", "BodyKit", "JournalKit")]
            command(["xcodebuild", "-scheme", "LooprPackages-Package"] + common + ["-destination", destination, "-resultBundlePath", str(package)] + selection + ["ENABLE_APP_INTENTS_METADATA_EXTRACTION=NO", "test"], "design-system", ROOT / "LooprPackages")
            inspect(package, ["TargetProgressTests", "ReviewControlsTests", "FoodSharedControlsTests"] if step == "food-6" else ["FoodAssociationTests", "ScatterChartTests"] if step == "food-5" else ["FoodEstimateTests", "FoodFavoriteTests", "CoachStructuredTests", "CoachStructuredHTTPTests", "ReviewControlsTests"] if step == "food-4" else ["FoodBarcodeTests", "FoodLocalCaptureTests"] if step == "food-3" else ["FoodTargetTests", "FoodOverviewStoreTests", "TargetProgressTests"] if step.startswith("food-2") else ["FoodStoreTests"] if step == "food-1" else ["JournalInsightsTests", "RatingCalendarTests"] if step == "journal-3" else ["JournalAutoFillTests", "JournalCheckInTests"] if step == "journal-2" else ["JournalCheckInTests", "ChoiceControlTests"] if step == "journal-1" else ())
        if step in TRAIN_UI:
            ui = folder / "train-ui.xcresult"
            command(app + ["-destination", destination, "-resultBundlePath", str(ui)] + [f"-only-testing:LooprUITests/{name}" for name in TRAIN_UI[step]] + ["test-without-building"], "train-ui")
            inspect(ui, TRAIN_UI[step])
        if step in TRAIN_PACKAGES:
            package = folder / "train-packages.xcresult"
            selection = [f"-only-testing:{name}" for name in TRAIN_PACKAGES[step]]
            command(["xcodebuild", "-scheme", "LooprPackages-Package"] + common + ["-destination", destination, "-resultBundlePath", str(package)] + selection + ["ENABLE_APP_INTENTS_METADATA_EXTRACTION=NO", "test"], "train-packages", ROOT / "LooprPackages")
            inspect(package, TRAIN_PACKAGE_SUITES.get(step, ()))
        (folder / "report.json").write_text(json.dumps(reports, indent=2) + "\n")
        print(f"Step {step} passed: {folder / 'report.json'}", flush=True)

if __name__ == "__main__":
    main()
