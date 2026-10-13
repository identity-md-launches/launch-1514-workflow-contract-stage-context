#!/usr/bin/env python3
"""Export the two launch ABIs from the pinned Foundry build, or check tracked exports."""

import argparse
import json
import pathlib
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if an exported ABI is missing or stale")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    stale = False
    for name in ("LaunchToken", "JobZero"):
        result = subprocess.run(
            ["forge", "inspect", f"src/{name}.sol:{name}", "abi", "--json"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        abi = json.loads(result.stdout)
        if not isinstance(abi, list) or not abi:
            raise ValueError(f"Invalid ABI for {name}")
        formatted = json.dumps(abi, indent=2) + "\n"
        path = root / "docs" / "abi" / f"{name}.json"
        if args.check:
            if not path.exists() or path.read_text() != formatted:
                print(f"Stale or missing ABI: {path.relative_to(root)}", file=sys.stderr)
                stale = True
            else:
                print(f"ABI matches: {path.relative_to(root)}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(formatted)
            print(f"Exported: {path.relative_to(root)}")
    return int(stale)


if __name__ == "__main__":
    sys.exit(main())
