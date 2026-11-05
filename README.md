# LINE Desktop MCP for macOS

讓支援MCP的AI agent在Mac上讀取有界聊天內容、撰寫文字，以及傳送單張PNG／JPEG。功能統一由同一個本機stdio MCP服務提供。

**版本1.2.0 · MIT開源 · macOS發行版**

衍生自 [Geoffrey Wang／dtwang 的 line-desktop-mcp](https://github.com/dtwang/line-desktop-mcp)，基準為上游 **1.1.2**。此分支由 [s2339956](https://github.com/s2339956) 維護macOS原生helper、圖片工具與安裝封裝。來源與授權見 [SOURCE](docs/SOURCE.md)、[NOTICE](NOTICE.md) 及 [MIT License](LICENSE.md)。本專案與LINE官方無關，不是Messaging API的LINE Bot。

## 安裝

需要macOS 14以上、已登入的LINE Desktop、Xcode Command Line Tools。ZIP／原始碼安裝另需Node.js 22以上；MCPB使用client提供的Node runtime，也須符合版本需求。已驗環境與支援範圍見 [TESTING](docs/TESTING.md)。

### Claude Desktop：MCPB

從 [Releases](https://github.com/s2339956/line-desktop-mcp/releases/latest) 下載 `line-desktop-mcp-1.2.0-macos.mcpb`，在Claude Desktop擴充功能設定選「Install Extension…」並開啟；支援檔案關聯的client也可雙擊。包內已有鎖定依賴，不下載上游 `npx @latest`。流程參見 [Claude官方文件](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop)。

依macOS提示，手動授予實際執行client「輔助使用」及「螢幕錄製」權限，再重新啟動client。權限不會自動放寬。

### ZIP：雙擊安裝

下載同一Release的 `line-desktop-mcp-1.2.0-macos.zip`，解壓到長期保留的資料夾，雙擊 **`Install.command`**。它會檢查需求、編譯helper、驗證MCP協定、備份並合併Claude Desktop設定，並產生通用 `mcp-config.json`。其他MCP設定保留，安裝不讀取或傳送LINE內容。

未安裝Command Line Tools時，先執行 `xcode-select --install`，完成Apple流程後再雙擊。若系統攔阻下載的腳本，請先檢視來源與組織政策；工具不移除quarantine或關閉保護。安裝後不要移動資料夾；移動或更新到新資料夾時重跑安裝以更新路徑。MCPB與ZIP安裝擇一即可。

其他AI agent、Codex與手動接法見 **[AI agent整合](docs/AI-AGENTS.md)**。

## 使用

連接後確認服務版號 **1.2.0**、**15個工具**，先呼叫 `line_desktop_status`。LINE須已登入、未鎖定且視窗可見；操作時暫停鍵鼠與其他桌面自動化。

對agent說：

> 檢查LINE是否可用，再讀取指定對話最近5個可觀察區塊，說明範圍是否完整。

> 把指定文字放入指定對話草稿，不送出。

> 我已開啟指定對話。核對標題並計算本機圖片SHA256，先選入圖片但不送出。

實際發送須明確指定對話、圖片與送出意圖。圖片預設 `autoSend:false`；true會按一次可能立即送出的「打開」。`UI_SUBMITTED`作為已發出驗收，不額外檢查對方收到或已讀。限制與回條見 [工具說明](docs/macos-desktop-tools.md)。

## 隱私

工具不設遙測、不上傳診斷資料、不保存聊天正文log，不需要LINE API token。讀取結果仍會交給你選擇的AI client／模型；發送透過LINE送往指定對話，請選用信任的agent。

公開測試只用合成資料；安裝包不含測試、實機診斷腳本、聊天截圖、操作紀錄、草稿備份或本機設定。生成的 `mcp-config.json` 含絕對路徑，已排除Git。私有圖片快照及不明操作的最小恢復紀錄保留在本機，不自動清除；勿在LINE仍可能讀檔或結果不明時任意刪除。

## 開發

```sh
git clone https://github.com/s2339956/line-desktop-mcp.git
cd line-desktop-mcp
npm ci --ignore-scripts
npm test
npm run check
npm run build:release
```

`check`只握手與列工具，不呼叫LINE內容工具。發行檔在 `dist/`，附SHA256SUMS，已有同名檔案時拒絕覆寫。本fork沒有發布npm套件，請勿以上游同名npm套件代替。Windows adapter僅保留來源相容性，此版沒有Windows安裝包或實機保證。
