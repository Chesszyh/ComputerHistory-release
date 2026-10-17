#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
if [[ -f "$bin_dir/ComputerHistoryCore.o" ]]; then
    modules="$bin_dir"
    objects=("$bin_dir/ComputerHistoryCore.o")
else
    modules="$bin_dir/Modules"
    objects=("$bin_dir/ComputerHistoryCore.build/"*.o)
fi
swiftc -parse-as-library -I "$modules" \
    Sources/computer-history-menubar/StatusModel.swift \
    Sources/computer-history-menubar/StatusPanel.swift \
    Sources/computer-history-menubar/SettingsPane.swift \
    "${1:-scripts/test-menubar-panel.swift}" "${objects[@]}" -o "$test_dir/panel-test"
"$test_dir/panel-test"
