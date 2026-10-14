"""Send one synthetic report through the configured public HTTPS intake and find its issue."""

import argparse
import json
from pathlib import Path
import subprocess
import time
import urllib.request
import uuid

from receiver import fingerprint


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-directory", required=True, type=Path)
    args = parser.parse_args()
    config = json.loads((args.state_directory / "config.json").read_text(encoding="utf-8"))
    runtime = json.loads((args.state_directory / "runtime.json").read_text(encoding="utf-8"))
    report = {"schema": 1, "id": str(uuid.uuid4()).upper(), "timestamp": int(time.time()), "version": "0", "build": "0",
              "revision": "unknown", "os": "0", "kind": "test", "component": "app", "code": 0, "frames": []}
    request = urllib.request.Request(runtime["endpoint"], data=json.dumps(report).encode(),
                                     headers={"Content-Type": "application/json", "Authorization": "Bearer " + config["upload_key"]})
    for _ in range(2):
        with urllib.request.urlopen(request, timeout=20) as response:
            if json.load(response) != {"accepted": True, "id": report["id"]}:
                raise RuntimeError("Invalid diagnostic acknowledgment")
    group = fingerprint(report)
    for _ in range(20):
        result = subprocess.run(["gh", "api", f"repos/{config['repository']}/issues?state=all&per_page=100"], capture_output=True, text=True, check=True)
        matches = [item for item in json.loads(result.stdout) if item["title"].endswith(group)]
        if matches:
            if len(matches) != 1:
                raise RuntimeError("Duplicate diagnostic issues")
            print(json.dumps({"accepted_twice": True, "issues_created": 1, "issue": matches[0]["html_url"]}))
            return
        time.sleep(2)
    raise RuntimeError("Report accepted locally, but GitHub delivery did not complete")


if __name__ == "__main__":
    main()
