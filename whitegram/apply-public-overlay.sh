#!/usr/bin/env bash
set -euo pipefail

source_dir="${1:?source checkout path is required}"
public_dir="${2:?public checkout path is required}"
public_repo="https://github.com/WhiteGram/WhiteGram-iOS.git"
base_repo="https://github.com/TelegramMessenger/Telegram-iOS.git"
public_ref="db18308774f863074278feedc4df4507b0fb174e"
public_base="release-12.6.2"
patch_file="${RUNNER_TEMP:-/tmp}/whitegram-public-overlay.patch"

if [[ ! -d "$source_dir/.git" ]]; then
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

git -C "$public_dir" diff --binary "$public_base" "$public_ref" -- \
  '*.swift' 'BUILD' '*.bzl' '*.xcconfig' '*.plist' '*.json' '*.sh' '*.strings' \
  ':(exclude)versions.json' \
  ':(exclude)versions.json.backup' \
  ':(exclude)third-party/**' \
  ':(exclude)submodules/rlottie/**' \
  ':(exclude)submodules/TgVoipWebrtc/**' \
  ':(exclude)submodules/LottieCpp/**' \
  ':(exclude)**/*.xcassets/**' \
  ':(exclude)**/*.png' \
  ':(exclude)**/*.jpg' \
  ':(exclude)**/*.jpeg' \
  ':(exclude)**/*.gif' \
  ':(exclude)**/*.pdf' \
  > "$patch_file"

if [[ ! -s "$patch_file" ]]; then
  echo "Public overlay patch is empty" >&2
  exit 3
fi

echo "Applying WhiteGram public overlay $(git -C "$public_dir" rev-parse --short "$public_ref")"
git -C "$source_dir" remote remove whitegram-public >/dev/null 2>&1 || true
git -C "$source_dir" remote add whitegram-public "$public_repo"
git -C "$source_dir" fetch --no-tags --depth=1 "$public_repo" "$public_ref:refs/whitegram/public"
git -C "$source_dir" fetch --no-tags --depth=1 "$base_repo" "refs/tags/$public_base:refs/whitegram/base"

if ! git -C "$source_dir" apply --3way --whitespace=nowarn "$patch_file"; then
  echo "WhiteGram overlay has unresolved conflicts" >&2
  git -C "$source_dir" status --short >&2 || true
  git -C "$source_dir" diff --name-only --diff-filter=U >&2 || true
  exit 4
fi

echo "WhiteGram overlay applied"
git -C "$source_dir" status --short | sed -n '1,120p'
