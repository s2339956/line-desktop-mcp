# macOS 工具與限制

1.2.0統一入口為 `src/server.js`。stdio提供15工具；舊HTTP模式只保留五個上游工具，不提供新桌面或圖片功能。

| 工具 | 用途 |
| --- | --- |
| `get_line_chatroom_history_default/long/short` | 上游三種讀取範圍，可能影響已讀，非完整伺服器歷史 |
| `send_message_manual` | 寫入文字草稿，不送出 |
| `send_message_auto` | 提交指定文字，須明確授權 |
| `line_desktop_status` | 程序、權限、視窗與恢復狀態 |
| `line_send_image` | 當前已開啟且標題相符對話的單張圖片 |
| `line_list_tabs` | 有界分頁盤點，可能水平捲動 |
| `line_list_tab_chats` | 指定分頁的有界清單 |
| `line_mark_tab_read` | 預覽全部已讀計畫 |
| `line_plan_tab_changes` | 預覽建立、改名及分類移入／移出；不刪除對話 |
| `line_execute_plan` | 執行同連線一次性計畫token |
| `line_get_chat_history_page` | 指定分頁與對話的分段歷史 |
| `line_get_chat_history_global` | 經「全部」搜尋的有界讀取，不代表全帳號盤點 |
| `line_search_tab_messages` | 指定分頁可證成員的有界已載入歷史搜尋 |

參數以 `tools/list` schema為準。游標與token限同連線同參數，不能重播。分類修改／全部已讀須個別授權；離線通過不代表所有LINE版本均已實機驗證。

## 圖片

必填 `chatName`、`imagePath`、`imageSha256`，`autoSend`預設false。由使用者先開啟對話，工具核對完整標題及空白輸入區；不清除草稿、不搜尋或換對象。

只接受單影格PNG/JPEG，20MiB以下，單邊最多8192、總像素最多1600萬。拒絕symlink與多硬連結，對同一檔案描述元核對雜湊及大小。解碼後保留方向，重編碼為不附EXIF/GPS的PNG，放入私有暫存資料夾；不會移除圖片畫面中的敏感文字或人物。

選檔須核對完整路徑、唯一預覽及雜湊。false回 `IMAGE_SELECTED_NOT_SENT`，停在系統選檔器，沒有按「打開」，不是已傳出。true只按一次「打開」，可能立即送出；回 `UI_SUBMITTED`、`autoSent:true`作為「已發出」驗收，不追查對方收到或已讀，`deliveryConfirmed`維持false。

## 異常與本機資料

鍵鼠活動、按住修飾鍵、視窗漂移、無法核對目標或檔案時拒絕操作。不明提交會保留操作紀錄、阻擋異動；不得盲目重送、手刪紀錄或換對象備援。由使用者核對畫面與結果後，才依確切操作類型處理恢復。恢復腳本是原始碼維護工具，不隨MCPB／ZIP分發。

私有圖片快照留在系統暫存目錄，避免LINE延後讀檔失敗；最小恢復紀錄在 `~/Library/Application Support/line-desktop-mcp/`，編譯快取在 `~/Library/Caches/line-desktop-mcp/`，均不發布。LINE仍可能讀檔或結果不明時不可任意清除。不保存聊天正文log，沒有遙測、雲端圖片下載或週期發送。

權限須給真正啟動服務的client／終端機。LINE須登入、未鎖定且視窗可見；延伸螢幕仍受可辨識結構限制。LINE版本、語言、縮放或配置變更可能使工具拒絕操作，不放寬核對作備援。已驗環境見 [TESTING](TESTING.md)。
