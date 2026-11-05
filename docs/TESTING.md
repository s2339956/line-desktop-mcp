# 1.2.0 版本與驗證

驗證日期2026-11-05。只公開必要軟體版本與結果，不含實機收件者、帳號、個人路徑、截圖、操作編號或原始回條。

| 項目 | 版本／範圍 |
| --- | --- |
| 本專案 | 1.2.0；package、lock root、manifest與MCP握手一致 |
| 上游基準 | dtwang/line-desktop-mcp 1.1.2，commit c138acef5343428a359722f352f6a85ab32a718b |
| 已驗macOS | 26.4.1，build 25E253 |
| 已驗架構 | Apple Silicon arm64 |
| 已驗LINE Desktop | 26.4.2，build 3955 |
| Node.js／npm | 26.13.0／12.2.1 |
| Swift | Apple Swift 6.3.3，build swiftlang-6.3.3.1.3 |
| MCP SDK | 1.32.1，依package-lock鎖定 |
| Express／archiver | 5.3.0／8.0.0，依package-lock鎖定 |
| 宣告最低需求 | macOS 14、Node.js 22、Xcode Command Line Tools；不等於已在所有最低版本實機驗證 |
| Intel Mac／Windows | 此次未實機驗證；沒有Windows安裝包 |

`npm test`使用合成資料，涵蓋協定、參數、操作鎖／紀錄、一次性token、圖片格式與雜湊、恢復、安裝設定保留／備份與封裝排除。macOS會編譯當前Swift來源做純自檢，同時停用UI，不讀取或傳送真實LINE內容。

`npm run check`以真正stdio程序握手並列工具，核對1.2.0與15工具，不呼叫內容操作。MCPB／ZIP會另行解壓後做相同協定檢查與檔案清單核對。設定合併只用合成暫存檔，不以測試覆寫真實client設定。當前測試數量、通過結果及檔案雜湊見該版Release及 `SHA256SUMS`。

圖片核心已於上述macOS／LINE版本，在明確授權下以非敏感圖片完成一次提交，畫面及UI_SUBMITTED回條均確認。發行整理不額外重送，也不檢查對方收到或已讀。這不代表所有分類修改、完整歷史、語言／縮放或每個AI client均已實機驗證。

發行包不含測試、實機診斷工具或個人紀錄。CI只跑合成／協定測試，不登入LINE、不實際傳訊。各client安裝畫面與權限提示仍需在安裝機器確認；未宣稱上架官方擴充目錄、Apple簽章或公證。

1.2.0最終本機結果：263項自動測試通過、原生純自檢464項通過；正式依賴的npm audit回報0個已知問題。這是發行當日鎖檔的結果，不是未來或所有環境的安全保證。
