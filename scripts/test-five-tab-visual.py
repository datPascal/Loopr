#!/usr/bin/env python3
"""Five-tab visual lane. Called by test-visual/capture-design-screens inside a fleet lease."""
import fcntl
import json
import os
import platform
import re
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "TestResults"
CAPTURES = Path(os.environ.get("LOOPR_CAPTURE_DIRECTORY", str(ROOT / "docs/execution/visual-reviews/five-tab/captures")))
DERIVED = Path(os.environ.get("LOOPR_DERIVED_DATA_PATH", "/tmp/loopr-dd-five-tabs"))
PHASE = os.environ.get("LOOPR_VISUAL_PHASE", "FT-01")
SCREENS = ("01-today", "02-health", "03-sleep", "04-metric-detail", "05-all-metrics", "18-your-data")
END_ELEMENTS = dict(zip(SCREENS, ("today-your-day", "health-explore-metrics", "sleep-wake-alarm-card",
    "metric-detail-methodology-open", "metric-library-recording-note", "your-data-delete")))
SUITE, TEST_COUNT = "FiveTabUITests", 7
if PHASE == "FT-02":
    SCREENS = ("14-check-in", "15-insights")
    END_ELEMENTS = dict(zip(SCREENS, ("journal-edit-questions", "journal-insights-ask")))
    SUITE, TEST_COUNT = "JournalVisualUITests", 3
elif PHASE == "FT-03":
    SCREENS = ("06-food", "07-capture", "08-ai-review", "09-food-and-body")
    END_ELEMENTS = dict(zip(SCREENS, ("food-week", "food-lens-hint", "food-review-source", "food-association-1")))
    SUITE, TEST_COUNT = "FoodVisualUITests", 5
elif PHASE == "FT-04":
    SCREENS = ("10-train", "11-workout-builder", "12-live-session", "13-program")
    END_ELEMENTS = dict(zip(SCREENS, ("train-this-week-list", "template-rule-band-cue", "train-rest-timer", "program-change-plan")))
    SUITE, TEST_COUNT = "TrainVisualUITests", 5
elif PHASE == "FT-05":
    SCREENS = ("16-ask", "17-patterns", "01-today", "03-sleep")
    END_ELEMENTS = dict(zip(SCREENS, ("ask-composer", "patterns-settings-card", "today-timeline-end", "sleep-wake-alarm-card")))
    SUITE, TEST_COUNT = "AgentVisualUITests", 4
elif PHASE != "FT-01":
    raise RuntimeError("Expected LOOPR_VISUAL_PHASE FT-01, FT-02, FT-03, FT-04 or FT-05")

def run(arguments, log=None, env=None):
    if log:
        with log.open("w") as output:
            return subprocess.run(arguments, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, env=env).returncode
    return subprocess.run(arguments, cwd=ROOT, check=True, env=env)

def publish_captures(folder, outputs):
    """Replace only this lane's captures after both appearances pass."""
    folder.mkdir(parents=True, exist_ok=True)
    for path in folder.glob("*.png"):
        if any(re.fullmatch(re.escape(slug) + r"(?:-(?:[2-9]|[1-9][0-9]+))?-(?:light|dark)\.png", path.name)
               for slug in SCREENS):
            path.unlink()
    for name, source in outputs.items():
        shutil.copyfile(source, folder / name)

def main():
    udid = os.environ.get("IOS_SIMULATOR_UDID")
    destination = os.environ.get("IOS_SIMULATOR_DESTINATION")
    if not udid or destination != f"platform=iOS Simulator,id={udid}" or not os.environ.get("IOS_SIMULATOR_NAME"):
        raise RuntimeError("Run through ios-simulator-worker.sh; a matching fleet lease is required")
    subprocess.run(["pgrep", "-fl", "xcodebuild"], check=False)
    run(["df", "-h", "/"])
    RESULTS.mkdir(exist_ok=True)
    lock_path = RESULTS / ".loopr-test.lock"
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as lock:
        metadata = os.fstat(lock.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_nlink != 1:
            raise RuntimeError("Invalid shared test lock")
        fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # This is the same POSIX record lock used by the canonical fast lane.
        processes = subprocess.check_output(["ps", "-ww", "-axo", "pid=,args="], text=True)
        for process in processes.splitlines():
            command = process.split(None, 1)[1] if " " in process.strip() else ""
            # A build queued behind lockf is waiting, not running; the running xcodebuild has its own line.
            if command.startswith("/usr/bin/lockf "):
                continue
            if "/xcodebuild " in process and ("-scheme Loopr " in process or "-scheme LooprPackages-Package " in process):
                raise RuntimeError(f"Another Loopr xcodebuild is active: {process.strip()}")
        if requested := os.environ.get("LOOPR_RESULT_DIRECTORY"):
            folder = Path(requested)
            if not folder.is_absolute():
                raise RuntimeError("LOOPR_RESULT_DIRECTORY must be absolute")
            folder.mkdir(mode=0o700)
        else:
            folder = Path(tempfile.mkdtemp(prefix="five-tab-visual.", dir=RESULTS))
        print(f"Visual evidence: {folder}", flush=True)
        architecture = platform.machine()
        if architecture not in ("arm64", "x86_64"):
            raise RuntimeError(f"Unsupported simulator host architecture: {architecture}")
        # Capture the leased simulator's architecture. FAST still builds both.
        base = ["xcodebuild", "-project", str(ROOT / "Loopr/Loopr.xcodeproj"), "-scheme", "Loopr", "-derivedDataPath", str(DERIVED), "-jobs", "4", f"ARCHS={architecture}", "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1", "OTHER_LDFLAGS=$(inherited) -framework AppIntents", "CODE_SIGNING_ALLOWED=NO"]
        status = run(base + ["-destination", "generic/platform=iOS Simulator", "build-for-testing"], folder / "build.log")
        if status:
            raise RuntimeError(f"Build failed ({status}): {folder / 'build.log'}")
        # The fleet grants ownership but leaves booting to the lane. Native
        # appearance changes require the leased device to be running.
        devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"]))
        (folder / "devices-before-boot.json").write_text(json.dumps(devices, indent=2) + "\n")
        if not any(device["udid"] == udid and device.get("isAvailable", False)
                   for runtime in devices["devices"].values() for device in runtime):
            raise RuntimeError("Leased device is unavailable")
        run(["xcrun", "simctl", "bootstatus", udid, "-b"])
        CAPTURES.mkdir(parents=True, exist_ok=True)
        reports = []
        outputs = {}
        failed = False
        for appearance in ("light", "dark"):
            # simctl ui can fail transiently on a loaded host; confirm boot and retry before giving up.
            for attempt in range(4):
                run(["xcrun", "simctl", "bootstatus", udid, "-b"])
                # Shared workers keep whatever text size the last lease left; captures use the default size.
                if (subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", appearance], cwd=ROOT).returncode == 0
                        and subprocess.run(["xcrun", "simctl", "ui", udid, "content_size", "large"], cwd=ROOT).returncode == 0):
                    break
                if attempt == 3:
                    raise RuntimeError(f"Could not set {appearance} appearance and default text size on {udid}")
                time.sleep(15)
            bundle = folder / f"{appearance}.xcresult"
            env = dict(os.environ, LOOPR_CAPTURE_APPEARANCE=appearance)
            status = run(base + ["-destination", destination, f"-only-testing:LooprUITests/{SUITE}", "-resultBundlePath", str(bundle), "test-without-building"], folder / f"{appearance}.log", env)
            summary = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)]))
            (folder / f"{appearance}-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
            counts = {key: summary[key] for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")}
            reports.append(dict(appearance=appearance, bundle=str(bundle), **counts))
            failed |= status != 0 or summary["result"] != "Passed" or counts["passedTests"] != TEST_COUNT or counts["totalTestCount"] != TEST_COUNT or any(counts[key] for key in ("failedTests", "skippedTests", "expectedFailures"))
            staging = folder / f"{appearance}-attachments"
            run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle), "--output-path", str(staging)])
            manifest = json.loads((staging / "manifest.json").read_text())
            captured = set()
            coverage = {}
            for test in manifest:
                for attachment in test.get("attachments", []):
                    name = attachment.get("suggestedHumanReadableName", "")
                    if name.startswith("FiveTab Coverage "):
                        record = json.loads((staging / attachment["exportedFileName"]).read_text())
                        coverage[record["screen"]] = record
                        continue
                    if not name.startswith("FiveTab Screen "):
                        continue
                    screen = name.removeprefix("FiveTab Screen ").split("_candidate")[0]
                    if not any(re.fullmatch(re.escape(slug) + r"(?:-(?:[2-9]|[1-9][0-9]+))?", screen) for slug in SCREENS):
                        continue
                    source = staging / attachment["exportedFileName"]
                    outputs[f"{screen}-{appearance}.png"] = source
                    captured.add(screen)
            missing = set(SCREENS) - captured
            if missing:
                failed = True
                print(f"Missing {appearance} captures: {sorted(missing)}", flush=True)
            for screen in SCREENS:
                record = coverage.get(screen, {})
                count = record.get("viewports", 0)
                expected = {screen} | {f"{screen}-{index}" for index in range(2, count + 1)}
                if (not record.get("reachedEnd") or record.get("lastElement") != END_ELEMENTS[screen]
                        or count < 1 or not expected.issubset(captured)):
                    failed = True
                    print(f"Incomplete {appearance} scroll coverage: {screen}", flush=True)
            (folder / f"{appearance}-coverage.json").write_text(json.dumps(coverage, indent=2) + "\n")
            print(f"{appearance}: {counts}", flush=True)
            if failed:
                break
        (folder / "report.json").write_text(json.dumps(reports, indent=2) + "\n")
        print(f"Evidence: {folder / 'report.json'}", flush=True)
        if not failed:
            publish_captures(CAPTURES, outputs)
        return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main())
