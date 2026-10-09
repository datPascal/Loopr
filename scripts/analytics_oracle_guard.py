#!/usr/bin/env python3
"""Validate the host/UTC behavior of the pinned OpenStrap Dart oracle.

The pinned sleep fixtures use relative Unix-epoch timestamps.  They therefore
inherit the host timezone when the production daytime guard evaluates them.
This module intentionally treats that behavior as a bounded, named baseline
delta rather than hiding it behind a retry or a source change.
"""

from __future__ import annotations

import json
import hashlib
import pathlib
import sys
import tempfile
from typing import Any


EXPECTED_FAILURES: dict[str, str] = {
    "segmentSleep single-source segmentation (a) still + low-HR night → one window, tst≈in-bed, eff high, figures consistent": "270:7",
    "segmentSleep single-source segmentation (b) brief mid-night movements do NOT fragment the window": "359:7",
    "segmentSleep single-source segmentation (d) brief 2-3 min arousals are rescored → high efficiency": "546:7",
}
EXPECTED_TEST_FILE = "test/onehz/sleep_test.dart"
EXPECTED_UTC_PASSES = 382
EXPECTED_HOST_PASSES = EXPECTED_UTC_PASSES - len(EXPECTED_FAILURES)
EXPECTED_SKIPS = 6
EXPECTED_HIDDEN_TESTS = 19
EXPECTED_TEST_MANIFEST_SHA256 = "99ead519cfb7eb7bf22c87b908d87f1540bd06985c1846da5ce2c426930c6018"
TEST_MANIFEST = pathlib.Path(__file__).resolve().with_name("analytics_oracle_test_names.txt")


class OracleReportError(ValueError):
    """Raised when a Dart JSON test report violates the oracle contract."""


def _load_test_inventory(path: pathlib.Path = TEST_MANIFEST) -> tuple[str, ...]:
    """Load and hash-pin the visible test names for the pinned oracle."""

    try:
        raw = path.read_bytes()
    except OSError as error:
        raise OracleReportError(f"cannot read test-name manifest {path}: {error}") from error
    digest = hashlib.sha256(raw).hexdigest()
    if digest != EXPECTED_TEST_MANIFEST_SHA256:
        raise OracleReportError(
            f"test-name manifest SHA-256 mismatch for {path}: {digest}; "
            f"expected {EXPECTED_TEST_MANIFEST_SHA256}"
        )
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise OracleReportError(f"test-name manifest is not UTF-8: {path}") from error
    names: list[str] = []
    seen: set[str] = set()
    for line_number, line in enumerate(lines, start=1):
        if not line or line.startswith("#"):
            continue
        if line in seen:
            raise OracleReportError(
                f"test-name manifest contains duplicate name at line {line_number}: {line!r}"
            )
        seen.add(line)
        names.append(line)
    if not names:
        raise OracleReportError(f"test-name manifest is empty: {path}")
    return tuple(names)


def _read_events(path: pathlib.Path) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    try:
        with path.open("r", encoding="utf-8") as stream:
            for line_number, line in enumerate(stream, start=1):
                if not line.strip():
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError as error:
                    raise OracleReportError(
                        f"{path}: invalid JSON at line {line_number}: {error}"
                    ) from error
                if not isinstance(event, dict):
                    raise OracleReportError(
                        f"{path}: JSON event at line {line_number} is not an object"
                    )
                events.append(event)
    except OSError as error:
        raise OracleReportError(f"cannot read Dart report {path}: {error}") from error
    if not events:
        raise OracleReportError(f"Dart report is empty: {path}")
    return events


def _parse_report(path: pathlib.Path) -> dict[str, Any]:
    """Parse visible test outcomes and failure stacks from a Dart report."""

    starts: dict[int, str] = {}
    started_names: set[str] = set()
    done: set[int] = set()
    errors: dict[int, list[str]] = {}
    failures: dict[str, str] = {}
    hidden_failures: dict[str, str] = {}
    outcomes: dict[str, str] = {}
    hidden_count = 0
    skipped_count = 0
    passed_count = 0
    for event in _read_events(path):
        event_type = event.get("type")
        if event_type == "testStart":
            test = event.get("test")
            if not isinstance(test, dict) or not isinstance(test.get("id"), int):
                raise OracleReportError(f"{path}: malformed testStart event")
            test_id = test["id"]
            name = test.get("name")
            if not isinstance(name, str) or not name:
                raise OracleReportError(f"{path}: testStart {test_id!r} has no name")
            if test_id in starts:
                raise OracleReportError(f"{path}: duplicate testStart id {test_id}")
            if name in started_names:
                raise OracleReportError(f"{path}: duplicate test name {name!r}")
            starts[test_id] = name
            started_names.add(name)
        elif event_type == "error":
            test_id = event.get("testID")
            if not isinstance(test_id, int) or test_id not in starts:
                raise OracleReportError(
                    f"{path}: error event has no preceding testStart: {test_id!r}"
                )
            error = event.get("error")
            stack = event.get("stackTrace")
            parts = []
            if isinstance(error, str):
                parts.append(error)
            if isinstance(stack, str):
                parts.append(stack)
            errors.setdefault(test_id, []).append("\n".join(parts))
        elif event_type == "testDone":
            test_id = event.get("testID")
            if not isinstance(test_id, int) or test_id not in starts:
                raise OracleReportError(
                    f"{path}: testDone event has no preceding testStart: {test_id!r}"
                )
            if test_id in done:
                raise OracleReportError(f"{path}: duplicate testDone id {test_id}")
            done.add(test_id)
            name = starts[test_id]
            hidden = event.get("hidden", False)
            if not isinstance(hidden, bool):
                raise OracleReportError(f"{path}: testDone {test_id} has non-boolean hidden flag")
            if hidden:
                hidden_count += 1
                if event.get("result") == "failure":
                    hidden_failures[name] = "\n".join(errors.get(test_id, []))
                elif event.get("result") != "success":
                    raise OracleReportError(
                        f"{path}: unsupported hidden test outcome for {name!r}: "
                        f"{event.get('result')!r}"
                    )
                continue
            if event.get("result") == "failure":
                stack = "\n".join(errors.get(test_id, []))
                if name in failures:
                    raise OracleReportError(f"{path}: duplicate failure for {name!r}")
                failures[name] = stack
                outcomes[name] = "failure"
            elif event.get("skipped", False):
                if name in outcomes:
                    raise OracleReportError(f"{path}: duplicate outcome for {name!r}")
                outcomes[name] = "skipped"
                skipped_count += 1
            elif event.get("result") == "success":
                if name in outcomes:
                    raise OracleReportError(f"{path}: duplicate outcome for {name!r}")
                outcomes[name] = "success"
                passed_count += 1
            else:
                raise OracleReportError(
                    f"{path}: unsupported visible test outcome for {name!r}: "
                    f"{event.get('result')!r}"
                )
    missing = set(starts) - done
    if missing:
        raise OracleReportError(
            f"{path}: testStart events without exactly one testDone: {sorted(missing)!r}"
        )
    return {
        "failures": failures,
        "hidden_failures": hidden_failures,
        "outcomes": outcomes,
        "hidden_count": hidden_count,
        "passed_count": passed_count,
        "skipped_count": skipped_count,
    }


def failed_tests(path: pathlib.Path) -> dict[str, str]:
    """Return failed test name -> stack trace from a Dart JSON report."""

    return _parse_report(path)["failures"]


def validate(
    host_report: pathlib.Path,
    utc_report: pathlib.Path,
    host_status: int,
    utc_status: int,
    manifest_path: pathlib.Path = TEST_MANIFEST,
) -> None:
    """Validate the accepted host-vs-UTC oracle delta."""

    inventory = set(_load_test_inventory(manifest_path))
    host_summary = _parse_report(host_report)
    utc_summary = _parse_report(utc_report)
    host_failures = host_summary["failures"]
    utc_failures = utc_summary["failures"]
    expected = set(EXPECTED_FAILURES)

    if not expected <= inventory:
        raise OracleReportError(
            "expected host-TZ failures are absent from the canonical test inventory: "
            + repr(sorted(expected - inventory))
        )

    if host_status != 1:
        raise OracleReportError(
            f"host-TZ Dart suite exited {host_status}; expected exactly 3 known failures"
        )
    if utc_status != 0:
        raise OracleReportError(f"TZ=UTC Dart suite exited {utc_status}; expected 0")

    if utc_summary["passed_count"] != EXPECTED_UTC_PASSES:
        raise OracleReportError(
            f"TZ=UTC Dart suite reported {utc_summary['passed_count']} passing tests; "
            f"expected {EXPECTED_UTC_PASSES}"
        )
    if host_summary["passed_count"] != EXPECTED_HOST_PASSES:
        raise OracleReportError(
            f"host-TZ Dart suite reported {host_summary['passed_count']} passing tests; "
            f"expected {EXPECTED_HOST_PASSES}"
        )
    if utc_summary["skipped_count"] != EXPECTED_SKIPS:
        raise OracleReportError(
            f"TZ=UTC Dart suite reported {utc_summary['skipped_count']} skips; "
            f"expected {EXPECTED_SKIPS}"
        )
    if host_summary["skipped_count"] != EXPECTED_SKIPS:
        raise OracleReportError(
            f"host-TZ Dart suite reported {host_summary['skipped_count']} skips; "
            f"expected {EXPECTED_SKIPS}"
        )
    if host_summary["hidden_count"] != utc_summary["hidden_count"]:
        raise OracleReportError(
            "host/UTC hidden loader-test counts differ: "
            f"{host_summary['hidden_count']} vs {utc_summary['hidden_count']}"
        )
    if host_summary["hidden_count"] != EXPECTED_HIDDEN_TESTS:
        raise OracleReportError(
            f"host-TZ report has {host_summary['hidden_count']} hidden tests; "
            f"expected {EXPECTED_HIDDEN_TESTS}"
        )
    if host_summary["hidden_failures"] or utc_summary["hidden_failures"]:
        raise OracleReportError(
            "hidden test failures are not accepted: "
            f"host={sorted(host_summary['hidden_failures'])!r}, "
            f"UTC={sorted(utc_summary['hidden_failures'])!r}"
        )

    if set(host_failures) != expected:
        missing = sorted(expected - set(host_failures))
        unexpected = sorted(set(host_failures) - expected)
        raise OracleReportError(
            "host-TZ failure set differs from the accepted three-case delta; "
            f"missing={missing!r}, unexpected={unexpected!r}"
        )
    if utc_failures:
        raise OracleReportError(
            "TZ=UTC Dart suite has failures: " + repr(sorted(utc_failures))
        )

    host_outcomes = host_summary["outcomes"]
    utc_outcomes = utc_summary["outcomes"]
    if set(host_outcomes) != inventory:
        missing = sorted(inventory - set(host_outcomes))
        unexpected = sorted(set(host_outcomes) - inventory)
        raise OracleReportError(
            "host-TZ visible test inventory differs from the pinned manifest; "
            f"missing={missing!r}, unexpected={unexpected!r}"
        )
    if set(utc_outcomes) != inventory:
        missing = sorted(inventory - set(utc_outcomes))
        unexpected = sorted(set(utc_outcomes) - inventory)
        raise OracleReportError(
            "TZ=UTC visible test inventory differs from the pinned manifest; "
            f"missing={missing!r}, unexpected={unexpected!r}"
        )
    for name in sorted(host_outcomes):
        if name in expected:
            if host_outcomes[name] != "failure" or utc_outcomes[name] != "success":
                raise OracleReportError(
                    f"known host/UTC delta is not failure→success for {name!r}: "
                    f"{host_outcomes[name]!r}→{utc_outcomes[name]!r}"
                )
        elif host_outcomes[name] != utc_outcomes[name]:
            raise OracleReportError(
                f"unexpected host/UTC outcome delta for {name!r}: "
                f"{host_outcomes[name]!r}→{utc_outcomes[name]!r}"
            )

    for name, line in EXPECTED_FAILURES.items():
        stack = host_failures[name]
        expected_location = f"{EXPECTED_TEST_FILE} {line}"
        if expected_location not in stack:
            raise OracleReportError(
                f"known failure {name!r} did not point at {expected_location}; "
                f"stack={stack!r}"
            )

    print(
        "analytics oracle: visible totals host="
        f"{host_summary['passed_count']} pass/{len(host_failures)} fail/"
        f"{host_summary['skipped_count']} skip, UTC="
        f"{utc_summary['passed_count']} pass/{len(utc_failures)} fail/"
        f"{utc_summary['skipped_count']} skip"
    )
    print("analytics oracle: host-TZ failures = (a), (b), (d)")
    print("analytics oracle: TZ=UTC failures = none")
    print("analytics oracle: PASS (host-vs-UTC delta is exactly the accepted three cases)")


def _event_report(failures: dict[str, str]) -> str:
    """Build the smallest valid JSON reporter stream for self-tests."""

    lines = [
        json.dumps(
            {
                "protocolVersion": "0.1.1",
                "runnerVersion": "self-test",
                "type": "start",
            }
        )
    ]
    test_id = 1
    for name, stack in failures.items():
        lines.append(
            json.dumps(
                {
                    "test": {
                        "id": test_id,
                        "name": name,
                        "suiteID": 0,
                        "groupIDs": [],
                        "metadata": {"skip": False},
                    },
                    "type": "testStart",
                }
            )
        )
        lines.append(
            json.dumps(
                {
                    "testID": test_id,
                    "error": "Expected: true",
                    "stackTrace": stack,
                    "type": "error",
                }
            )
        )
        lines.append(
            json.dumps(
                {"testID": test_id, "result": "failure", "type": "testDone"}
            )
        )
        test_id += 1
    return "\n".join(lines) + "\n"


def _complete_event_report(
    *,
    failures: dict[str, str],
    success_names: tuple[str, ...],
    skip_names: tuple[str, ...],
    hidden_names: tuple[str, ...] = (),
) -> str:
    """Build a manifest-complete synthetic report for the parser self-test."""

    lines = _event_report(failures).rstrip("\n").splitlines()
    next_id = len(failures) + 1
    for name in success_names:
        lines.extend(
            [
                json.dumps({"test": {"id": next_id, "name": name}, "type": "testStart"}),
                json.dumps(
                    {"testID": next_id, "result": "success", "skipped": False, "hidden": False, "type": "testDone"}
                ),
            ]
        )
        next_id += 1
    for name in skip_names:
        lines.extend(
            [
                json.dumps({"test": {"id": next_id, "name": name}, "type": "testStart"}),
                json.dumps(
                    {"testID": next_id, "result": "success", "skipped": True, "hidden": False, "type": "testDone"}
                ),
            ]
        )
        next_id += 1
    for name in hidden_names:
        lines.extend(
            [
                json.dumps({"test": {"id": next_id, "name": name}, "type": "testStart"}),
                json.dumps(
                    {"testID": next_id, "result": "success", "skipped": False, "hidden": True, "type": "testDone"}
                ),
            ]
        )
        next_id += 1
    return "\n".join(lines) + "\n"


def self_test() -> None:
    """Exercise both the positive contract and representative fail-closed paths."""

    with tempfile.TemporaryDirectory(prefix="loopr-analytics-oracle-self-test-") as directory:
        root = pathlib.Path(directory)
        host = root / "host.json"
        utc = root / "utc.json"
        inventory = _load_test_inventory()
        host_failures = {
            name: f"{EXPECTED_TEST_FILE} {line}"
            for name, line in EXPECTED_FAILURES.items()
        }
        skip_names = tuple(
            name for name in inventory if name not in EXPECTED_FAILURES
        )[-EXPECTED_SKIPS:]
        host_success_names = tuple(
            name
            for name in inventory
            if name not in EXPECTED_FAILURES and name not in skip_names
        )
        utc_success_names = tuple(
            name for name in inventory if name not in skip_names
        )
        hidden_names = tuple(f"loading oracle hidden {index}" for index in range(EXPECTED_HIDDEN_TESTS))
        host.write_text(
            _complete_event_report(
                failures=host_failures,
                success_names=host_success_names,
                skip_names=skip_names,
                hidden_names=hidden_names,
            ),
            encoding="utf-8",
        )
        utc.write_text(
            _complete_event_report(
                failures={},
                success_names=utc_success_names,
                skip_names=skip_names,
                hidden_names=hidden_names,
            ),
            encoding="utf-8",
        )
        validate(host, utc, 1, 0)

        try:
            validate(host, utc, 0, 0)
        except OracleReportError:
            pass
        else:
            raise AssertionError("wrong host exit status was accepted")

        wrong = root / "wrong.json"
        wrong_failure = next(iter(EXPECTED_FAILURES))
        wrong.write_text(
            _complete_event_report(
                failures={wrong_failure: "wrong.dart 1:1"},
                success_names=tuple(
                    name
                    for name in inventory
                    if name != wrong_failure and name not in skip_names
                ),
                skip_names=skip_names,
                hidden_names=hidden_names,
            ),
            encoding="utf-8",
        )
        try:
            validate(wrong, utc, 1, 0)
        except OracleReportError:
            pass
        else:
            raise AssertionError("incomplete failure set was accepted")

        truncated = root / "truncated.json"
        truncated.write_text(
            _complete_event_report(
                failures=host_failures,
                success_names=host_success_names[:-1],
                skip_names=skip_names,
                hidden_names=hidden_names,
            ),
            encoding="utf-8",
        )
        try:
            validate(truncated, utc, 1, 0)
        except OracleReportError:
            pass
        else:
            raise AssertionError("truncated visible inventory was accepted")

        replacement = root / "replacement.json"
        replacement.write_text(
            _complete_event_report(
                failures=host_failures,
                success_names=host_success_names[:-1] + ("synthetic replacement",),
                skip_names=skip_names,
                hidden_names=hidden_names,
            ),
            encoding="utf-8",
        )
        try:
            validate(replacement, utc, 1, 0)
        except OracleReportError:
            pass
        else:
            raise AssertionError("replacement visible inventory was accepted")

        duplicate = root / "duplicate.json"
        duplicate.write_text(
            host.read_text(encoding="utf-8")
            + json.dumps({"testID": 1, "result": "success", "hidden": True, "type": "testDone"})
            + "\n",
            encoding="utf-8",
        )
        try:
            _parse_report(duplicate)
        except OracleReportError:
            pass
        else:
            raise AssertionError("duplicate testDone was accepted")

        orphan = root / "orphan.json"
        orphan.write_text(
            host.read_text(encoding="utf-8")
            + json.dumps({"testID": 999999, "result": "success", "hidden": False, "type": "testDone"})
            + "\n",
            encoding="utf-8",
        )
        try:
            _parse_report(orphan)
        except OracleReportError:
            pass
        else:
            raise AssertionError("orphan testDone was accepted")

        unclosed = root / "unclosed.json"
        unclosed.write_text(
            "\n".join(host.read_text(encoding="utf-8").rstrip("\n").splitlines()[:-1]) + "\n",
            encoding="utf-8",
        )
        try:
            _parse_report(unclosed)
        except OracleReportError:
            pass
        else:
            raise AssertionError("unclosed testStart was accepted")
    print("analytics oracle guard self-test: PASS")


def main(argv: list[str]) -> int:
    if argv == ["--self-test"]:
        self_test()
        return 0
    if len(argv) != 5 or argv[0] != "validate":
        print(
            "usage: analytics_oracle_guard.py validate HOST_JSON UTC_JSON HOST_STATUS UTC_STATUS",
            file=sys.stderr,
        )
        return 64
    try:
        validate(
            pathlib.Path(argv[1]),
            pathlib.Path(argv[2]),
            int(argv[3]),
            int(argv[4]),
        )
    except (OracleReportError, ValueError) as error:
        print(f"analytics oracle: FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
