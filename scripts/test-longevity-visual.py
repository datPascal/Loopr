#!/usr/bin/env python3
"""Longevity visual lane: light and dark captures of one package's screens.

Run inside a worker lease after a build-for-testing of the same tree and DerivedData
(scripts/lv-compile.sh through the compile queue):

  LOOPR_DERIVED_DATA_PATH=<dd> ios-simulator-worker.sh run loopr-lv-visual -- \
      python3 scripts/test-longevity-visual.py <phase>

Phases live in scripts/longevity-visual-phases.json: the capture suite, its test count and
each screen's slug with the element that proves the scroll reached the end. Captures that
pass in both appearances replace that phase's files in
docs/execution/visual-reviews/longevity/captures/ as <slug>[-n]-<light|dark>[<variant>].png.

Accessibility variants (LV-10.3): LOOPR_CAPTURE_CONTENT_SIZE sets the text size (default large,
for example accessibility-extra-extra-extra-large for AX5), LOOPR_CAPTURE_CONTRAST=enabled turns on
Increase Contrast, and LOOPR_CAPTURE_VARIANT (for example -ax5) names the files so the default
captures stay.
"""
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(os.environ.get("LOOPR_REPO_ROOT") or Path(__file__).resolve().parents[1])
PHASES = json.loads((ROOT / "scripts/longevity-visual-phases.json").read_text())
CAPTURES = Path(os.environ.get("LOOPR_CAPTURE_DIRECTORY", str(ROOT / "docs/execution/visual-reviews/longevity/captures")))
DERIVED = os.environ.get("LOOPR_DERIVED_DATA_PATH", "/private/tmp/loopr-lv/dd-lanes")
CONTENT_SIZE = os.environ.get("LOOPR_CAPTURE_CONTENT_SIZE", "large")
CONTRAST = os.environ.get("LOOPR_CAPTURE_CONTRAST", "disabled")
VARIANT = os.environ.get("LOOPR_CAPTURE_VARIANT", "")
if VARIANT and not re.fullmatch(r"-[a-z0-9-]+", VARIANT):
    raise SystemExit("LOOPR_CAPTURE_VARIANT must look like -ax5")
SLUG = r"(?:-(?:[2-9]|[1-9][0-9]+))?"


def run(arguments, log=None, env=None, cwd=ROOT):
    if log:
        with log.open("w") as output:
            return subprocess.run(arguments, cwd=cwd, stdout=output, stderr=subprocess.STDOUT, env=env).returncode
    return subprocess.run(arguments, cwd=cwd, env=env).returncode


def set_appearance(udid, appearance):
    # Shared workers keep whatever the last lease left; set both appearance and text size.
    for attempt in range(4):
        run(["xcrun", "simctl", "bootstatus", udid, "-b"])
        if run(["xcrun", "simctl", "ui", udid, "appearance", appearance]) == 0 and \
                run(["xcrun", "simctl", "ui", udid, "content_size", CONTENT_SIZE]) == 0 and \
                run(["xcrun", "simctl", "ui", udid, "increase_contrast", CONTRAST]) == 0:
            return
        if attempt < 3:
            time.sleep(15)
    raise RuntimeError(f"Could not set {appearance} appearance on {udid}")


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in PHASES:
        raise SystemExit(f"Usage: test-longevity-visual.py <{'|'.join(PHASES)}>")
    phase = PHASES[sys.argv[1]]
    screens = {screen["slug"]: screen["end"] for screen in phase["screens"]}
    udid = os.environ.get("IOS_SIMULATOR_UDID")
    destination = os.environ.get("IOS_SIMULATOR_DESTINATION")
    if not udid or destination != f"platform=iOS Simulator,id={udid}":
        raise RuntimeError("Run through ios-simulator-worker.sh")
    results = ROOT / "TestResults"
    results.mkdir(exist_ok=True)
    descriptor = os.open(results / ".loopr-test.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        metadata = os.fstat(lock.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_nlink != 1:
            raise RuntimeError("Invalid shared test lock")
        fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            return capture(phase, screens, udid, destination)
        finally:
            # Leave the shared worker as the fleet expects it.
            run(["xcrun", "simctl", "ui", udid, "content_size", "large"])
            run(["xcrun", "simctl", "ui", udid, "increase_contrast", "disabled"])


def capture(phase, screens, udid, destination):
    base = Path("/private/tmp/loopr-lv/results")
    base.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix=f"visual-{sys.argv[1]}.", dir=base))
    print(f"Visual evidence: {folder}", flush=True)
    command = ["xcodebuild", "-project", str(ROOT / "Loopr/Loopr.xcodeproj"), "-scheme", "Loopr",
               "-derivedDataPath", DERIVED, "ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO", "COMPILER_INDEX_STORE_ENABLE=NO",
               "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
               "OTHER_LDFLAGS=$(inherited) -framework AppIntents", "CODE_SIGNING_ALLOWED=NO"]
    outputs, reports, failed = {}, [], False
    for appearance in ("light", "dark"):
        set_appearance(udid, appearance)
        bundle = folder / f"{appearance}.xcresult"
        env = dict(os.environ, LOOPR_CAPTURE_APPEARANCE=appearance)
        if CONTENT_SIZE != "large":
            env["TEST_RUNNER_LOOPR_CAPTURE_MAX_VIEWPORTS"] = os.environ.get("LOOPR_CAPTURE_MAX_VIEWPORTS", "48")
        status = run(command + ["-destination", destination, f"-only-testing:LooprUITests/{phase['suite']}",
                                "-resultBundlePath", str(bundle), "test-without-building"], folder / f"{appearance}.log", env)
        summary = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)]))
        counts = {key: summary[key] for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")}
        reports.append(dict(appearance=appearance, bundle=str(bundle), **counts))
        failed |= status != 0 or summary["result"] != "Passed" or counts["totalTestCount"] != phase["tests"] \
            or counts["passedTests"] != phase["tests"] or any(counts[key] for key in ("failedTests", "skippedTests", "expectedFailures"))
        staging = folder / f"{appearance}-attachments"
        run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle), "--output-path", str(staging)])
        manifest = json.loads((staging / "manifest.json").read_text()) if (staging / "manifest.json").exists() else []
        captured, coverage = set(), {}
        for test in manifest:
            for attachment in test.get("attachments", []):
                name = attachment.get("suggestedHumanReadableName", "")
                if name.startswith("Longevity Coverage "):
                    record = json.loads((staging / attachment["exportedFileName"]).read_text())
                    coverage[record["screen"]] = record
                elif name.startswith("Longevity Screen "):
                    screen = name.removeprefix("Longevity Screen ").split("_")[0]
                    if any(re.fullmatch(re.escape(slug) + SLUG, screen) for slug in screens):
                        outputs[f"{screen}-{appearance}{VARIANT}.png"] = staging / attachment["exportedFileName"]
                        captured.add(screen)
        for slug, end in screens.items():
            record = coverage.get(slug, {})
            expected = {slug} | {f"{slug}-{index}" for index in range(2, record.get("viewports", 0) + 1)}
            if not record.get("reachedEnd") or record.get("lastElement") != end or not expected <= captured:
                failed = True
                print(f"Incomplete {appearance} coverage: {slug}", flush=True)
        print(f"{appearance}: {counts}", flush=True)
        if failed:
            break
    (folder / "report.json").write_text(json.dumps(reports, indent=2) + "\n")
    if failed:
        print(f"Visual lane {sys.argv[1]} failed: {folder}", flush=True)
        return 1
    CAPTURES.mkdir(parents=True, exist_ok=True)
    for path in CAPTURES.glob("*.png"):
        if any(re.fullmatch(re.escape(slug) + SLUG + r"-(?:light|dark)" + re.escape(VARIANT) + r"\.png", path.name) for slug in screens):
            path.unlink()
    for name, source in outputs.items():
        shutil.copyfile(source, CAPTURES / name)
    print(f"Visual lane {sys.argv[1]} passed: {len(outputs)} captures in {CAPTURES}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
