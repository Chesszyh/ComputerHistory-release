#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(cat VERSION)"
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "只构建 Apple Silicon（arm64）包。" >&2
    exit 1
fi
arch="arm64"
case "${1:-}" in
    "") bash scripts/build.sh -c release ;;
    --skip-build) ;;
    *) echo "Usage: $0 [--skip-build]" >&2; exit 2 ;;
esac
bin_dir="$(swift build -c release --show-bin-path)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
name="ComputerHistory-v${version}-macos-${arch}"
mkdir -p "$stage/$name" dist
for executable in computer-history computer-history-menubar; do
    cp "$bin_dir/$executable" "$stage/$name/$executable"
    strip -S "$stage/$name/$executable"
    if command -v local-codesign >/dev/null 2>&1; then
        local-codesign "$stage/$name/$executable"
    else
        codesign --force --sign - "$stage/$name/$executable"
    fi
    codesign --verify "$stage/$name/$executable"
done
cp LICENSE "$stage/$name/LICENSE"
cp docs/distribution.md "$stage/$name/README.md"
"$stage/$name/computer-history" --help >/dev/null
COPYFILE_DISABLE=1 tar -czf "dist/$name.tar.gz" -C "$stage" "$name"
printf 'Created dist/%s.tar.gz\n' "$name"
