"""Start a temporary local receiver/tunnel and configure the build's intake secrets."""

import argparse
import json
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid


def public_health(url):
    # Windows' Python TLS/network path can stall on IPv6; curl bounds the IPv4 probe.
    result = subprocess.run(["curl.exe" if sys.platform == "win32" else "curl", "--ipv4", "--silent", "--fail", "--max-time", "8", url],
                            capture_output=True, text=True, timeout=10, check=False)
    if result.returncode:
        return None
    try:
        return json.loads(result.stdout)
    except ValueError:
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-root", type=Path, required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--build-repository", required=True)
    parser.add_argument("--port", type=int, default=8767)
    parser.add_argument("--provider", choices=("cloudflare", "tailscale"), default="cloudflare")
    args = parser.parse_args()
    if not args.state_root.is_dir():
        parser.error("state-root must exist")
    cloudflared = shutil.which("cloudflared")
    if args.provider == "cloudflare" and cloudflared is None:
        parser.error("cloudflared is required")
    directory = args.state_root / ("whitegram-diagnostics-" + time.strftime("%Y%m%d-%H%M%S"))
    directory.mkdir()
    config = {"repository": args.repository, "port": args.port, "upload_key": secrets.token_hex(32), "instance": str(uuid.uuid4())}
    config_path = directory / "config.json"
    config_path.write_text(json.dumps(config), encoding="utf-8")
    flags = (subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP) if sys.platform == "win32" else 0
    with (directory / "receiver.log").open("wb") as log:
        receiver = subprocess.Popen([sys.executable, "-B", str(Path(__file__).with_name("receiver.py")), "--config", str(config_path)],
                                    stdin=subprocess.DEVNULL, stdout=log, stderr=log, creationflags=flags)
    tunnel = None
    funnel_started = False
    try:
        for attempt in range(20):
            if receiver.poll() is not None:
                raise RuntimeError("Receiver stopped; inspect receiver.log")
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{args.port}/health", timeout=2) as response:
                    if json.load(response).get("instance") != config["instance"]:
                        raise RuntimeError("Port belongs to a different receiver")
                break
            except urllib.error.URLError:
                if attempt == 19:
                    raise RuntimeError("Receiver failed to start") from None
                time.sleep(1)
        endpoint = None
        if args.provider == "tailscale":
            existing = subprocess.run(["tailscale", "funnel", "status", "--json"], capture_output=True, text=True, check=True)
            if json.loads(existing.stdout or "{}"):
                raise RuntimeError("Existing Tailscale serve configuration requires review")
            state = json.loads(subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, check=True).stdout)
            host = state["Self"]["DNSName"].rstrip(".")
            subprocess.run(["tailscale", "funnel", "--bg", "--https=8443", "--yes", f"http://127.0.0.1:{args.port}"], check=True, timeout=40)
            funnel_started = True
            endpoint = "https://" + host + ":8443/v1/reports"
        else:
            with (directory / "tunnel.log").open("wb") as log:
                tunnel = subprocess.Popen([cloudflared, "tunnel", "--no-autoupdate", "--protocol", "quic", "--url", f"http://127.0.0.1:{args.port}"],
                                          stdin=subprocess.DEVNULL, stdout=log, stderr=log, creationflags=flags)
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if tunnel is not None:
                if tunnel.poll() is not None:
                    raise RuntimeError("Tunnel stopped; inspect tunnel.log")
                text = (directory / "tunnel.log").read_text(encoding="utf-8", errors="replace")
                match = re.search(r"https://[a-z0-9-]+\.trycloudflare\.com", text)
                if match:
                    endpoint = match[0] + "/v1/reports"
            if endpoint:
                response = public_health(endpoint.removesuffix("/v1/reports") + "/health")
                if response is not None and response.get("instance") == config["instance"]:
                    break
            time.sleep(2)
        else:
            raise RuntimeError("Public tunnel health check failed")
        for name, value in (("WHITEGRAM_DIAGNOSTICS_URL", endpoint), ("WHITEGRAM_DIAGNOSTICS_UPLOAD_KEY", config["upload_key"])):
            subprocess.run(["gh", "secret", "set", name, "--repo", args.build_repository], input=value, text=True, check=True, capture_output=True)
        runtime = {"endpoint": endpoint, "repository": args.repository, "receiver_pid": receiver.pid, "tunnel_pid": tunnel.pid if tunnel else None, "provider": args.provider}
        (directory / "runtime.json").write_text(json.dumps(runtime, indent=2), encoding="utf-8")
        print(json.dumps({**runtime, "state_directory": str(directory)}, indent=2))
    except BaseException:
        receiver.terminate()
        if tunnel is not None:
            tunnel.terminate()
        if funnel_started:
            subprocess.run(["tailscale", "funnel", "--https=8443", "off"], check=False)
        raise


if __name__ == "__main__":
    main()
