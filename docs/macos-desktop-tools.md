# macOS 工具與限制

1.5.1統一入口為 `src/server.js`。stdio提供27工具；舊HTTP模式只保留五個上游工具，不提供新桌面或圖片功能。

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

## 1.3.0 健檢與請求紀錄

`line_doctor {probeNative:false}`或`npm run doctor`不編譯、不操作LINE，列出版本與相容性；`probeNative:true`或CLI加`--native`才呼叫原生權限探針，可能首次編譯，完全不讀對話。`uiReadinessConfirmed`僅表示權限與程序基本條件，不取代發送前的完整視窗核對。未驗證版本不放寬indexed profile。

文字manual／auto與單圖工具可傳16–128位英數、底線或連字號的`requestId`。同編號須保持內容與模式不變；已完成時回既有回條且`replayed:true`。持久化資料只有雜湊、狀態及必要回條，不保存路徑、對話名或文字。無編號的舊呼叫維持原行為。

`line_operation_status {requestId}`查詢狀態。只有使用者已人工觀察結果時，才使用`line_resolve_operation {requestId,operationId,outcome:"submitted"或"abandoned"}`。工具不判斷對方收到或已讀；先封存精確journal並比對穩定主窗，原請求永久不可重送。`submitted`是使用者回報，不能冒充UI驗證回條；不會清除別的操作。

## 1.4.0 多圖與一般檔案直送

`line_send_images`必填chatName、requestId、images陣列，每項imagePath與imageSha256。`line_send_files`必填chatName、requestId、files陣列，每項filePath與fileSha256。每批1–10項；圖片每張20MiB，整批附件總計100MiB；同一批不接受重複內容。沒有autoSend、caption、PDF轉換或確認／取消參數，正常情況直接按順序送出。

每項先建立私有、SHA綁定的完整快照；全批都通過才開始UI。一般檔案保留原始位元組與檔名（Unicode採標準等價正規化），PDF可當一般檔案傳送，不轉成圖片；圖片沿用既有PNG/JPEG解碼與重編碼。

需先由使用者打開指定對話；工具只在鍵鼠閒置、主窗與簽章核對後啟用現有LINE，不搜尋或切換對話。項目間自動等待自己的事件離開2秒idle窗口，下一項仍核對硬體輸入；這不是等待使用者確認。若client工具逾時較短，大批附件請將該次呼叫預算設為至少120秒，並先完成Mac安裝的預編譯。

success:true代表本批均已UI_SUBMITTED。success:false、partial:true代表已驗證的前綴送出，failedIndex為0起算、completedCount是已驗證數量；不會送後項，也不重送前綴。不明則回OPERATION_UNCERTAIN，請用原requestId查line_operation_status，不換新編號自動重送。若清除journal失敗，已保存回條仍有效，狀態會提示needsRecovery。

一般檔案的原生核對依據為已驗NSOpenPanel、完整GoTo路徑、含SHA的私有目錄、唯一檔名Info首行、檔案位元組SHA及唯一Open按鈕。已用獨立標準NSOpenPanel的合成TXT及ZIP核對結構；這不等同已在LINE向真人提交每種檔案。


## 1.5.0 本機agent服務

新增 `line_agent_workflow`、`line_describe_attachments` 及 `line_index_import/search/sources/delete/restore` 七工具。統一入口與stdio限制不變；agent服務不取得桌面UI鎖，不啟動LINE或存取剪貼簿。

附件描述只讀明確1–10個絕對路徑，總計100MiB，拒絕symlink、多硬連結與變動中的檔案；回傳索引、SHA256、大小，不回檔案內容或路徑。不執行檔案、解壓或轉換。發送時仍重新核對SHA；雜湊不是發送授權。

索引資料夾與金鑰僅於明確呼叫索引工具時建立，不隨服務啟動或讀聊天建立；只有import會保存文字來源。最多100來源（含可還原移除）、每份100000字元、標籤200字元；保留1–365天，預設30天。文字與標籤、日期、移除狀態一起AES-256-GCM加密，每次隨機nonce，以sourceId作AAD；金鑰32bytes儲於 `~/Library/Application Support/line-desktop-mcp/local-index/.key.json`，金鑰及密文0600、目錄0700。此為本機私有檔案保護，不能抵抗已控制同一帳號的程式，也未使用Keychain。

只使用來源UUID作檔名；每次存取由獨立索引鎖保護並以原子寫入提交。不記錄明文log、不做自動聊天擷取或網路索引。備份與搬移須將整個索引資料夾含金鑰保存在私人位置；遺失金鑰拒絕重建，竄改密文拒絕回報為空結果。不要將資料夾、金鑰或模型回應貼到公開issue。索引鎖不自動搶佔；異常中止留下鎖時，由維護者確認沒有索引程序執行後處理。

`line_index_search`最多200字元／10詞，NFKC小寫literal AND；每2000字元區塊獨立匹配，最多回50筆、預設20，回報matchedChunks／truncated／unknownDateExcluded。日期為使用者提供sourceDate、dateVerifiedByLINE:false；缺日期資料只在沒有日期限制時納入。移除只隱藏搜尋來源，仍計容量；可在到期前還原。到期於下次索引存取刪密文，沒有背景清理，也不承諾儲存媒體安全抹除。

## 維護結構

`server.js`負責協定與transport；`desktop-tools.js`／`agent-tools.js`定義工具schema；`agent-workflows.js`處理靜態流程、明確路徑SHA描述與索引路由。`local-index.js`專管加密來源與有界搜尋，`mcp-result.js`統一回應及公開錯誤白名單。桌面發送留在`desktop-automation.js`及`attachment-batch.js`，呼叫共用Swift原生附件流程；`request-records.js`與`private-json.js`分別處理防重與私有原子檔案。新增功能優先加在對應模組，避免擴大協定層與原生UI程式的職責。

純agent服務測試不呼叫native；桌面協定用合成bridge；原生自檢使用雙重停用UI的獨立程序。MCPB／ZIP只封裝執行來源與使用文件，測試、私人紀錄與診斷工具皆排除。


## 1.5.1 附件批次停止

client透過MCP取消當次呼叫時，排隊或尚未開始的附件停止；執行中的原生呼叫不中途強殺，先核對回條，再停止後項。以原requestId查line_operation_status，cancelled代表已知停止，result.completedCount只計可靠提交數，已提交內容不撤回。

結果不明維持uncertain／needsRecovery，不因client停止而視為安全未送出。若最後一項已可靠完成，記錄仍為succeeded。cancelled回條以isError標示，重播只回既有回條；不能換新requestId重送整批。沒有新增逐張確認或圖片取消視窗。停止通知是否送達由client與transport決定，僅關閉client畫面不保證通知已送達。
