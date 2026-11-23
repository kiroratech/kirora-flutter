#!/usr/bin/env bash
# Copies the Kirora iOS SDK's sources into ios/Kirora, where the CocoaPods build compiles them
# into this plugin (Kirora isn't on CocoaPods trunk, which is read-only from December 2026).
# Swift Package Manager builds don't use this copy: Package.swift depends on kirora-ios itself.
#
#   tool/sync_kirora_ios.sh 0.2.0                # a kirora-ios release tag
#   tool/sync_kirora_ios.sh /path/to/kirora-ios  # a local checkout, as it is
#
# With a tag, also set the same exact version in ios/kirora_flutter/Package.swift; a test checks
# the two agree.
set -euo pipefail

source="${1:?usage: tool/sync_kirora_ios.sh <kirora-ios tag or checkout path>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
target="$root/ios/Kirora"

if [ -d "$source" ]; then
  checkout="$(cd "$source" && pwd)"
else
  checkout="$(mktemp -d)"
  trap 'rm -rf "$checkout"' EXIT
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$source" https://github.com/kiroratech/kirora-ios.git "$checkout"
fi

rm -rf "$target"
mkdir -p "$target/Sources"
cp -R "$checkout/Sources/Kirora" "$target/Sources/Kirora"
cp "$checkout/LICENSE" "$target/LICENSE"
echo "ios/Kirora now holds kirora-ios $(sed -n 's/^let sdkVersion = "\(.*\)"/\1/p' "$target/Sources/Kirora/Internal/Support.swift")"
