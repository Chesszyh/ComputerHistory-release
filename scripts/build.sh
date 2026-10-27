#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build "$@"
for argument in "$@"; do
    case "$argument" in --show-bin-path|--help|-h|--version) exit 0;; esac
done
bin_dir="$(swift build "$@" --show-bin-path)"
if command -v local-codesign >/dev/null 2>&1; then
    local-codesign --identifier xyz.chesszyh.computer-history.credentials "$bin_dir/computer-history-credentials"
    local-codesign --identifier xyz.chesszyh.computer-history.cli "$bin_dir/computer-history"
    local-codesign --identifier xyz.chesszyh.computer-history.menubar "$bin_dir/computer-history-menubar"
fi
