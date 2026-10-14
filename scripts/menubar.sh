#!/bin/bash
# 启动菜单栏应用。与采集器一样脱离终端会话——它是常驻的 GUI，
# 不应随启动它的终端一起退出。
#
# 用法：
#   ./scripts/menubar.sh          启动（已在运行则提示）
#   ./scripts/menubar.sh --stop   停止

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${COMPUTER_HISTORY_MENUBAR_BIN:-${ROOT}/.build/release/computer-history-menubar}"
if [[ ! -x "${BIN}" ]]; then
    echo "找不到可执行文件：${BIN}" >&2
    echo "先构建：swift build -c release" >&2
    exit 1
fi

if [[ "${1:-}" == "--stop" ]]; then
    exec "${BIN}" --stop
fi

python3 - "$BIN" <<'PYTHON'
import subprocess, sys
process = subprocess.Popen([sys.argv[1]], stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           start_new_session=True)
try:
    code = process.wait(timeout=1)
except subprocess.TimeoutExpired:
    print(f"菜单栏应用已启动（pid {process.pid}）。")
else:
    print("菜单栏应用已在运行。" if code == 0 else "菜单栏启动失败，请直接运行二进制查看错误。")
    sys.exit(code)
PYTHON
