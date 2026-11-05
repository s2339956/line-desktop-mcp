# 原始來源與修改範圍

本倉庫以 [dtwang/line-desktop-mcp](https://github.com/dtwang/line-desktop-mcp) 的1.1.2為基礎，基準commit為 `c138acef5343428a359722f352f6a85ab32a718b`，保留上游commit歷史及MIT授權。

```sh
git diff c138acef5343428a359722f352f6a85ab32a718b..v1.2.1
```

保留上游五個工具名稱：三個聊天歷史工具及 `send_message_manual`、`send_message_auto`。macOS改由原生helper與受控桌面流程執行；Windows adapter只保留來源，未在此版驗收。

1.2.1新增十個stdio桌面工具：狀態、單張圖片、分頁盤點、分類計畫、有界歷史及搜尋。加入視窗與目標核對、圖片雜湊與重編碼、共用操作鎖、一次性計畫及不明提交阻擋。整理Mac安裝入口、MCPB／ZIP、鎖定依賴、合成自動測試及AI agent文件。

移除舊cliclick安裝流程、未由統一入口使用的獨立HTTP server、診斷用聊天正文log及示範媒體。實機帳號、名稱、路徑、操作紀錄與開發計畫沒有納入本次新增公開commit。

作者與授權見 [NOTICE](../NOTICE.md)、[LICENSE](../LICENSE.md)。上游npm套件仍由原作者維護，本fork的1.2.1從GitHub Releases分發。
