// 新桌面工具集中定義；執行端仍須驗證參數，schema 不是授權或安全邊界。
const object = properties => ({ type: 'object', properties, additionalProperties: false });
const name = { type: 'string', minLength: 1, maxLength: 200 };
const handle = { type: 'string', minLength: 16, maxLength: 200 };
const limit = { type: 'integer', minimum: 1, maximum: 100, default: 50 };
const resultIndex = { type: 'integer', minimum: 1, maximum: 20 };
const date = { type: 'string', pattern: '^\\d{4}-\\d{2}-\\d{2}$', description: 'LINE 畫面的本地日曆日期；執行端另驗證有效日期。' };
const schema = (properties, required = []) => ({ ...object(properties), required });

export const desktopTools = [
  {
    name: 'line_send_image',
    description: '將單張 PNG/JPEG 選入目前已開啟且標題核對相符的 LINE 對話，不搜尋或換對話。預設 autoSend:false，只停在已核對的附件選擇器；autoSend:true 會按一次打開，可能立即送出，僅限使用者已明確授權。圖片須綁定 SHA256；任何不明結果禁止重試。',
    inputSchema: schema({ chatName: name,
      imagePath: { type: 'string', minLength: 1, maxLength: 4096, description: '本機圖片的絕對路徑。' },
      imageSha256: { type: 'string', pattern: '^[a-f0-9]{64}$' },
      autoSend: { type: 'boolean', default: false },
    }, ['chatName', 'imagePath', 'imageSha256']),
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false },
  },
  {
    name: 'line_desktop_status',
    description: '檢查 macOS LINE 程序、權限與唯一主視窗；不開啟聊天室、不傳送訊息。',
    inputSchema: schema({}),
    annotations: { readOnlyHint: true, destructiveHint: false },
  },
  {
    name: 'line_list_tabs',
    description: '盤點 LINE 分頁；需要前景並會水平捲動分頁列，即使 maxPages:1 也不是零 UI 事件。回報可觀察範圍與完整性；不可讀取不代表空清單。',
    inputSchema: schema({ maxPages: { type: 'integer', minimum: 1, maximum: 20, default: 5 } }),
    annotations: { readOnlyHint: true, destructiveHint: false },
  },
  {
    name: 'line_list_tab_chats',
    description: '列出指定分頁中的聊天室與可辨識的類型；可能切換分頁，不開啟聊天室。',
    inputSchema: schema({ tabName: name, limit, cursor: handle }, ['tabName']),
    annotations: { readOnlyHint: true, destructiveHint: false },
  },
  {
    name: 'line_mark_tab_read',
    description: '只預覽指定分頁「全部已讀」計畫，不直接執行；確認範圍後使用一次性 token 執行。已讀狀態無法保證永久維持。',
    inputSchema: schema({ tabName: name }, ['tabName']),
    annotations: { readOnlyHint: true, destructiveHint: false },
  },
  {
    name: 'line_execute_plan',
    description: '執行同一連線預覽並核准的一次性計畫。過期、重播、前置狀態改變皆拒絕；提交後不明需人工確認，不可自動重試。',
    inputSchema: schema({ planToken: handle }, ['planToken']),
    annotations: { readOnlyHint: false, destructiveHint: true },
  },
  {
    name: 'line_plan_tab_changes',
    description: '預覽建立／改名分頁、聊天室移入／移出分類。只回預覽與可執行時的一次性 token，不直接更改分類。預覽可能開啟聊天室而影響已讀。建立／改名限單筆；移動／移出可同類型、同來源批次，最多 20 筆。移出不會刪除聊天或退出群組。',
    inputSchema: schema({ changes: {
      type: 'array', minItems: 1, maxItems: 20,
      items: { oneOf: [
        schema({ action: { const: 'create_tab' }, name }, ['action', 'name']),
        schema({ action: { const: 'rename_tab' }, tabName: name, newName: name }, ['action', 'tabName', 'newName']),
        schema({ action: { const: 'move_chat' }, sourceTab: name, destinationTab: name, chatName: name },
          ['action', 'sourceTab', 'destinationTab', 'chatName']),
        schema({ action: { const: 'remove_chat' }, sourceTab: name, chatName: name }, ['action', 'sourceTab', 'chatName']),
      ] },
    } }, ['changes']),
    annotations: { readOnlyHint: false, destructiveHint: false },
  },
  {
    name: 'line_get_chat_history_page',
    description: '分段讀取指定分頁中的指定聊天室。只回已觀察且可證範圍，不代表完整伺服器歷史；limit 計觀察區塊，不計換行。日期未知會揭露，嚴格日期篩選會排除未知日期。可能開啟聊天室而影響已讀；續讀須原參數與同一連線的 cursor。',
    inputSchema: schema({ tabName: name, chatName: name, startDate: date, endDate: date, limit, cursor: handle },
      ['tabName', 'chatName']),
    annotations: { readOnlyHint: false, destructiveHint: false },
  },
  {
    name: 'line_get_chat_history_global',
    description: '從 LINE 內建「全部」搜尋路由讀取指定聊天室。未提供 resultIndex 時仍要求名稱唯一；只有使用者明確指定搜尋結果順位時才傳 1–20 的 resultIndex，該模式不支援 cursor。global 不代表已盤點全帳號。',
    inputSchema: schema({ chatName: name, resultIndex, startDate: date, endDate: date, limit, cursor: handle },
      ['chatName']),
    annotations: { readOnlyHint: false, destructiveHint: false },
  },
  {
    name: 'line_search_tab_messages',
    description: '僅在指定分頁可證成員的有界已載入歷史中搜尋，不是 LINE 伺服器全庫搜尋。query 以 NFKC + JS 小寫、空白分詞作 literal AND，不使用正規表示式。每次讀一個原始頁，零命中仍可能有 cursor；請依完整性、日期未知、同步與進度判讀。開啟聊天室可能影響已讀。',
    inputSchema: schema({ tabName: name,
      query: { type: 'string', minLength: 1, maxLength: 1000 },
      startDate: date, endDate: date, limit, cursor: handle }, ['tabName', 'query']),
    annotations: { readOnlyHint: false, destructiveHint: false },
  },
];

export const desktopToolNames = new Set(desktopTools.map(tool => tool.name));
