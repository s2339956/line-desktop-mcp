#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
# Finder 啟動時不一定有 shell 的 PATH；只補常見 Node 安裝位置。
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v node >/dev/null 2>&1; then
  echo '需要 Node.js 22 或以上，請先從 https://nodejs.org/ 安裝。'
  read -r -p '按 Enter 結束。' _
  exit 1
fi
if node scripts/setup-mac.mjs --claude; then
  echo '安裝完成。請重新啟動 Claude Desktop；其他 AI agent 請使用 mcp-config.json。'
else
  echo '安裝未完成，請依上方訊息處理；原本設定已保留。'
  read -r -p '按 Enter 結束。' _
  exit 1
fi
read -r -p '按 Enter 結束。' _
