#!/bin/bash
# 采集器自监督入口。实际循环在 `computer-history supervise` 中实现——
# 放在可执行文件里可以复用进程身份校验，也避免 shell 的解析差异。
#
# 用法：
#   ./scripts/supervise.sh             前台监督
#   ./scripts/supervise.sh --daemon    脱离终端会话常驻（推荐）
#   computer-history --stop            停止

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${COMPUTER_HISTORY_BIN:-${ROOT}/.build/release/computer-history}"

if [[ ! -x "${BIN}" ]]; then
    echo "找不到可执行文件：${BIN}" >&2
    exit 1
fi

exec "${BIN}" supervise "$@"
