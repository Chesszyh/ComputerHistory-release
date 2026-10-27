#!/bin/bash
# 默认打开已安装应用；源码调试可显式指定二进制。
#
# 用法：
#   ./scripts/menubar.sh          启动（已在运行则提示）
#   ./scripts/menubar.sh --stop   停止

set -u

APP="${HOME}/Applications/ComputerHistory.app"
BIN="${COMPUTER_HISTORY_MENUBAR_BIN:-${APP}/Contents/MacOS/computer-history-menubar}"
if [[ ! -x "${BIN}" ]]; then
    echo "找不到可执行文件：${BIN}" >&2
    echo "请先安装 ComputerHistory.app；源码调试可用 COMPUTER_HISTORY_MENUBAR_BIN 指定程序。" >&2
    exit 1
fi

if [[ "${1:-}" == "--stop" ]]; then
    exec "${BIN}" --stop
fi

if [[ -z "${COMPUTER_HISTORY_MENUBAR_BIN:-}" ]]; then
    exec /usr/bin/open "$APP"
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
