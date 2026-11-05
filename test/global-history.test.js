import assert from 'node:assert/strict';
import test from 'node:test';
import { MacOSDesktopAutomation } from '../src/automation/desktop-automation.js';
import { AutomationError } from '../src/automation/automation-error.js';
import { desktopTools } from '../src/desktop-tools.js';
import {
  globalNavigationReceipt,
  memoryJournalFS,
  syntheticValidLINEWindow,
} from './fixtures/global-navigation-fixtures.mjs';

const context = (sessionId = 'global-test') => ({ transport: 'stdio', sessionId });
const hex = character => character.repeat(64);
const nativeState = (overrides = {}) => ({
  version: 1,
  expectedWindow: syntheticValidLINEWindow,
  headerDigest: hex('b'), anchorHash: hex('c'), offset: 0, pageNumber: 0,
  advance: false, seenIds: [], dateContext: null,
  ...overrides,
});
const globalPage = (overrides = {}) => ({
  scope: { kind: 'chat', chatName: '測試對話', verified: true },
  observations: [], observedAt: '2026-10-29T08:00:00Z',
  snapshotDigest: hex('a'), nextState: null,
  complete: false, reasons: ['NO_MESSAGE_ROWS_VERIFIED'], syncState: 'unknown',
  truncated: false, possibleDuplicates: false,
  ...overrides,
});
const tabPage = (overrides = {}) => ({
  scope: { tabName: 'Tab', chatName: '測試對話', verified: true },
  observations: [], observedAt: '2026-10-29T08:00:00Z',
  snapshotDigest: hex('d'), nextState: null, complete: true, reasons: [],
  syncState: 'complete', truncated: false, possibleDuplicates: false,
  ...overrides,
});

function desktopWithBridge(bridge, options = {}) {
  const bridgeCalls = [];
  const fileSystem = options.fileSystem || memoryJournalFS();
  const securedBridge = {
    async selectedSourceDigest() {
      return typeof bridge.selectedSourceDigest === 'function'
        ? bridge.selectedSourceDigest()
        : { sourceDigest: null, sourceDigestVerified: false };
    },
    async call(name, args) {
      bridgeCalls.push({ name, args });
      if (name === 'status') {
        return typeof options.status === 'function' ? options.status() : options.status || {
          running: true, accessibilityTrusted: true, foreground: true, usable: true,
          mainWindow: syntheticValidLINEWindow,
        };
      }
      if (name === 'selectGlobalAll') {
        return options.selectGlobalAll
          ? options.selectGlobalAll(args)
          : globalNavigationReceipt(args);
      }
      return bridge.call(name, args);
    },
  };
  const desktop = new MacOSDesktopAutomation({
    bridge: securedBridge,
    lock: options.lock || { withLock: work => work() },
    exportReader: options.exportReader ?? null,
    bootNonce: options.bootNonce || 'synthetic-global-history-test',
    fileSystem,
    journalPath: options.journalPath || '/synthetic-line-mcp/pending-operation.json',
    randomBytes: options.randomBytes || ((length) => Buffer.alloc(length, 0xab)),
    now: options.now || (() => 1_000),
  });
  desktop.globalBridgeCalls = bridgeCalls;
  desktop.globalJournalFS = fileSystem;
  return desktop;
}

test('global tool schema 只要求 chatName 且不暴露 tabName', () => {
  const tool = desktopTools.find(item => item.name === 'line_get_chat_history_global');
  assert(tool);
  assert.deepEqual(tool.inputSchema.required, ['chatName']);
  assert.deepEqual(Object.keys(tool.inputSchema.properties).sort(),
    ['chatName', 'cursor', 'endDate', 'limit', 'resultIndex', 'startDate'].sort());
  assert.equal(tool.inputSchema.additionalProperties, false);
});

test('explicit resultIndex 綁定 search_result scope，且 cursor 在任何 native call 前拒絕', async () => {
  const calls = [];
  const desktop = desktopWithBridge({ async call(name, args) {
    calls.push({ name, args });
    assert.equal(name, 'readGlobalHistoryPage');
    assert.equal(args.resultIndex, 2);
    return globalPage({
      scope: { kind: 'search_result', chatName: '測試對話', resultIndex: 2, verified: true },
      observations: [{ observedId: hex('9'), text: 'indexed block', date: null,
        dateVerified: false, unit: 'text_block', identityVerified: false,
        provenance: { source: 'VISIBLE_CHAT_VIEWPORT_OCR', complete: false } }],
      nextState: null, complete: false,
      reasons: ['VISIBLE_VIEWPORT_ONLY', 'DATE_CONTEXT_UNKNOWN',
        'STABLE_MESSAGE_ID_UNAVAILABLE', 'LATEST_BOUNDARY_UNVERIFIED'],
      syncState: 'unknown', truncated: false, possibleDuplicates: true,
    });
  } });
  const result = await desktop.call('line_get_chat_history_global',
    { chatName: '測試對話', resultIndex: 2, limit: 5 }, context());
  assert.deepEqual(result.scope,
    { kind: 'search_result', chatName: '測試對話', resultIndex: 2, verified: true });
  assert.deepEqual(calls.map(call => call.name), ['readGlobalHistoryPage']);
  const before = desktop.globalBridgeCalls.length;
  await assert.rejects(desktop.call('line_get_chat_history_global',
    { chatName: '測試對話', resultIndex: 2, cursor: 'forbidden', limit: 5 }, context()),
  error => error?.code === 'INVALID_ARGUMENT');
  assert.equal(desktop.globalBridgeCalls.length, before);
});

test('no-index global 拒絕 indexed viewport provider', async () => {
  const desktop = desktopWithBridge({ async call() {
    return globalPage({
      observations: [{ observedId: hex('9'), text: 'wrong provider', date: null,
        dateVerified: false, unit: 'text_block', identityVerified: false,
        provenance: { source: 'VISIBLE_CHAT_VIEWPORT_OCR', complete: false } }],
      reasons: ['VISIBLE_VIEWPORT_ONLY'], possibleDuplicates: true,
    });
  } });
  await assert.rejects(desktop.call('line_get_chat_history_global',
    { chatName: '測試對話', limit: 5 }, context()), error => error?.code === 'NATIVE_PROTOCOL_ERROR');
});

test('indexed viewport truthful 組合任一欄位漂移都拒絕', async () => {
  const base = {
    scope: { kind: 'search_result', chatName: '測試對話', resultIndex: 1, verified: true },
    observations: [{ observedId: hex('9'), text: 'block', date: null,
      dateVerified: false, unit: 'text_block', identityVerified: false,
      provenance: { source: 'VISIBLE_CHAT_VIEWPORT_OCR', complete: false } }],
    nextState: null, complete: false,
    reasons: ['VISIBLE_VIEWPORT_ONLY', 'DATE_CONTEXT_UNKNOWN',
      'STABLE_MESSAGE_ID_UNAVAILABLE', 'LATEST_BOUNDARY_UNVERIFIED'],
    syncState: 'unknown', truncated: false, possibleDuplicates: true,
  };
  for (const mutate of [
    page => { page.scope.resultIndex = 2; },
    page => { page.complete = true; },
    page => { page.possibleDuplicates = false; },
    page => { page.syncState = 'complete'; },
    page => { page.observations[0].identityVerified = true; },
    page => { page.observations[0].provenance.complete = true; },
    page => { page.reasons.pop(); },
  ]) {
    const page = structuredClone(base); mutate(page);
    const desktop = desktopWithBridge({ async call() { return globalPage(page); } });
    await assert.rejects(desktop.call('line_get_chat_history_global',
      { chatName: '測試對話', resultIndex: 1, limit: 5 }, context()),
    error => error?.code === 'NATIVE_PROTOCOL_ERROR');
  }
});

// 真正呼叫 MCP 的桌面 dispatcher；任何全分頁盤點都會使此回歸案例失敗。
test('全域讀取測試對話不呼叫分頁盤點，只接受全域身分證據', async () => {
  const calls = [];
  let lockCalls = 0;
  const desktop = desktopWithBridge({ async call(name, args) {
      calls.push({ name, args });
      assert.equal(name, 'readGlobalHistoryPage');
      assert.equal(args.chatName, '測試對話');
      assert.equal(args.tabName, undefined);
      return globalPage();
    } }, {
    lock: { withLock: (work) => { lockCalls += 1; return work(); } },
  });
  const result = await desktop.call('line_get_chat_history_global',
    { chatName: '測試對話', limit: 5 }, context());
  assert.deepEqual(result.scope, { kind: 'chat', chatName: '測試對話', verified: true });
  assert.deepEqual(desktop.globalBridgeCalls.map((call) => call.name),
    ['status', 'selectGlobalAll', 'readGlobalHistoryPage']);
  assert.deepEqual(calls.map((call) => call.name), ['readGlobalHistoryPage']);
  assert.equal(lockCalls, 1);
  assert.equal(result.complete, false);
  assert.equal(desktop.globalJournalFS.files.size, 0);
});

test('global envelope 先驗 exact chat scope 才讀 body，不接受 tab 或偽 global scope', async () => {
  for (const scope of [
    { tabName: 'All', chatName: '測試對話', verified: true },
    { kind: 'global', chatName: '測試對話', verified: true },
    { kind: 'chat', chatName: 'Other', verified: true },
    { kind: 'chat', chatName: '測試對話', verified: true, tabName: 'All' },
  ]) {
    let bodyRead = false;
    const page = globalPage({ scope });
    Object.defineProperty(page, 'observations', {
      enumerable: true,
      get() { bodyRead = true; throw new Error('不得讀取錯誤 scope 的 body'); },
    });
    const desktop = desktopWithBridge({ async call() { return page; } });
    await assert.rejects(desktop.call('line_get_chat_history_global',
      { chatName: '測試對話', limit: 5 }, context()), error => error?.code === 'NATIVE_PROTOCOL_ERROR');
    assert.equal(bodyRead, false);
    assert.equal(desktop.cursors.size, 0);
  }
});

test('global cursor 綁 session/chat/date/limit/kind，且 identity namespace 不與 tab history 共用', async () => {
  const identityKeys = { global: [], tab: [] };
  let globalPageNumber = 0;
  const desktop = desktopWithBridge({ async call(name, args) {
    if (name === 'readGlobalHistoryPage') {
      identityKeys.global.push(args.identityKey);
      globalPageNumber += 1;
      return globalPage(globalPageNumber === 1 ? {
        nextState: nativeState(), complete: false, reasons: [], syncState: 'complete',
      } : { complete: true, reasons: [], syncState: 'complete' });
    }
    if (name === 'listTabChats') {
      return {
        tabName: 'Tab', chats: ['測試對話'], snapshotDigest: hex('1'), nextOffset: undefined,
        complete: true, partial: false, reasons: [], ambiguousNames: [],
      };
    }
    assert.equal(name, 'readHistoryPage');
    identityKeys.tab.push(args.identityKey);
    return tabPage();
  } });
  const first = await desktop.call('line_get_chat_history_global',
    { chatName: '測試對話', startDate: '2026-10-29', limit: 5 }, context());
  assert.equal(typeof first.cursor, 'string');

  for (const [callContext, args] of [
    [context('other-session'), { chatName: '測試對話', startDate: '2026-10-29', limit: 5 }],
    [context(), { chatName: 'Other', startDate: '2026-10-29', limit: 5 }],
    [context(), { chatName: '測試對話', startDate: '2026-10-28', limit: 5 }],
    [context(), { chatName: '測試對話', startDate: '2026-10-29', limit: 6 }],
  ]) {
    await assert.rejects(desktop.call('line_get_chat_history_global',
      { ...args, cursor: first.cursor }, callContext), error => error?.code === 'CURSOR_INVALID');
  }
  await assert.rejects(desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: '測試對話', startDate: '2026-10-29', limit: 5, cursor: first.cursor,
  }, context()), error => error?.code === 'CURSOR_INVALID');
  assert.equal(globalPageNumber, 1);

  const second = await desktop.call('line_get_chat_history_global', {
    chatName: '測試對話', startDate: '2026-10-29', limit: 5, cursor: first.cursor,
  }, context());
  assert.equal(second.cursor, null);
  assert.deepEqual(identityKeys.global, [identityKeys.global[0], identityKeys.global[0]]);

  await desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: '測試對話', limit: 5,
  }, context());
  assert.notEqual(identityKeys.global[0], identityKeys.tab[0]);
});

test('global 參數與 unsafe cursor state 在 native 前 fail closed', async () => {
  let calls = 0;
  const desktop = desktopWithBridge({ async call() { calls += 1; return globalPage(); } });
  for (const args of [
    { chatName: '測試對話', tabName: 'All' },
    { chatName: '測試對話', startDate: '' },
    { chatName: '測試對話', endDate: '2026-02-30' },
    { chatName: '測試對話', startDate: '2026-10-30', endDate: '2026-10-29' },
  ]) {
    await assert.rejects(desktop.call('line_get_chat_history_global', args, context()),
      error => error?.code === 'INVALID_ARGUMENT');
  }
  desktop.cursors.set('unsafe', {
    kind: 'globalHistoryPage', sessionId: 'global-test', tabName: null, chatName: '測試對話',
    query: null, startDate: null, endDate: null, limit: 5,
    normalizationVersion: 'nfkc-js-lower-v1', bootNonce: 'synthetic-global-history-test',
    expiresAt: 2_000, nativeState: { provider: 'export', state: {} }, historyEvidence: {},
  });
  await assert.rejects(desktop.call('line_get_chat_history_global',
    { chatName: '測試對話', limit: 5, cursor: 'unsafe' }, context()),
  error => error?.code === 'CURSOR_INVALID');
  assert.equal(calls, 0);
});

test('global 日期篩選排除 unknown 並累積限制，不呼叫 export provider', async () => {
  let exportCalls = 0;
  const desktop = desktopWithBridge({ async call() {
    return globalPage({
      observations: [
        {
          observedId: hex('e'), text: '範圍內', date: '2026-10-29', dateVerified: true,
          unit: 'message', provenance: { source: 'AX_ROW_VALUE', complete: true }, identityVerified: true,
        },
        {
          observedId: hex('f'), text: '未知日期', date: null, dateVerified: false,
          unit: 'message', provenance: { source: 'AX_ROW_VALUE', complete: true }, identityVerified: true,
        },
      ],
      nextState: nativeState(), complete: false, reasons: [], syncState: 'complete',
    });
  } }, { exportReader: { recoveryLatch: null, async readPage() { exportCalls += 1; } } });
  const result = await desktop.call('line_get_chat_history_global', {
    chatName: '測試對話', startDate: '2026-10-29', endDate: '2026-10-29', limit: 5,
  }, context());
  assert.deepEqual(result.observations.map(item => item.text), ['範圍內']);
  assert.equal(result.excludedUnknownDateCount, 1);
  assert(result.reasons.includes('UNKNOWN_DATE_EXCLUDED'));
  assert.equal(exportCalls, 0);
});

test('global envelope 拒絕 NATIVE_TEXT_EXPORT provenance', async () => {
  const desktop = desktopWithBridge({ async call() {
    return globalPage({
      observations: [{
        observedId: hex('e'), text: 'export text', date: null, dateVerified: false,
        unit: 'text_block', provenance: { source: 'NATIVE_TEXT_EXPORT', complete: false },
        identityVerified: false,
      }],
      possibleDuplicates: true,
    });
  } });
  await assert.rejects(desktop.call('line_get_chat_history_global',
    { chatName: '測試對話', limit: 5 }, context()), error => error?.code === 'NATIVE_PROTOCOL_ERROR');
  assert.equal(desktop.cursors.size, 0);
});

test('recovery latch 與 export latch 都在 cursor/native 前阻擋 global 讀取', async () => {
  for (const mode of ['journal', 'export']) {
    let calls = 0;
    const exportReader = mode === 'export' ? { recoveryLatch: { pending: true } } : null;
    const desktop = desktopWithBridge({ async call() { calls += 1; return globalPage(); } }, { exportReader });
    if (mode === 'journal') desktop.recoveryLatch = { pending: true };
    await assert.rejects(desktop.call('line_get_chat_history_global',
      { chatName: '測試對話', limit: 5 }, context()), error => error?.code === 'NEEDS_RECOVERY');
    assert.equal(calls, 0);
    assert.equal(desktop.cursors.size, 0);
  }
});

test('journal 未完成 create/checkpoint durability 時 selector 與 body 都是零呼叫', async (t) => {
  for (const failAt of ['open', 'write', 'sync', 'close', 'dirsync', 'rename', 'chmod']) {
    await t.test(failAt, async () => {
      let bodyCalls = 0;
      const desktop = desktopWithBridge({ async call() { bodyCalls += 1; return globalPage(); } }, {
        fileSystem: memoryJournalFS({ failAt }),
      });
      await assert.rejects(desktop.call('line_get_chat_history_global',
        { chatName: '測試對話', limit: 5 }, context()));
      assert.deepEqual(desktop.globalBridgeCalls.map(({ name }) => name), ['status']);
      assert.equal(bodyCalls, 0);
    });
  }
});

test('錯誤 receipt 與 timeout 保留 pending，fresh instance 在 status 前停止且 journal 無聊天室明文', async (t) => {
  for (const mode of ['wrong-receipt', 'wrong-error-receipt', 'timeout']) {
    await t.test(mode, async () => {
      const fileSystem = memoryJournalFS();
      const bridge = {
        async call() { throw new Error('不得讀 body'); },
        async selectedSourceDigest() {
          return { sourceDigest: hex('9'), sourceDigestVerified: true };
        },
      };
      const desktop = desktopWithBridge(bridge, {
        fileSystem,
        selectGlobalAll(args) {
          if (mode === 'timeout') throw new AutomationError('NATIVE_TIMEOUT', 'synthetic timeout');
          if (mode === 'wrong-error-receipt') {
            throw new AutomationError('POST_EVENT_GUARD_FAILED', 'synthetic wrong receipt', {
              allNavigation: globalNavigationReceipt(args, {
                requestNonce: hex('c'),
                mainWindow: null,
                allSelected: false,
                phase: 'pre_input',
                identityVerified: false,
              }),
            });
          }
          return globalNavigationReceipt(args, { requestNonce: hex('c') });
        },
      });
      await assert.rejects(desktop.call('line_get_chat_history_global',
        { chatName: '測試對話', limit: 5 }, context()), error => error?.code === 'OPERATION_UNCERTAIN');
      assert.deepEqual(desktop.globalBridgeCalls.map(({ name }) => name), ['status', 'selectGlobalAll']);
      const stored = fileSystem.readJson('/synthetic-line-mcp/pending-operation.json');
      assert.equal(stored.navigation.sourceDigest, hex('9'));
      assert.equal(JSON.stringify(stored).includes('測試對話'), false);

      const restarted = desktopWithBridge(bridge, { fileSystem });
      await assert.rejects(restarted.call('line_get_chat_history_global',
        { chatName: '測試對話', limit: 5 }, context()), error => error?.code === 'NEEDS_RECOVERY');
      assert.deepEqual(restarted.globalBridgeCalls, []);
    });
  }
});

test('只有 exact pre_input 零事件 native error 可關閉自己的 journal，且仍不讀 body', async () => {
  const fileSystem = memoryJournalFS();
  let bodyCalls = 0;
  const desktop = desktopWithBridge({ async call() { bodyCalls += 1; return globalPage(); } }, {
    fileSystem,
    selectGlobalAll(args) {
      throw new AutomationError('POST_EVENT_GUARD_FAILED', 'synthetic known-zero failure', {
        allNavigation: globalNavigationReceipt(args, {
          mainWindow: null,
          allSelected: false,
          inputAttempted: false,
          eventCounts: { move: 0, down: 0, up: 0 },
          phase: 'pre_input',
          identityVerified: false,
        }),
      });
    },
  });
  await assert.rejects(desktop.call('line_get_chat_history_global',
    { chatName: '測試對話', limit: 5 }, context()), error => error?.code === 'POST_EVENT_GUARD_FAILED');
  assert.equal(bodyCalls, 0);
  assert.equal(fileSystem.files.size, 0);
});

test('scope、nonce、window 與 event receipt 任一不符都不能解鎖 body', async (t) => {
  const otherWindow = {
    ...syntheticValidLINEWindow,
    windowId: syntheticValidLINEWindow.windowId + 1,
  };
  const cases = {
    route: { route: 'line-system-events-all-v1' },
    scope: { scope: { kind: 'all-navigation', chatName: 'Other' } },
    nonce: { requestNonce: hex('d') },
    expectedWindow: { expectedWindow: otherWindow },
    mainWindow: { mainWindow: otherWindow },
    counts: { inputAttempted: true, eventCounts: { move: 1, down: 1, up: 0 } },
    ordering: { inputAttempted: true, eventCounts: { move: 0, down: 1, up: 1 }, phase: 'post_input' },
    preInput: { inputAttempted: true, eventCounts: { move: 1, down: 0, up: 0 }, phase: 'pre_input' },
    invocations: { systemEventsInvocations: 2 },
    inputMismatch: { inputAttempted: true, systemEventsInvocations: 0 },
    phase: { phase: 'post_input' },
  };
  for (const [name, overrides] of Object.entries(cases)) {
    await t.test(name, async () => {
      let bodyCalls = 0;
      const desktop = desktopWithBridge({ async call() { bodyCalls += 1; return globalPage(); } }, {
        selectGlobalAll: args => globalNavigationReceipt(args, overrides),
      });
      await assert.rejects(desktop.call('line_get_chat_history_global',
        { chatName: '測試對話', limit: 5 }, context()), error => error?.code === 'OPERATION_UNCERTAIN');
      assert.equal(bodyCalls, 0);
      assert(desktop.recoveryLatch);
    });
  }
});

test('selector strict success 後若 clear 失敗仍保留 latch 且不讀 body', async () => {
  let bodyCalls = 0;
  const desktop = desktopWithBridge({ async call() { bodyCalls += 1; return globalPage(); } }, {
    fileSystem: memoryJournalFS({ failAt: 'unlink' }),
  });
  await assert.rejects(desktop.call('line_get_chat_history_global',
    { chatName: '測試對話', limit: 5 }, context()), error => error?.code === 'OPERATION_UNCERTAIN');
  assert.equal(bodyCalls, 0);
  assert(desktop.recoveryLatch);
});

test('HID move/down/up 各一次且 System Events 零次的 verified receipt 才能接續 body', async () => {
  let bodyCalls = 0;
  const desktop = desktopWithBridge({ async call() { bodyCalls += 1; return globalPage(); } }, {
    selectGlobalAll: args => globalNavigationReceipt(args, {
      inputAttempted: true,
      eventCounts: { move: 1, down: 1, up: 1 },
      systemEventsInvocations: 0,
    }),
  });
  await desktop.call('line_get_chat_history_global', { chatName: '測試對話', limit: 5 }, context());
  assert.equal(bodyCalls, 1);
  assert.equal(desktop.globalJournalFS.files.size, 0);
});

test('status 未就緒與 cursor window drift 都在 selector 前停止', async () => {
  const unavailable = desktopWithBridge({ async call() { throw new Error('不得讀 body'); } }, {
    status: {
      running: true, accessibilityTrusted: true, foreground: false, usable: true,
      mainWindow: syntheticValidLINEWindow,
    },
  });
  await assert.rejects(unavailable.call('line_get_chat_history_global',
    { chatName: '測試對話', limit: 5 }, context()), error => error?.code === 'LINE_NOT_READY');
  assert.deepEqual(unavailable.globalBridgeCalls.map(({ name }) => name), ['status']);

  let currentWindow = syntheticValidLINEWindow;
  let page = 0;
  const drifted = desktopWithBridge({ async call() {
    page += 1;
    return globalPage({ nextState: page === 1 ? nativeState() : null });
  } }, {
    status: () => ({
      running: true, accessibilityTrusted: true, foreground: true, usable: true,
      mainWindow: currentWindow,
    }),
  });
  const first = await drifted.call('line_get_chat_history_global',
    { chatName: '測試對話', limit: 5 }, context());
  currentWindow = { ...syntheticValidLINEWindow, windowId: syntheticValidLINEWindow.windowId + 1 };
  const priorCalls = drifted.globalBridgeCalls.length;
  await assert.rejects(drifted.call('line_get_chat_history_global',
    { chatName: '測試對話', limit: 5, cursor: first.cursor }, context()),
  error => error?.code === 'CURSOR_INVALID');
  assert.deepEqual(drifted.globalBridgeCalls.slice(priorCalls).map(({ name }) => name), ['status']);
});
