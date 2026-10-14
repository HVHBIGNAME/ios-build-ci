"""Authenticated, bounded diagnostic inbox with private GitHub issue delivery."""

import argparse
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import threading
import time
import uuid

MAX_BODY = 65536
KINDS = {"crash", "hang", "http", "network", "runtime", "test"}
COMPONENTS = {"app", "services", "backend", "audio", "storage"}


class ReceiverServer(ThreadingHTTPServer):
    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(16)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


def validate_report(value):
    fields = {"schema", "id", "timestamp", "version", "build", "revision", "os", "kind", "component", "code", "frames"}
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError("Unexpected report fields")
    if type(value["schema"]) is not int or value["schema"] != 1:
        raise ValueError("Unsupported schema")
    if not isinstance(value["id"], str) or str(uuid.UUID(value["id"])).upper() != value["id"]:
        raise ValueError("Invalid report ID")
    if type(value["timestamp"]) is not int or not 0 <= value["timestamp"] <= 4102444800:
        raise ValueError("Invalid timestamp")
    for key in ("version", "build", "os"):
        if not isinstance(value[key], str) or not re.fullmatch(r"[0-9]{1,10}(\.[0-9]{1,10}){0,3}", value[key]):
            raise ValueError("Invalid version")
    if not isinstance(value["revision"], str) or not re.fullmatch(r"[a-f0-9]{40}|unknown", value["revision"]):
        raise ValueError("Invalid revision")
    if not isinstance(value["kind"], str) or not isinstance(value["component"], str) or value["kind"] not in KINDS or value["component"] not in COMPONENTS:
        raise ValueError("Invalid diagnostic category")
    if type(value["code"]) is not int or not -(2**63) <= value["code"] < 2**63:
        raise ValueError("Invalid diagnostic code")
    if not isinstance(value["frames"], list) or len(value["frames"]) > 64:
        raise ValueError("Too many frames")
    for frame in value["frames"]:
        if not isinstance(frame, dict) or set(frame) != {"binary", "uuid", "offset", "thread", "depth"}:
            raise ValueError("Unexpected frame fields")
        if not isinstance(frame["binary"], str) or not re.fullmatch(r"[A-Za-z0-9_.+-]{1,96}", frame["binary"]):
            raise ValueError("Invalid binary name")
        if not isinstance(frame["uuid"], str) or str(uuid.UUID(frame["uuid"])).upper() != frame["uuid"]:
            raise ValueError("Invalid binary UUID")
        for key, maximum in (("offset", 2**63 - 1), ("depth", 32), ("thread", 65535)):
            if type(frame[key]) is not int or not 0 <= frame[key] <= maximum:
                raise ValueError("Invalid frame number")
    return value


def fingerprint(report):
    group = {key: report[key] for key in ("revision", "kind", "component", "code")}
    group["frames"] = [{key: frame[key] for key in ("uuid", "offset")} for frame in report["frames"][:8]]
    return hashlib.sha256(json.dumps(group, sort_keys=True).encode()).hexdigest()[:24]


def github(arguments, payload=None):
    result = subprocess.run(["gh", *arguments], input=None if payload is None else json.dumps(payload),
                            capture_output=True, text=True, timeout=45, check=False)
    if result.returncode:
        raise RuntimeError("GitHub request failed")
    return json.loads(result.stdout) if result.stdout.strip() else None


def issue_body(report, group):
    frames = "\n".join(f"{f['thread']}:{f['depth']} {f['binary']} {f['uuid']} +0x{f['offset']:x}" for f in report["frames"])
    return (
        f"<!-- whitegram-diagnostic:{group} -->\n"
        f"Automatic {'synthetic pipeline check' if report['kind'] == 'test' else 'device diagnostic'}.\n\n"
        f"- Revision: `{report['revision']}`\n- App: `{report['version']} ({report['build']})`\n"
        f"- OS: `{report['os']}`\n- Component: `{report['component']}`\n"
        f"- Kind/code: `{report['kind']} / {report['code']}`\n- Received report: `{report['id']}`\n\n"
        f"### Binary-relative stack frames\n```text\n{frames or '(no stack supplied)'}\n```\n\n"
        "No message text, URLs, credentials, account identifiers or raw Telegram logs are collected. "
        "Repeated reports are grouped in the receiver database. Use the matching revision's debug-symbol artifact."
    )


class Inbox:
    def __init__(self, database, repository):
        self.repository = repository
        self.lock = threading.Lock()
        self.db = sqlite3.connect(database, check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS reports (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL,
                payload TEXT NOT NULL, received INTEGER NOT NULL, delivered INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS groups (fingerprint TEXT PRIMARY KEY, issue INTEGER NOT NULL);
        """)
        self.db.commit()

    def accept(self, report):
        with self.lock:
            existing = self.db.execute("SELECT payload FROM reports WHERE id=?", (report["id"],)).fetchone()
            if existing:
                if existing[0] != json.dumps(report, sort_keys=True):
                    raise ValueError("Report ID collision")
                return
            now = int(time.time())
            if self.db.execute("SELECT COUNT(*) FROM reports WHERE received>?", (now - 3600,)).fetchone()[0] >= 120:
                raise OverflowError("Rate limit")
            if self.db.execute("SELECT COUNT(*) FROM reports WHERE delivered=0").fetchone()[0] >= 1024:
                raise OverflowError("Inbox full")
            self.db.execute("DELETE FROM reports WHERE delivered=1 AND received<?", (now - 30 * 86400,))
            self.db.execute("INSERT INTO reports(id,fingerprint,payload,received) VALUES(?,?,?,?)",
                            (report["id"], fingerprint(report), json.dumps(report, sort_keys=True), now))
            self.db.commit()

    def deliver_one(self):
        with self.lock:
            row = self.db.execute("SELECT id,fingerprint,payload FROM reports WHERE delivered=0 ORDER BY received LIMIT 1").fetchone()
            if row is None:
                return False
            report_id, group, payload = row
            known = self.db.execute("SELECT issue FROM groups WHERE fingerprint=?", (group,)).fetchone()
        if known is None:
            report = json.loads(payload)
            title = f"[{report['kind']}] {report['component']} code {report['code']} · {group}"
            # Recover an issue if the receiver stopped after GitHub accepted it but before SQLite committed.
            issues = github(["api", f"repos/{self.repository}/issues?state=all&per_page=100"])
            issue = next((item for item in issues if item.get("title") == title), None)
            if issue is None:
                issue = github(["api", f"repos/{self.repository}/issues", "--method", "POST", "--input", "-"],
                               {"title": title, "body": issue_body(report, group)})
            with self.lock:
                self.db.execute("INSERT OR IGNORE INTO groups VALUES(?,?)", (group, issue["number"]))
                self.db.commit()
        with self.lock:
            self.db.execute("UPDATE reports SET delivered=1 WHERE id=?", (report_id,))
            self.db.commit()
        return True

    def worker(self):
        while True:
            try:
                if not self.deliver_one():
                    time.sleep(2)
            except (RuntimeError, OSError, subprocess.TimeoutExpired, ValueError):
                print("Diagnostic issue delivery delayed; retrying.", flush=True)
                time.sleep(30)


def handler(inbox, upload_key, instance_id):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def setup(self):
            super().setup()
            self.connection.settimeout(10)

        def log_message(self, *_):
            pass

        def reply(self, status, value):
            body = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True

        def do_GET(self):
            self.reply(200 if self.path == "/health" else 404, {"service": "whitegram-diagnostics", "instance": instance_id})

        def do_POST(self):
            if self.path != "/v1/reports":
                self.reply(404, {"accepted": False}); return
            if not hmac.compare_digest(self.headers.get("Authorization", "").encode("utf-8"), ("Bearer " + upload_key).encode("utf-8")):
                self.reply(401, {"accepted": False}); return
            if self.headers.get("Transfer-Encoding") or self.headers.get_content_type() != "application/json":
                self.reply(400, {"accepted": False}); return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= MAX_BODY:
                    self.reply(413, {"accepted": False}); return
                data = self.rfile.read(length)
                if len(data) != length:
                    raise ValueError("Short body")
                report = validate_report(json.loads(data))
                inbox.accept(report)
            except OverflowError:
                self.reply(429, {"accepted": False}); return
            except (ValueError, TypeError, KeyError):
                self.reply(400, {"accepted": False}); return
            except sqlite3.Error:
                self.reply(503, {"accepted": False}); return
            self.reply(202, {"accepted": True, "id": report["id"]})
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(args.config.read_text(encoding="utf-8"))
    repository = config["repository"]
    if not github(["api", f"repos/{repository}"])["private"]:
        raise SystemExit("Diagnostics require a private repository")
    inbox = Inbox(args.config.parent / "inbox.sqlite3", repository)
    server = ReceiverServer(("127.0.0.1", config["port"]), handler(inbox, config["upload_key"], config["instance"]))
    threading.Thread(target=inbox.worker, daemon=True).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
