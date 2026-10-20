#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_source="${1:-scripts/test-menubar-panel.swift}"
test_source="${test_source#"$PWD"/}"
case "$test_source" in
    scripts/test-menubar-panel.swift|scripts/test-menubar-usage.swift|scripts/test-menubar-settings.swift|scripts/test-menubar-catalog.swift|scripts/test-menubar-reports.swift)
        python3 scripts/build-menubar-tests.py
        test_name="$test_source"
        test_name="${test_name##*/test-menubar-}"
        exec .build/native-tests/panel-test "${test_name%.swift}" "${@:2}"
        ;;
esac
bash scripts/build.sh -c release
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
    Sources/computer-history-menubar/ReportsPane.swift \
    scripts/test-menubar-input.swift \
    "${1:-scripts/test-menubar-panel.swift}" "${objects[@]}" -o "$test_dir/panel-test"
if command -v local-codesign >/dev/null 2>&1; then
    local-codesign --identifier xyz.chesszyh.computer-history.panel-test "$test_dir/panel-test"
fi
"$test_dir/panel-test" "${@:2}"
