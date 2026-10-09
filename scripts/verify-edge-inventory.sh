#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 - "$repo_root" <<'PY'
import hashlib, json, re, subprocess, sys
from pathlib import Path

root = Path(sys.argv[1])
path = root / "Fixtures/UI/edge-route-manifest.json"
document = json.loads(path.read_text(), object_pairs_hook=lambda pairs: dict(pairs) if len(pairs) == len(dict(pairs)) else (_ for _ in ()).throw(ValueError("duplicate JSON key")))
entries = document["entries"]
routes = [entry["route"] for entry in entries]
assert len(routes) == len(set(routes)) and routes
captured = unreproducible = 0
for entry in entries:
    assert entry["verification_level"] == "code"
    assert entry["appearance_targets"] == ["light", "dark"]
    assert entry["major_section_order"] and entry["source_citations"]
    state_names = {state["name"] for state in entry["fixture_state"]["states"]}
    assert set(entry["screenshot_evidence"]["targets"]) == state_names
    for citation in entry["source_citations"]:
        relative = citation["file"].removeprefix("OpenStrap Code/edge/")
        result = subprocess.run(["git", "-C", str(root / "OpenStrap Code/edge"), "show", f"d911f60e75d99a6ac0d7ef22a5084a18a7058445:{relative}"], capture_output=True, check=True)
        lines = result.stdout.splitlines()
        assert 1 <= citation["line_start"] <= citation["line_end"] <= len(lines)
    for appearances in entry["screenshot_evidence"]["targets"].values():
        assert set(appearances) == {"light", "dark"}
        for target in appearances.values():
            if target["status"] == "captured":
                artifact = root / target["artifact"]
                assert artifact.is_file() and artifact.suffix.lower() == ".png"
                assert hashlib.sha256(artifact.read_bytes()).hexdigest() == target["checksum"]
                captured += 1
            else:
                assert target["status"] == "unreproducible" and target["artifact"] is None and target["checksum"] is None and target["reason"]
                unreproducible += 1
assert document["manifest_metadata"]["captured_target_count"] == captured
assert document["manifest_metadata"]["unreproducible_target_count"] == unreproducible
print(f"verify-edge-inventory: {len(entries)} routes, {captured} captured targets, {unreproducible} explicitly unreproducible targets; zero drift")
PY
