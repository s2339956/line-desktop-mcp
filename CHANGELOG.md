# 更新紀錄

## 1.2.1 — 2026-11-05

- Swift首次冷編譯上限統一提高為300秒，涵蓋MCPB惰性編譯、Mac安裝入口及CI純策略編譯；LINE操作逾時與安全核對不變。
- 編譯失敗顯示實際逾時原因，CI工作預算改為15分鐘。修正GitHub較慢macOS runner在原120秒編譯測試上限被終止的問題。
- 保留1.2.0來源、授權、安裝包與版本歷史；套件、manifest、lock與協定版本同步為1.2.1。

## 1.2.0 — 2026-11-05

- 以dtwang/line-desktop-mcp 1.1.2為基準，保留原作者、MIT及五個工具名稱。
- 新增macOS Swift helper及十個stdio桌面工具，包含圖片、有界歷史、分頁與計畫。
- 圖片加入原檔SHA256、去除附加metadata、完整對話核對、預設不發送及不明提交禁止重試。
- 統一MCPB／ZIP與Install.command，提供設定備份合併、鎖定依賴、原生編譯及協定檢查。
- 補齊AI agent、Codex、Claude Desktop接法及明確測試版本／未驗範圍。
- 移除聊天正文log、實驗性AX模式診斷、cliclick安裝及獨立HTTP入口。發行包排除測試、診斷與本機資料，公開測試只保留合成資料。

封裝依賴更新至archiver 8.0.0，採官方ZipArchive API，移除舊glob依賴；針對readdir-glob鎖定minimatch 11.0.1以修正globparts放大問題；其餘執行依賴按鎖檔保留。


## 1.1.2 — 上游基準

原作者Geoffrey Wang的LINE Desktop MCP，來源見 [NOTICE](NOTICE.md)。本fork未重新發布原作者的npm套件。
