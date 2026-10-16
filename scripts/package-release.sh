#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(cat VERSION)"
arch="$(uname -m)"
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
name="ComputerHistory-v${version}-macos-${arch}"
mkdir -p "$stage/$name" dist
for executable in computer-history computer-history-menubar; do
    cp "$bin_dir/$executable" "$stage/$name/$executable"
    strip -S "$stage/$name/$executable"
    codesign --force --sign - "$stage/$name/$executable"
    codesign --verify "$stage/$name/$executable"
done
cp LICENSE "$stage/$name/LICENSE"
cp docs/distribution.md "$stage/$name/README.md"
"$stage/$name/computer-history" --help >/dev/null
COPYFILE_DISABLE=1 tar -czf "dist/$name.tar.gz" -C "$stage" "$name"
printf 'Created dist/%s.tar.gz\n' "$name"
