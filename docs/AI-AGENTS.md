# 搭配 AI agent 使用

AI agent須支援 **本機MCP stdio**；服務、LINE與桌面權限須在同一部Mac。僅有雲端HTTP connector、不能啟動本機程序的agent，不能直接使用圖片工具。

## 通用設定

安裝Node.js 22以上及Xcode Command Line Tools，解壓Release ZIP。Claude Desktop可雙擊 `Install.command`；其他agent在資料夾內執行 `node scripts/setup-mac.mjs`，會完成依賴、編譯及協定檢查，產生 `mcp-config.json`，不修改client設定。將其中的服務加入client並重新連接。

生成檔會填入正確的Node完整路徑；下列僅為格式，路徑須替換：

```json
{
  "mcpServers": {
    "line-desktop-mcp": {
      "command": "/absolute/path/to/node",
      "args": ["/absolute/path/to/line-desktop-mcp/src/server.js"],
      "env": { "CHAT_LOG_ON": "false" }
    }
  }
}
```

`CHAT_LOG_ON`僅保留設定相容性；1.2.1已移除聊天正文寫檔。不將生成的個人設定上傳公開issue。若只需產生設定、不安裝或編譯，可用 `node scripts/setup-mac.mjs --config-only`。

## Codex

先在工具資料夾完成 `node scripts/setup-mac.mjs`，再於該目錄執行：

```sh
codex mcp add line-desktop-mcp --env CHAT_LOG_ON=false -- "$(command -v node)" "$PWD/src/server.js"
codex mcp list
```

此命令由你執行，會新增本機MCP設定。重新啟動或重連後確認版號與工具清單。語法已依發行時本機CLI的 `codex mcp add --help`核對；介面不同時使用client的本機MCP設定入口。

## Claude Desktop

選用Release MCPB或ZIP的 `Install.command`，兩者擇一。MCPB用client的Node runtime；ZIP入口會備份並合併 `~/Library/Application Support/Claude/claude_desktop_config.json`，保留其他設定。損壞JSON、symlink或安裝期間設定變更時會停止。

重啟Claude Desktop。自訂MCPB從擴充功能「Install Extension…」開啟，介面以 [官方文件](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop) 為準；本專案未宣稱通過官方目錄審核。

## 可提供給 agent 的操作規則

```text
透過line-desktop-mcp操作本機LINE，先呼叫line_desktop_status。
只讀取使用者指定的對話與範圍，回報截斷、日期未知及完整性；不要把失敗當成空清單。
傳文字須確認對話及內容；未要求送出時用send_message_manual。
傳圖用line_send_image，綁定本機絕對路徑與原檔SHA256，核對已開啟對話的完整標題。
預設autoSend:false；只在使用者明確同意特定圖片發給特定對話時設true。
false會停在系統選檔器；不要另呼叫一次造成重複。必要時由使用者取消或打開。
UI_SUBMITTED即視為已發出，不額外檢查對方收到或已讀。
OPERATION_UNCERTAIN或needsRecovery=true時停止，不自動重送、不手刪紀錄、不切換收件者備援。
UI操作前提醒使用者暫停鍵鼠及其他桌面自動化。
```

## 圖片參數

```json
{
  "chatName": "使用者指定的完整對話名稱",
  "imagePath": "/absolute/path/to/image.png",
  "imageSha256": "原始檔SHA256的64位小寫十六進位值",
  "autoSend": false
}
```

用agent的本機檔案工具或 `shasum -a 256 /absolute/path/to/image.png` 算SHA，不能填範例字串。先由使用者開啟對話；圖片工具不搜尋或切換對象。完整限制見 [工具說明](macos-desktop-tools.md)。

工具本機執行；讀取內容仍會交給你選用的client／模型。不要讓agent讀取不願交給該模型的內容。
