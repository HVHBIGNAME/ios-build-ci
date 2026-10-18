"""Check official stable Telegram iOS tags and optionally notify through one GitHub issue."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess

OFFICIAL_REPOSITORY = "TelegramMessenger/Telegram-iOS"


def version(tag):
    match = re.fullmatch(r"release-(\d+)\.(\d+)(?:\.(\d+))?", tag)
    return tuple(int(part or 0) for part in match.groups()) if match else None


def gh_json(*args):
    return json.loads(subprocess.check_output(["gh", *args], text=True, encoding="utf-8"))


def compare_tags(config, tags):
    if config.get("repository") != OFFICIAL_REPOSITORY or version(config.get("source_tag", "")) is None:
        raise ValueError("Expected an official stable Telegram source pin")
    if not re.fullmatch(r"[0-9a-f]{40}", config.get("source_sha", "")):
        raise ValueError("Invalid pinned source SHA")
    releases = {}
    for tag in tags:
        name = tag.get("name", "")
        if version(name) is None:
            continue
        sha = tag.get("commit", {}).get("sha", "")
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise ValueError(f"Invalid official tag SHA: {name}")
        if name in releases and releases[name] != sha:
            raise ValueError(f"Inconsistent official tag SHA: {name}")
        releases[name] = sha
    if not releases:
        raise ValueError("Official repository returned no stable release tags")
    pin = config["source_tag"]
    if pin not in releases:
        raise ValueError(f"Pinned official tag disappeared: {pin}")
    latest = max(releases, key=lambda tag: (version(tag), tag))
    moved = releases[pin] != config["source_sha"]
    newer = version(latest) > version(pin)
    return {"repository": OFFICIAL_REPOSITORY, "source_tag": pin, "source_sha": config["source_sha"],
            "latest_tag": latest, "latest_sha": releases[latest], "pinned_tag_moved": moved,
            "update_available": newer, "attention_required": newer or moved,
            "compare_url": f"https://github.com/{OFFICIAL_REPOSITORY}/compare/{config['source_sha']}...{releases[latest]}"}


def notify(report, repository):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid notification repository")
    title = "[Telegram upstream] " + ("Changed pin " + report["source_tag"] if report["pinned_tag_moved"] else report["latest_tag"])
    issues = gh_json("issue", "list", "--repo", repository, "--state", "all", "--search", title + " in:title", "--limit", "100", "--json", "title,url")
    for issue in issues:
        if issue["title"] == title:
            return issue["url"]
    body = (f"Official Telegram iOS source update detected.\n\n"
            f"- Current source target: `{report['source_tag']}` / `{report['source_sha']}`\n"
            f"- Latest stable tag: `{report['latest_tag']}` / `{report['latest_sha']}`\n"
            f"- Pinned tag changed: `{report['pinned_tag_moved']}`\n"
            f"- [Upstream changes]({report['compare_url']})\n\n"
            "Upgrade the source pin and toolchain, adapt Whitegram patches, then pass native tests, IPA verification and simulator launches. "
            "Changing application version metadata alone does not update the Telegram implementation.\n")
    return subprocess.check_output(["gh", "issue", "create", "--repo", repository, "--title", title, "--body", body], text=True, encoding="utf-8").strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path(__file__).with_name("upstream.json"))
    parser.add_argument("--notify", action="store_true")
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if args.notify and not args.repository:
        parser.error("--notify requires --repository or GITHUB_REPOSITORY")
    pages = gh_json("api", "--paginate", "--slurp", f"repos/{OFFICIAL_REPOSITORY}/tags?per_page=100")
    report = compare_tags(json.loads(args.config.read_text(encoding="utf-8")), [tag for page in pages for tag in page])
    report["issue"] = notify(report, args.repository) if args.notify and report["attention_required"] else None
    output = json.dumps(report, indent=2) + "\n"
    if args.report:
        args.report.write_text(output, encoding="utf-8")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with Path(summary).open("a", encoding="utf-8") as stream:
            stream.write("## Official Telegram iOS check\n\n```json\n" + output + "```\n")
    print(output, end="")


if __name__ == "__main__":
    main()
