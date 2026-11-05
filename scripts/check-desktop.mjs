import fs from 'node:fs';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { NativeBridge } from '../src/automation/native-bridge.js';
import { MacOSDesktopAutomation } from '../src/automation/desktop-automation.js';
import { LineAutomation } from '../src/automation/line-automation.js';
import { assertSafeName } from '../src/automation/automation-error.js';
import { LineDesktopMCPServer } from '../src/server.js';

// 僅將 Swift 的固定訊息投影成安全 enum，避免 native message/details 洩漏至診斷輸出。
const SEMANTIC_CAUSE_BY_MESSAGE = new Map([
  ['無法唯一辨識唯讀左側聊天室 AXList', 'READ_TAB_CHAT_LIST_NOT_UNIQUE'],
  ['無法唯一辨識唯讀左側搜尋欄', 'READ_TAB_SEARCH_FIELD_NOT_UNIQUE'],
  ['無法辨識跨越主窗中線的唯讀 split group', 'READ_TAB_SPLIT_GROUP_UNRELIABLE'],
  ['無法由三個唯一視窗 chrome 按鈕校正唯讀分頁帶', 'READ_TAB_CHROME_CALIBRATION_FAILED'],
  ['AX 結構推導的唯讀分頁 ROI 不合理', 'READ_TAB_ROI_INVALID'],
  ['無法唯一辨識訊息輸入區', 'LAYOUT_COMPOSER_NOT_UNIQUE'],
  ['無法唯一辨識右側訊息 AXList', 'LAYOUT_MESSAGE_LIST_NOT_UNIQUE'],
  ['無法唯一辨識左側聊天室 AXList', 'LAYOUT_CHAT_LIST_NOT_UNIQUE'],
  ['無法唯一辨識左側搜尋欄', 'LAYOUT_SEARCH_FIELD_NOT_UNIQUE'],
  ['無法辨識 LINE 主要 split group', 'LAYOUT_MAIN_SPLIT_GROUP_UNRELIABLE'],
  ['無法辨識 LINE 右側 split group', 'LAYOUT_RIGHT_SPLIT_GROUP_UNRELIABLE'],
  ['無法由三個視窗 chrome 按鈕校正分頁帶', 'LAYOUT_CHROME_CALIBRATION_FAILED'],
  ['AX 結構推導的 OCR ROI 不合理', 'LAYOUT_OCR_ROI_INVALID'],
  ['可見聊天室列數不可靠', 'CHAT_ROWS_COUNT_UNRELIABLE'],
  ['名稱探針清單幾何不可靠', 'NAME_PROBE_LIST_GEOMETRY_UNRELIABLE'],
  ['左側聊天室 AXList 缺少 frame', 'CHAT_LIST_FRAME_MISSING'],
  ['無法安全聚焦左側聊天室 AXList', 'CHAT_LIST_FOCUS_UNVERIFIED'],
  ['metadata 左側清單幾何或 overlay 不可靠', 'METADATA_CHAT_LIST_GEOMETRY_UNRELIABLE'],
  ['bounded 掃描沒有可靠聊天室列', 'BOUNDED_CHAT_SCAN_NO_RELIABLE_ROWS'],
  ['搜尋欄缺少 frame', 'SEARCH_FIELD_FRAME_MISSING'],
  ['無法安全聚焦已驗證 message AXList', 'MESSAGE_LIST_FOCUS_UNVERIFIED'],
]);
const TAB_SELECTION_CAUSE_BY_MESSAGE = new Map([
  ['global route 的 selected 證據視窗不符', 'GLOBAL_ROUTE_SELECTED_WINDOW_MISMATCH'],
  ['global route 的主視窗已漂移', 'GLOBAL_ROUTE_WINDOW_CHANGED'],
  ['單一可見分頁頁面無法唯一辨識全部／All route', 'GLOBAL_ALL_ROUTE_NOT_UNIQUE'],
  ['第一張 raw 分頁 selected 證據不可靠', 'TAB_FIRST_RAW_SELECTED_UNRELIABLE'],
  ['兩張 raw 分頁 selected 證據不一致', 'TAB_RAW_SELECTED_EVIDENCE_DRIFT'],
  ['AXPress 後 selected-state 未經證實', 'TAB_AX_PRESS_SELECTION_UNVERIFIED'],
  ['AXPress 後結果不明', 'TAB_AX_PRESS_RESULT_UNCERTAIN'],
  ['第一張 raw 分頁有不可靠的 selected hint', 'TAB_FIRST_RAW_SELECTED_HINT_UNRELIABLE'],
  ['raw selected 證據意外消失', 'TAB_RAW_SELECTED_EVIDENCE_LOST'],
  ['目標分頁缺少唯一且相對應的 selected underline', 'TAB_TARGET_UNDERLINE_UNVERIFIED'],
  ['目標分頁 raw selected 證據消失', 'TAB_TARGET_RAW_SELECTED_EVIDENCE_LOST'],
  ['唯讀分頁色彩或 selected 證據不穩定', 'TAB_READ_PROFILE_OR_SELECTION_UNSTABLE'],
]);
const CAUSE_BY_ERROR_CODE = new Map([
  ['SEMANTIC_UNRELIABLE', SEMANTIC_CAUSE_BY_MESSAGE],
  ['TAB_SELECTION_UNVERIFIED', TAB_SELECTION_CAUSE_BY_MESSAGE],
]);
const CAUSE_CODES_BY_ERROR_CODE = new Map([...CAUSE_BY_ERROR_CODE]
  .map(([code, causes]) => [code, new Set(causes.values())]));

export function parseDesktopArgs(argv) {
  const options = { read: false, page: false, ax: false, tabName: null, chatName: null,
    resultIndex: null };
  for (let index = 0; index < argv.length; index++) {
    const flag = argv[index];
    if (flag === '--read') options.read = true;
    else if (flag === '--page') options.page = true;
    else if (flag === '--ax') options.ax = true;
    else if (flag === '--global') {
      if (options.global) throw new Error('--global 不可重複');
      options.global = true;
    }
    else if (flag === '--result-index') {
      if (options.resultIndex !== null) throw new Error('--result-index 不可重複');
      const value = Number(argv[++index]);
      if (!Number.isInteger(value) || value < 1 || value > 20) {
        throw new Error('--result-index 必須是 1 到 20 的整數');
      }
      options.resultIndex = value;
    }
    else if (flag === '--tab' || flag === '--chat') {
      const field = flag === '--tab' ? 'tabName' : 'chatName';
      if (options[field] !== null) throw new Error('測試目標參數不可重複');
      options[field] = assertSafeName(argv[++index], field);
    } else throw new Error('只接受 --read、--page、--global、--result-index、--ax、--tab 與 --chat');
  }
  validateGlobalOptions(options);
  if ((options.read || options.ax) && ((!options.global && !options.tabName) || !options.chatName)) {
    throw new Error('唯讀驗收必須同時指定 --tab 與 --chat');
  }
  if (!options.read && !options.ax && (options.tabName || options.chatName)) {
    throw new Error('目標僅可搭配明確的 --read 或 --ax 使用');
  }
  if (options.page && !options.read) throw new Error('--page 必須搭配 --read 與 exact 目標');
  if (options.ax && (options.read || options.page)) throw new Error('--ax 不可與讀取訊息模式混用');
  return options;
}

function validateGlobalOptions(options) {
  if (options.global !== undefined && options.global !== true) {
    throw new Error('--global 必須是明確的開啟旗標');
  }
  // 全域驗收只走正式分段工具；不讓呼叫端繞過 parser 後改走 legacy 或分頁模式。
  if (options.global && (options.read !== true || options.page !== true || options.ax ||
      (options.tabName !== null && options.tabName !== undefined) || !options.chatName)) {
    throw new Error('--global 必須搭配 --read --page --chat，且不可與 --tab／--ax 混用');
  }
  if (options.global) assertSafeName(options.chatName, 'chatName');
  if (options.resultIndex != null && !options.global) {
    throw new Error('--result-index 只可搭配 --global --read --page');
  }
}

function axMetadata(raw, scope) {
  // 只投影固定型別欄位；不讓未知 AX 名稱或正文隨原生結果流入終端。
  const fail = () => { throw Object.assign(new Error('AX 探針缺少安全的 metadata'), { code: 'NATIVE_PROTOCOL_ERROR' }); };
  if (!raw || typeof raw !== 'object' || Array.isArray(raw) ||
      raw.scope?.tabName !== scope.tabName || raw.scope?.chatName !== scope.chatName ||
      raw.bodyReadAttempted !== false || raw.ocrUsed !== false || raw.uiEvents !== 0) fail();
  const projected = {};
  for (const field of ['axTabGroupCount', 'axTabCount', 'axTargetTabMatchCount', 'axSaveChatActionCount',
    'axObjectsWithNameCount', 'axObjectsWithStateCount', 'axObjectsWithIdentifierCount']) {
    if (!Number.isInteger(raw[field]) || raw[field] < 0 || raw[field] > 1000) fail();
    projected[field] = raw[field];
  }
  for (const field of ['axRowCount', 'axTargetRowNameMatchCount']) {
    if (raw[field] !== null && (!Number.isInteger(raw[field]) || raw[field] < 0 || raw[field] > 1000)) fail();
    projected[field] = raw[field];
  }
  for (const field of ['axTargetTabSelected', 'axTargetTabIdentifierPresent', 'axHeaderNameMatches']) {
    if (raw[field] !== null && typeof raw[field] !== 'boolean') fail();
    projected[field] = raw[field];
  }
  for (const field of ['axTabInventoryCalibrated', 'axHeaderTitleRelationAvailable', 'requiresCalibration']) {
    if (typeof raw[field] !== 'boolean') fail();
    projected[field] = raw[field];
  }
  return projected;
}

function decodeToolResult(result) {
  let payload;
  try { payload = JSON.parse(result.content?.[0]?.text); }
  catch { throw Object.assign(new Error('MCP 工具回傳格式不正確'), { code: 'MCP_PROTOCOL_ERROR' }); }
  if (result.isError) {
    const code = typeof payload?.error?.code === 'string' ? payload.error.code : 'DESKTOP_OPERATION_FAILED';
    const causeCode = typeof payload?.error?.message === 'string'
      ? CAUSE_BY_ERROR_CODE.get(code)?.get(payload.error.message)
      : undefined;
    // CLI 只保留 typed code，不把 native 或聊天內容帶入終端錯誤。
    throw Object.assign(new Error('桌面唯讀驗收未完成'),
      causeCode ? { code, details: { causeCode } } : { code });
  }
  return payload;
}

async function checkHistoryPage(options, bridge, desktop) {
  const facade = new LineAutomation({ platform: 'darwin', desktop });
  const server = new LineDesktopMCPServer(facade, {
    transport: 'stdio', sessionId: `desktop-page-${randomUUID()}`,
  });
  const client = new Client({ name: 'line-desktop-page-check', version: '1.0.0' });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  try {
    await server.server.connect(serverTransport);
    await client.connect(clientTransport);
    const status = decodeToolResult(await client.callTool({ name: 'line_desktop_status', arguments: {} }));
    if (status.usable !== true) {
      throw Object.assign(new Error('LINE 主視窗目前不可用'), { code: 'MAIN_WINDOW_UNAVAILABLE' });
    }
    // 僅在起點失焦時啟用一次；失敗不 retry，也不改搜其他 body。
    if (status.foreground === false) {
      const activation = await facade.activateLine();
      if (activation?.success !== true) {
        throw Object.assign(new Error('LINE 無法在唯讀驗收起點取得前景'), { code: 'ACTIVATE_FAILED' });
      }
    }
    const page = decodeToolResult(await client.callTool({
      name: options.global ? 'line_get_chat_history_global' : 'line_get_chat_history_page',
      arguments: options.global ? { chatName: options.chatName, limit: 5,
        ...(options.resultIndex == null ? {} : { resultIndex: options.resultIndex }) }
        : { tabName: options.tabName, chatName: options.chatName, limit: 5 },
    }));
    const digest = await bridge.selectedSourceDigest();
    return {
      mode: 'mcp-history-page',
      fixture: options.global ? { kind: 'global', chatName: options.chatName,
        ...(options.resultIndex == null ? {} : { resultIndex: options.resultIndex }) }
        : { tabName: options.tabName, chatName: options.chatName },
      count: Array.isArray(page.observations) ? page.observations.length : 0,
      hasCursor: typeof page.cursor === 'string',
      metadata: {
        observedAt: page.observedAt,
        complete: page.complete === true,
        reasons: Array.isArray(page.reasons) ? page.reasons : [],
        syncState: page.syncState,
        truncated: page.truncated === true,
        possibleDuplicates: page.possibleDuplicates === true,
        excludedUnknownDateCount: Number.isInteger(page.excludedUnknownDateCount)
          ? page.excludedUnknownDateCount : 0,
        mayAffectReadState: page.mayAffectReadState === true,
        ...digest,
        writeToolsEnabled: false,
      },
    };
  } finally {
    await client.close().catch(() => {});
    await server.server.close().catch(() => {});
  }
}

export async function checkDesktop(options, makeDesktop = bridge => new MacOSDesktopAutomation({ bridge }),
  makeBridge = options => new NativeBridge(options)) {
  validateGlobalOptions(options);
  if (options.ax) {
    if (options.read || options.page) throw new Error('--ax 不可與讀取訊息模式混用');
    assertSafeName(options.tabName, 'tabName');
    assertSafeName(options.chatName, 'chatName');
  }
  // 此 runner 的能力在 bridge 層限縮；不能只靠呼叫者承諾「不呼叫送出」。
  const liveScope = options.global ? { kind: 'global', chatName: options.chatName,
    ...(options.resultIndex == null ? {} : { resultIndex: options.resultIndex }) } : options.read || options.ax
    ? { tabName: options.tabName, chatName: options.chatName }
    : { tabName: '__status_only__', chatName: '__status_only__' };
  const bridge = makeBridge({ liveScope, timeoutMs: 25000 });
  const desktop = makeDesktop(bridge);
  if (options.ax) {
    if (typeof desktop.lock?.withLock !== 'function') {
      throw Object.assign(new Error('AX 探針需要共用操作鎖'), { code: 'AX_PROBE_LOCK_UNAVAILABLE' });
    }
    return desktop.lock.withLock(async () => {
      const probe = axMetadata(await bridge.call('probeAXReadScope', liveScope), liveScope);
      const digest = await bridge.selectedSourceDigest();
      return {
        mode: 'ax-capabilities', fixture: liveScope, probe,
        sourceDigest: digest.sourceDigest, sourceDigestVerified: digest.sourceDigestVerified,
        bodyReadAttempted: false, ocrUsed: false, uiEvents: 0,
      };
    });
  }
  if (options.page) return checkHistoryPage(options, bridge, desktop);
  const status = await desktop.call('line_desktop_status', {}, { transport: 'stdio', sessionId: 'desktop-check-readonly' });
  if (!options.read) return { mode: 'status', status };
  if (status.usable !== true) return { mode: 'live-readonly', status, complete: false, reasons: ['MAIN_WINDOW_UNAVAILABLE'] };
  // 僅在已授權讀取流程起點啟用一次；後續焦點失去由 native guard 停止，不反覆搶回前景。
  if (status.foreground === false) await desktop.activateLine();
  const history = await desktop.legacyHistory(options.chatName, undefined, 5, 0);
  // 驗收只回資料量與證據狀態，不把私人訊息全文寫入終端或 artifact。
  return {
    mode: 'live-readonly', fixture: { tabName: options.tabName, chatName: options.chatName },
    observedAt: new Date().toISOString(),
    historyCharacters: history.history.length,
    metadata: history.metadata,
    writeToolsEnabled: false,
  };
}

const filename = fileURLToPath(import.meta.url);
if (process.argv[1] && fs.existsSync(process.argv[1]) && fs.realpathSync(process.argv[1]) === filename) {
  try {
    const result = await checkDesktop(parseDesktopArgs(process.argv.slice(2)));
    console.log(JSON.stringify(result));
  } catch (error) {
    const causeCode = CAUSE_CODES_BY_ERROR_CODE.get(error.code)?.has(error.details?.causeCode)
      ? error.details.causeCode
      : undefined;
    const output = {
      code: error.code || 'CHECK_FAILED',
      message: error.code ? error.message : '驗收參數或執行失敗',
    };
    if (causeCode) output.details = { causeCode };
    console.error(JSON.stringify({ error: output }));
    process.exitCode = 1;
  }
}
