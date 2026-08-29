#!/usr/bin/env python3
"""FE meter post-processor for free-scan.sh results.

Adds an `fe_reading` field to each PASSING model in the results JSON by running
the 1 FE gauge against their endpoint. Uses the same OpenAI-compatible wiring
as free-scan.sh, so keyless endpoints are probed without authentication.

Usage (called from free-scan.sh):
    python3 fe-postprocess.py <results.json> <fe-meter.py>
"""
import json
import sys
import subprocess
from pathlib import Path
from typing import Any


def run_fe_meter(model_id: str, base_url: str) -> dict | None:
    """Run fe_meter.py against a single model and return its reading.

    Returns None if the meter fails (infra errors are treated as BELOW_FE-reachable).
    """
    meter_path = Path(__file__).parent.parent / "independent-research" / "fe_meter.py"
    import tempfile
    import os

    try:
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            out_file = f.name

        result = subprocess.run(
            [sys.executable, str(meter_path),
             "--model", model_id,
             "--host", base_url,
             "--runs", "1",  # Single run for roster integration (speed vs precision)
             "--lengths", "2000",  # Short test for fast scanning
             "--out", out_file],
            capture_output=True, text=True, timeout=120, check=True
        )

        with open(out_file) as f:
            reading = json.load(f)

        os.unlink(out_file)
        return reading.get("reading", {"verdict": "ERROR"})

    except (subprocess.TimeoutExpired, subprocess.CalledProcessError, json.JSONDecodeError, FileNotFoundError) as e:
        if 'out_file' in locals() and os.path.exists(out_file):
            os.unlink(out_file)
        return {"verdict": f"ERROR:{type(e).__name__}"}


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: fe-postprocess.py <results.json>", file=sys.stderr)
        return 1

    results_path = sys.argv[1]
    with open(results_path) as f:
        data = json.load(f)

    passing_ids = set(data.get("passing", []))
    results = data.get("results", [])

    print(f"[FE post-process] adding readings to {len(passing_ids)} PASSING models...", flush=True)

    for i, result in enumerate(results):
        model_id = result.get("id", "")
        if model_id not in passing_ids:
            continue

        base_url = result.get("base_url", "")
        if not base_url:
            continue

        print(f"  [{i+1}/{len(results)}] {model_id} @ {base_url}", flush=True)
        reading = run_fe_meter(model_id, base_url)
        result["fe_reading"] = reading

    # Write back
    with open(results_path, "w") as f:
        json.dump(data, f, indent=2)

    print(f"[FE post-process] updated {results_path}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
