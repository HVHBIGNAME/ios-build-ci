#!/usr/bin/env bash
set -euo pipefail

source_dir="${1:?source checkout path is required}"
public_dir="${2:?public checkout path is required}"
public_repo="https://github.com/WhiteGram/WhiteGram-iOS.git"
base_repo="https://github.com/TelegramMessenger/Telegram-iOS.git"
public_ref="db18308774f863074278feedc4df4507b0fb174e"
public_base="release-12.6.2"
report_dir="${RUNNER_TEMP:-/tmp}/whitegram-port-report"

if ! git -C "$source_dir" rev-parse --git-dir >/dev/null; then
  echo "Not a git checkout: $source_dir" >&2
  exit 2
fi

mkdir -p "$(dirname "$public_dir")"
if [[ ! -d "$public_dir/.git" ]]; then
  git clone --filter=blob:none --no-checkout --depth=1 --branch master "$public_repo" "$public_dir"
fi

git -C "$public_dir" fetch --depth=1 origin "$public_ref"
git -C "$public_dir" checkout --detach "$public_ref"
git -C "$public_dir" fetch --depth=1 "$base_repo" "refs/tags/$public_base:refs/tags/$public_base"

echo "Applying WhiteGram public overlay $(git -C "$public_dir" rev-parse --short "$public_ref")"
python3 "$(dirname "$0")/port_public.py" "$source_dir" "$public_dir" \
  --report "$report_dir/report.json" --apply
