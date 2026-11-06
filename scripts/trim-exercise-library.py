#!/usr/bin/env python3
"""Trim the Free Exercise DB dataset to the metadata Loopr bundles.

Usage:
  python3 -I scripts/trim-exercise-library.py SOURCE_JSON EXPECTED_SHA256 OUTPUT_JSON \
      [--provenance PROVENANCE_JSON --source-url URL --commit SHA --generated YYYY-MM-DD]

The source file is untrusted data. The script only parses it as JSON, checks
its SHA-256 against the expected value, validates every kept field, drops
instructions and images, and writes sorted, deterministic JSON. The same
input always produces the same bytes.
"""
import argparse
import hashlib
import json
import re
import sys
from datetime import date

KEPT_REQUIRED = ("id", "name", "category", "primaryMuscles", "secondaryMuscles")
KEPT_OPTIONAL = ("equipment", "level", "force", "mechanic")
ID_PATTERN = re.compile(r"^[A-Za-z0-9_\-]{1,120}$")
MAX_NAME = 80
MAX_TOKEN = 40
MAX_MUSCLES = 12


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fail(message: str):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def clean_text(value, label: str, limit: int) -> str:
    if not isinstance(value, str):
        fail(f"{label} must be a string")
    if value != value.strip() or not value or len(value) > limit:
        fail(f"{label} must be non-empty, trimmed and at most {limit} characters")
    return value


def clean_muscles(value, label: str) -> list:
    if not isinstance(value, list) or len(value) > MAX_MUSCLES:
        fail(f"{label} must be a list of at most {MAX_MUSCLES} strings")
    cleaned = [clean_text(item, f"{label} item", MAX_TOKEN) for item in value]
    if len(set(cleaned)) != len(cleaned):
        fail(f"{label} has duplicates")
    return cleaned


def trim_entry(entry, index: int) -> dict:
    if not isinstance(entry, dict):
        fail(f"entry {index} is not an object")
    for key in KEPT_REQUIRED:
        if key not in entry:
            fail(f"entry {index} is missing {key}")
    identifier = entry["id"]
    if not isinstance(identifier, str) or not ID_PATTERN.match(identifier):
        fail(f"entry {index} has an invalid id")
    out = {
        "id": identifier,
        "name": clean_text(entry["name"], f"{identifier} name", MAX_NAME),
        "category": clean_text(entry["category"], f"{identifier} category", MAX_TOKEN),
        "primaryMuscles": clean_muscles(entry["primaryMuscles"], f"{identifier} primaryMuscles"),
        "secondaryMuscles": clean_muscles(entry["secondaryMuscles"], f"{identifier} secondaryMuscles"),
    }
    for key in KEPT_OPTIONAL:
        value = entry.get(key)
        if value is not None:
            out[key] = clean_text(value, f"{identifier} {key}", MAX_TOKEN)
    for key in ("instructions", "images"):
        if key in entry and not isinstance(entry[key], list):
            fail(f"{identifier} {key} must be a list")
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("expected_sha256")
    parser.add_argument("output")
    parser.add_argument("--provenance")
    parser.add_argument("--source-url")
    parser.add_argument("--commit")
    parser.add_argument("--generated", default=date.today().isoformat())
    args = parser.parse_args()

    with open(args.source, "rb") as handle:
        raw = handle.read()
    actual = sha256(raw)
    if actual != args.expected_sha256.lower():
        fail(f"source SHA-256 is {actual}, expected {args.expected_sha256}")
    try:
        entries = json.loads(raw)
    except ValueError as error:
        fail(f"source is not valid JSON: {error}")
    if not isinstance(entries, list) or not entries:
        fail("source must be a non-empty array")

    trimmed = [trim_entry(entry, index) for index, entry in enumerate(entries)]
    ids = [entry["id"] for entry in trimmed]
    if len(set(ids)) != len(ids):
        fail("duplicate ids")
    if len({identifier.lower() for identifier in ids}) != len(ids):
        fail("ids collide when compared without case")
    trimmed.sort(key=lambda entry: entry["id"])

    output = (json.dumps(trimmed, ensure_ascii=False, sort_keys=True, indent=1) + "\n").encode("utf-8")
    with open(args.output, "wb") as handle:
        handle.write(output)

    if args.provenance:
        if not args.source_url or not args.commit:
            fail("--provenance needs --source-url and --commit")
        provenance = {
            "commit": args.commit,
            "count": len(trimmed),
            "generated": args.generated,
            "keptFields": sorted(["id", "name", "category", *KEPT_OPTIONAL, "primaryMuscles", "secondaryMuscles"]),
            "licence": "The Unlicense",
            "outputFile": "exercises.v1.json",
            "outputSha256": sha256(output),
            "script": "scripts/trim-exercise-library.py",
            "sourceSha256": actual,
            "sourceUrl": args.source_url,
        }
        with open(args.provenance, "wb") as handle:
            handle.write((json.dumps(provenance, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8"))
    print(f"wrote {len(trimmed)} exercises, {len(output)} bytes, sha256 {sha256(output)}")


if __name__ == "__main__":
    main()
