#!/usr/bin/env python3
"""Small, dependency-free JSON helper for Dependencies/CoreDependency.lock.json.

Bash scripts shell out to this instead of hand-rolling JSON parsing so that
nested fields, string escaping, and validation stay correct. Not a general
purpose tool; only supports what scripts/*.sh need.

Usage:
    python3 lock.py get <dotted.path> --lock <file> [--default X]
    python3 lock.py set <dotted.path> <value> --lock <file> [--type str|int|bool|json|null]
    python3 lock.py validate --lock <file> --schema <file> [--allow-placeholder]
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import sys
from pathlib import Path
from typing import Any


def _load(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def _dump(path: Path, data: dict) -> None:
    with path.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")


def _get_path(data: dict, dotted: str) -> Any:
    node: Any = data
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            raise KeyError(dotted)
        node = node[part]
    return node


def _set_path(data: dict, dotted: str, value: Any) -> None:
    parts = dotted.split(".")
    node = data
    for part in parts[:-1]:
        if part not in node or not isinstance(node[part], dict):
            node[part] = {}
        node = node[part]
    node[parts[-1]] = value


def cmd_get(args: argparse.Namespace) -> int:
    data = _load(Path(args.lock))
    try:
        value = _get_path(data, args.path)
    except KeyError:
        if args.default is not None:
            print(args.default)
            return 0
        return 1
    if isinstance(value, bool):
        print("true" if value else "false")
    elif isinstance(value, (dict, list)):
        print(json.dumps(value))
    elif value is None:
        print("")
    else:
        print(value)
    return 0


def _coerce(raw: str, type_name: str) -> Any:
    if type_name == "str":
        return raw
    if type_name == "int":
        return int(raw)
    if type_name == "bool":
        return raw.strip().lower() in ("1", "true", "yes", "on")
    if type_name == "json":
        return json.loads(raw)
    if type_name == "null":
        return None
    raise ValueError(f"unknown --type {type_name}")


def cmd_set(args: argparse.Namespace) -> int:
    lock_path = Path(args.lock)
    data = _load(lock_path)
    value = _coerce(args.value, args.type)
    _set_path(data, args.path, value)
    if args.touch_metadata:
        data["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        data["updatedBy"] = args.updated_by
    _dump(lock_path, data)
    return 0


_SEMVERISH = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+([ab][0-9]+|rc[0-9]+)?$")
_SHA_OR_PLACEHOLDER = re.compile(r"^([0-9a-f]{40}|PENDING-run-scripts/update-core\.sh)$")


def cmd_validate(args: argparse.Namespace) -> int:
    lock_path = Path(args.lock)
    errors: list[str] = []
    warnings: list[str] = []

    try:
        data = _load(lock_path)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: could not parse {lock_path}: {exc}", file=sys.stderr)
        return 1

    required_top = [
        "repository",
        "tag",
        "commitSha",
        "pythonPackageVersion",
        "bridgeProtocolVersion",
        "helperBuildVersion",
        "helper",
        "localOverride",
    ]
    for key in required_top:
        if key not in data:
            errors.append(f"missing required key: {key}")

    if errors:
        for e in errors:
            print(f"ERROR: {e}", file=sys.stderr)
        return 1

    repo = data.get("repository", "")
    if not isinstance(repo, str) or not repo.startswith("https://"):
        errors.append(f"repository must be an https:// URL, got: {repo!r}")

    sha = data.get("commitSha", "")
    if not isinstance(sha, str) or not _SHA_OR_PLACEHOLDER.match(sha):
        errors.append(
            f"commitSha must be a 40-char hex sha or the pending placeholder, got: {sha!r}"
        )
    elif sha.startswith("PENDING"):
        warnings.append(
            "commitSha is still the placeholder — run scripts/update-core.sh to pin a real revision "
            "before cutting a release."
        )

    pkg_ver = data.get("pythonPackageVersion", "")
    if not isinstance(pkg_ver, str) or not _SEMVERISH.match(pkg_ver):
        errors.append(f"pythonPackageVersion doesn't look like a version: {pkg_ver!r}")

    bpv = data.get("bridgeProtocolVersion")
    if not isinstance(bpv, int) or bpv < 1:
        errors.append(f"bridgeProtocolVersion must be a positive integer, got: {bpv!r}")

    hbv = data.get("helperBuildVersion")
    if not isinstance(hbv, int) or hbv < 0:
        errors.append(f"helperBuildVersion must be a non-negative integer, got: {hbv!r}")

    helper = data.get("helper", {})
    if not isinstance(helper, dict) or not helper.get("binaryName"):
        errors.append("helper.binaryName is required")
    if not isinstance(helper.get("entryPointCandidates"), list) or not helper.get(
        "entryPointCandidates"
    ):
        errors.append("helper.entryPointCandidates must be a non-empty list")

    override = data.get("localOverride", {})
    if not isinstance(override, dict) or "enabled" not in override or "path" not in override:
        errors.append("localOverride must have 'enabled' and 'path'")
    elif override.get("enabled") and not override.get("path"):
        errors.append("localOverride.enabled is true but localOverride.path is empty")

    for w in warnings:
        print(f"WARNING: {w}", file=sys.stderr)

    if errors:
        for e in errors:
            print(f"ERROR: {e}", file=sys.stderr)
        return 1

    print("OK: Dependencies/CoreDependency.lock.json is well-formed.")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_get = sub.add_parser("get")
    p_get.add_argument("path")
    p_get.add_argument("--lock", required=True)
    p_get.add_argument("--default", default=None)
    p_get.set_defaults(func=cmd_get)

    p_set = sub.add_parser("set")
    p_set.add_argument("path")
    p_set.add_argument("value")
    p_set.add_argument("--lock", required=True)
    p_set.add_argument("--type", default="str", choices=["str", "int", "bool", "json", "null"])
    p_set.add_argument("--touch-metadata", action="store_true")
    p_set.add_argument("--updated-by", default="scripts/update-core.sh")
    p_set.set_defaults(func=cmd_set)

    p_val = sub.add_parser("validate")
    p_val.add_argument("--lock", required=True)
    p_val.add_argument("--schema", required=False)
    p_val.add_argument("--allow-placeholder", action="store_true")
    p_val.set_defaults(func=cmd_validate)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
