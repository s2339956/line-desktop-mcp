import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { parseDesktopArgs, checkDesktop } from '../scripts/check-desktop.mjs';
import { AutomationError } from '../src/automation/automation-error.js';
import { WindowsLineAutomation } from '../src/automation/windows-line-automation.js';

function nativeFailureMessages(code) {
  const source = fs.readFileSync(new URL('../src/automation/line-desktop-native.swift', import.meta.url), 'utf8');
  const pattern = new RegExp(`NativeFailure\\(\\s*"${code}"\\s*,\\s*"([^"]+)"`, 'g');
  return [...new Set([...source.matchAll(pattern)].map(match => match[1]))].sort();
}

function cliCauseEntries(mapName) {
  const source = fs.readFileSync(new URL('../scripts/check-desktop.mjs', import.meta.url), 'utf8');
  const block = source.match(new RegExp(`const ${mapName} = new Map\\(\\[([\\s\\S]*?)\\n\\]\\);`));
  assert(block, `${mapName} 必須存在`);
  return [...block[1].matchAll(/\['([^']+)', '([A-Z0-9_]+)'\]/g)]
    .map(match => [match[1], match[2]]);
}

test('live runner 必須明確指定 exact fixture，不接受多餘或重複參數', () => {
  assert.deepEqual(parseDesktopArgs([]), { read: false, page: false, ax: false, tabName: null, chatName: null,
    resultIndex: null });
  assert.deepEqual(parseDesktopArgs(['--read', '--tab', 'Test tab', '--chat', 'Test chat']),
    { read: true, page: false, ax: false, tabName: 'Test tab', chatName: 'Test chat', resultIndex: null });
  assert.deepEqual(parseDesktopArgs(['--read', '--page', '--tab', 'Test tab', '--chat', 'Test chat']),
    { read: true, page: true, ax: false, tabName: 'Test tab', chatName: 'Test chat', resultIndex: null });
  for (const args of [ ['--read'], ['--tab', 'Test tab'], ['--send'],
    ['--page', '--tab', 'Test tab', '--chat', 'Test chat'],
    ['--read', '--tab', 'a', '--tab', 'b', '--chat', 'c'], ['--read', '--chat', '\u202e'] ]) {
    assert.throws(() => parseDesktopArgs(args));
  }
});

test('page mode 建立正式 MCP session，只回 metadata 且最多啟用一次', async () => {
  const calls = [];
  let activations = 0;
  const result = await checkDesktop(parseDesktopArgs([
    '--read', '--page', '--tab', 'Test tab', '--chat', 'Test chat',
  ]), bridge => {
    assert.deepEqual(bridge.liveScope, { tabName: 'Test tab', chatName: 'Test chat' });
    return {
      async activateLine() { activations++; return { success: true }; },
      async call(name, args, context) {
        calls.push({ name, args, context });
        if (name === 'line_desktop_status') return { usable: true, foreground: false };
        if (name === 'line_get_chat_history_page') return {
          scope: { tabName: 'Test tab', chatName: 'Test chat', verified: true },
          observations: [{
            observedId: 'b'.repeat(64), text: 'PRIVATE_CANARY', date: '2026-10-24',
            dateVerified: true, unit: 'message', identityVerified: true,
            provenance: { source: 'AX_ROW_VALUE', complete: true },
          }],
          observedAt: '2026-10-24T01:02:03Z', snapshotDigest: 'c'.repeat(64),
          cursor: null, complete: true, reasons: [], syncState: 'complete',
          truncated: false, possibleDuplicates: false,
          excludedUnknownDateCount: 0, mayAffectReadState: true,
        };
        throw new Error(`unexpected ${name}`);
      },
    };
  });
  assert.equal(activations, 1);
  assert.deepEqual(calls.map(call => call.name), ['line_desktop_status', 'line_get_chat_history_page']);
  assert.deepEqual(calls[1].args, { tabName: 'Test tab', chatName: 'Test chat', limit: 5 });
  assert(calls.every(call => call.context.sessionId === calls[0].context.sessionId));
  assert.equal(result.mode, 'mcp-history-page');
  assert.equal(result.count, 1);
  assert.equal(result.hasCursor, false);
  assert.equal(result.metadata.sourceDigest, null);
  assert.equal(result.metadata.sourceDigestVerified, false);
  assert(!JSON.stringify(result).includes('PRIVATE_CANARY'));
});

test('page mode 將正式 MCP isError 轉成 typed code，不洩漏 native 內容', async () => {
  await assert.rejects(checkDesktop({
    read: true, page: true, tabName: 'Test tab', chatName: 'Test chat',
  }, () => ({
    async call(name) {
      if (name === 'line_desktop_status') return { usable: true, foreground: true };
      throw Object.assign(new Error('PRIVATE_NATIVE_CANARY'), { code: 'SCOPE_NOT_VERIFIED' });
    },
  })), error => error.code === 'SCOPE_NOT_VERIFIED' && !error.message.includes('PRIVATE_NATIVE_CANARY'));
});

test('page mode 只保留 code-scoped 已知分類，未知／跨 code／incoming details 不流出', async () => {
  const inspect = (code, message) => checkDesktop({
    read: true, page: true, tabName: 'Test tab', chatName: 'Test chat',
  }, () => ({ async call(name) {
    if (name === 'line_desktop_status') return { usable: true, foreground: true };
    // 模擬NativeBridge受控錯誤；一般Error現在須遮蔽訊息，不再冒充原生語意。
    throw new AutomationError(code, message, { causeCode: 'PRIVATE_DETAIL_CANARY', rawAX: 'PRIVATE_AX_CANARY' });
  } }));
  for (const [code, message, causeCode] of [
    ['SEMANTIC_UNRELIABLE', '無法唯一辨識訊息輸入區', 'LAYOUT_COMPOSER_NOT_UNIQUE'],
    ['TAB_SELECTION_UNVERIFIED', '目標分頁缺少唯一且相對應的 selected underline',
      'TAB_TARGET_UNDERLINE_UNVERIFIED'],
  ]) await assert.rejects(inspect(code, message), error => error.code === code &&
    error.details?.causeCode === causeCode && !JSON.stringify(error).includes('PRIVATE_') &&
    !error.message.includes(message));
  for (const [code, message] of [
    ['SEMANTIC_UNRELIABLE', 'PRIVATE_NATIVE_CANARY'],
    ['TAB_SELECTION_UNVERIFIED', 'PRIVATE_NATIVE_CANARY'],
    ['SEMANTIC_UNRELIABLE', '目標分頁缺少唯一且相對應的 selected underline'],
    ['TAB_SELECTION_UNVERIFIED', '無法唯一辨識訊息輸入區'],
  ]) await assert.rejects(inspect(code, message), error => error.code === code &&
    error.details === undefined && !error.message.includes(message));
});

test('CLI 固定 cause Map 精確涵蓋 Swift 的兩種固定錯誤 literal', () => {
  for (const [code, mapName] of [
    ['SEMANTIC_UNRELIABLE', 'SEMANTIC_CAUSE_BY_MESSAGE'],
    ['TAB_SELECTION_UNVERIFIED', 'TAB_SELECTION_CAUSE_BY_MESSAGE'],
  ]) {
    const entries = cliCauseEntries(mapName);
    const causeCodes = entries.map(([, causeCode]) => causeCode);
    assert.deepEqual(entries.map(([message]) => message).sort(), nativeFailureMessages(code));
    assert.equal(new Set(causeCodes).size, causeCodes.length);
    assert(causeCodes.every(causeCode => /^[A-Z0-9_]{1,64}$/.test(causeCode)));
  }
});

test('live runner status-only 不讀聊天；不可用主窗不繼續 select', async () => {
  let reads = 0;
  const factory = bridge => {
    assert(Object.isFrozen(bridge.liveScope));
    return { async call() { return { usable: false }; }, async legacyHistory() { reads++; } };
  };
  assert.equal((await checkDesktop(parseDesktopArgs([]), factory)).mode, 'status');
  const result = await checkDesktop(parseDesktopArgs(['--read', '--tab', 'Test tab', '--chat', 'Test chat']), factory);
  assert.equal(result.complete, false);
  assert.equal(reads, 0);
});

test('live runner 只回證據 metadata，不回私人內容', async () => {
  const result = await checkDesktop({ read: true, tabName: 'Test tab', chatName: 'Test chat' }, bridge => {
    assert.deepEqual(bridge.liveScope, { tabName: 'Test tab', chatName: 'Test chat' });
    return {
      async call() { return { usable: true }; },
      async legacyHistory(name, date, limit, pages) {
        assert.deepEqual([name, date, limit, pages], ['Test chat', undefined, 5, 0]);
        return { history: 'PRIVATE_CANARY', metadata: { complete: false, mayAffectReadState: true } };
      },
    };
  });
  assert.equal(result.historyCharacters, 14);
  assert.equal(result.writeToolsEnabled, false);
  assert.equal(result.metadata.mayAffectReadState, true);
  assert(!JSON.stringify(result).includes('PRIVATE_CANARY'));
});

test('授權讀取僅起點啟用一次，途中失焦失敗不能反覆搶回前景', async () => {
  let activations = 0;
  let reads = 0;
  await assert.rejects(checkDesktop({ read: true, tabName: 'Test tab', chatName: 'Test chat' }, () => ({
    async call() { return { usable: true, foreground: false }; },
    async activateLine() { activations++; return { success: true }; },
    async legacyHistory() { reads++; throw Object.assign(new Error('focus lost'), { code: 'FOREGROUND_REQUIRED' }); },
  })), error => error.code === 'FOREGROUND_REQUIRED');
  assert.equal(activations, 1);
  assert.equal(reads, 1);
});

test('Windows 相容路徑不能以行數冒充訊息數而截掉多行歷史', async () => {
  const adapter = new WindowsLineAutomation({ lock: { withLock: work => work() } });
  adapter.switchToEnglish = async () => {};
  adapter.activateLine = async () => ({ success: true });
  adapter.selectChat = async () => true;
  adapter.pageUp = async () => {};
  adapter.copyAllChatToClipboard = async () => 'multi\nline\nmessage';
  const result = await adapter.getChatHistoryResult('Test chat', undefined, 1, 0);
  assert.equal(result.history, 'multi\nline\nmessage');
  assert.equal(result.metadata.messageLimitApplied, false);
});

function axProbeFixture(overrides = {}) {
  return {
    scope: { tabName: 'Test tab', chatName: 'Test chat' },
    axTabGroupCount: 1, axTabCount: 3, axTargetTabMatchCount: 1,
    axObjectsWithNameCount: 3, axObjectsWithStateCount: 3, axObjectsWithIdentifierCount: 2,
    axTargetTabSelected: true, axTargetTabIdentifierPresent: true,
    axTabInventoryCalibrated: false, axRowCount: null,
    axTargetRowNameMatchCount: null, axHeaderTitleRelationAvailable: false,
    axHeaderNameMatches: null, axSaveChatActionCount: 0,
    requiresCalibration: true, bodyReadAttempted: false, ocrUsed: false, uiEvents: 0,
    ...overrides,
  };
}

function fakeAXCheck(raw, calls) {
  return checkDesktop(parseDesktopArgs(['--ax', '--tab', 'Test tab', '--chat', 'Test chat']),
    () => ({
      lock: { async withLock(work) { calls.push('lock'); return work(); } },
      async activateLine() { throw new Error('AX metadata mode 不得啟用 LINE'); },
    }), options => {
      assert.deepEqual(options.liveScope, { tabName: 'Test tab', chatName: 'Test chat' });
      return {
        async call(name, args) {
          calls.push(name);
          assert.deepEqual(args, options.liveScope);
          if (raw instanceof Error) throw raw;
          return raw;
        },
        async selectedSourceDigest() { return { sourceDigest: null, sourceDigestVerified: false }; },
      };
    });
}

test('AX mode 必須 exact scope 且不混用訊息讀取', () => {
  assert.deepEqual(parseDesktopArgs(['--ax', '--tab', 'Test tab', '--chat', 'Test chat']),
    { read: false, page: false, ax: true, tabName: 'Test tab', chatName: 'Test chat', resultIndex: null });
  for (const args of [['--ax'], ['--ax', '--read', '--tab', 'a', '--chat', 'b'],
    ['--ax', '--page', '--tab', 'a', '--chat', 'b']]) assert.throws(() => parseDesktopArgs(args));
});

test('AX probe 同一lock、零自動啟用、只投影安全metadata', async () => {
  const calls = [];
  const result = await fakeAXCheck(axProbeFixture({ unknownTitle: 'PRIVATE_AX_CANARY', body: 'PRIVATE_BODY_CANARY' }), calls);
  assert.deepEqual(calls, ['lock', 'probeAXReadScope']);
  assert.equal(result.mode, 'ax-capabilities');
  assert.equal(result.probe.axTargetTabSelected, true);
  assert.equal(result.probe.axObjectsWithNameCount, 3);
  assert.equal(result.probe.axObjectsWithStateCount, 3);
  assert.equal(result.probe.axObjectsWithIdentifierCount, 2);
  assert.equal(result.probe.axRowCount, null);
  assert.equal(result.probe.axTabInventoryCalibrated, false);
  assert.equal(result.bodyReadAttempted, false);
  assert.equal(result.uiEvents, 0);
  assert(!JSON.stringify(result).includes('PRIVATE_'));
});

test('AX probe scope、型別及零內容／零事件保證不符即拒', async () => {
  for (const overrides of [
    { scope: { tabName: 'Other', chatName: 'Test chat' } },
    { axTargetTabSelected: 'PRIVATE_AX_CANARY' }, { axTabCount: -1 },
    { axObjectsWithNameCount: 'PRIVATE_AX_CANARY' },
    { axRowCount: 'PRIVATE_BODY_CANARY' }, { axHeaderNameMatches: 1 },
    { bodyReadAttempted: true }, { ocrUsed: true }, { uiEvents: 1 },
  ]) {
    await assert.rejects(fakeAXCheck(axProbeFixture(overrides), []),
      e => e.code === 'NATIVE_PROTOCOL_ERROR' && !e.message.includes('PRIVATE_'));
  }
});

test('AX probe 失焦立即傳回typed拒絕，不自動搶回前景', async () => {
  const calls = [];
  await assert.rejects(fakeAXCheck(Object.assign(new Error('失焦'), { code: 'FOREGROUND_REQUIRED' }), calls),
    e => e.code === 'FOREGROUND_REQUIRED');
  assert.deepEqual(calls, ['lock', 'probeAXReadScope']);
});

test('global page runner 明確指定測試對話且拒絕與自訂分頁混用', () => {
  const parsed = parseDesktopArgs(['--global', '--read', '--page', '--chat', '測試對話']);
  assert.equal(parsed.global, true);
  assert.equal(parsed.tabName, null);
  assert.equal(parsed.chatName, '測試對話');
  assert.equal(parsed.resultIndex, null);
  const indexed = parseDesktopArgs([
    '--global', '--read', '--page', '--chat', '測試對話', '--result-index', '2',
  ]);
  assert.equal(indexed.resultIndex, 2);
  for (const args of [
    ['--global', '--read', '--chat', '測試對話'],
    ['--global', '--read', '--page', '--tab', '全部', '--chat', '測試對話'],
    ['--global', '--ax', '--chat', '測試對話'],
    ['--global', '--global', '--read', '--page', '--chat', '測試對話'],
    ['--read', '--page', '--tab', '全部', '--chat', '測試對話', '--result-index', '1'],
    ['--global', '--read', '--page', '--chat', '測試對話', '--result-index', '0'],
    ['--global', '--read', '--page', '--chat', '測試對話', '--result-index', '21'],
  ]) assert.throws(() => parseDesktopArgs(args));
});

test('indexed global runner 將 resultIndex 同時綁定 liveScope 與 tool args', async () => {
  const result = await checkDesktop(parseDesktopArgs([
    '--global', '--read', '--page', '--chat', '測試對話', '--result-index', '2',
  ]), bridge => {
    assert.deepEqual(bridge.liveScope, { kind: 'global', chatName: '測試對話', resultIndex: 2 });
    return { async call(name, args) {
      if (name === 'line_desktop_status') return { usable: true, foreground: true };
      assert.equal(name, 'line_get_chat_history_global');
      assert.deepEqual(args, { chatName: '測試對話', resultIndex: 2, limit: 5 });
      return { scope: { kind: 'search_result', chatName: '測試對話', resultIndex: 2, verified: true },
        observations: [], cursor: null, complete: false, reasons: ['VISIBLE_VIEWPORT_ONLY'],
        syncState: 'unknown', truncated: false, possibleDuplicates: true,
        excludedUnknownDateCount: 0, mayAffectReadState: true };
    } };
  });
  assert.deepEqual(result.fixture, { kind: 'global', chatName: '測試對話', resultIndex: 2 });
});

test('global page runner 只走測試對話全域工具，輸出不包含正文', async () => {
  const calls = [];
  let activationCount = 0;
  const result = await checkDesktop(parseDesktopArgs([
    '--global', '--read', '--page', '--chat', '測試對話',
  ]), bridge => {
    assert.deepEqual(bridge.liveScope, { kind: 'global', chatName: '測試對話' });
    return {
      async activateLine() { activationCount++; return { success: true }; },
      async call(name, args) {
        calls.push({ name, args });
        if (name === 'line_desktop_status') return { usable: true, foreground: false };
        assert.equal(name, 'line_get_chat_history_global');
        assert.deepEqual(args, { chatName: '測試對話', limit: 5 });
        return { scope: { kind: 'global', chatName: '測試對話', verified: true },
          observations: [{ text: 'PRIVATE_GLOBAL_CANARY' }], cursor: null,
          complete: false, reasons: ['BODY_PROVENANCE_PARTIAL'], syncState: 'unknown',
          truncated: false, possibleDuplicates: true, excludedUnknownDateCount: 0,
          mayAffectReadState: true };
      },
    };
  });
  assert.equal(activationCount, 1);
  assert.equal(result.count, 1);
  assert.deepEqual(result.fixture, { kind: 'global', chatName: '測試對話' });
  assert.deepEqual(calls.map(c => c.name), ['line_desktop_status', 'line_get_chat_history_global']);
  assert.equal(JSON.stringify(result).includes('PRIVATE_GLOBAL_CANARY'), false);
});

test('直接注入的 global 混用參數，在建立 bridge 前就停止', async () => {
  let bridgeCreations = 0;
  for (const options of [
    { global: true, read: false, page: true, chatName: '測試對話' },
    { global: true, read: true, page: true, tabName: '全部', chatName: '測試對話' },
    { global: true, read: true, page: true, chatName: '測試對話', ax: true },
    { global: 'true', read: true, page: true, chatName: '測試對話' },
  ]) await assert.rejects(checkDesktop(options, undefined, () => { bridgeCreations++; }));
  assert.equal(bridgeCreations, 0);
});
