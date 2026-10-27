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
bin_dir="${COMPUTER_HISTORY_BIN_DIR:-$(swift build -c release --show-bin-path)}"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
name="ComputerHistory-v${version}-macos-${arch}"
mkdir -p "$stage/$name" dist
for executable in computer-history computer-history-menubar; do
    cp "$bin_dir/$executable" "$stage/$name/$executable"
    strip -S "$stage/$name/$executable"
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        case "$executable" in
            computer-history) suffix=cli;;
            computer-history-menubar) suffix=menubar;;
            computer-history-credentials) suffix=credentials;;
        esac
        codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp --identifier "xyz.chesszyh.computer-history.$suffix" "$stage/$name/$executable"
    elif command -v local-codesign >/dev/null 2>&1; then
        local-codesign "$stage/$name/$executable"
    else
        codesign --force --sign - "$stage/$name/$executable"
    fi
    codesign --verify "$stage/$name/$executable"
done
python3 scripts/bundle-app.py --bin-dir "$bin_dir" --output "$stage/$name/ComputerHistory.app"
cp "$stage/$name/ComputerHistory.app/Contents/MacOS/computer-history-credentials" "$stage/$name/computer-history-credentials"
cp scripts/manage-install.py "$stage/$name/manage-install.py"
cp LICENSE "$stage/$name/LICENSE"
cp docs/distribution.md "$stage/$name/README.md"
"$stage/$name/computer-history" --help >/dev/null
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    ditto -c -k --keepParent "$stage/$name/ComputerHistory.app" "$stage/notarize.zip"
    xcrun notarytool submit "$stage/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$stage/$name/ComputerHistory.app"
fi
COPYFILE_DISABLE=1 tar -czf "dist/$name.tar.gz" -C "$stage" "$name"
printf 'Created dist/%s.tar.gz\n' "$name"
