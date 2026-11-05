import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { MacOSDesktopAutomation } from '../src/automation/desktop-automation.js';
import { NativeBridge } from '../src/automation/native-bridge.js';

const context = (sessionId = 'session-a') => ({ transport: 'stdio', sessionId });
const hex = (character) => character.repeat(64);
const expectedWindow = {
  pid: 123,
  windowId: 88,
  title: 'LINE',
  bounds: { x: -10, y: 20, width: 900, height: 700 },
  bundleIdentifier: 'jp.naver.line.mac',
  executableURL: '/Applications/LINE.app/Contents/MacOS/LINE',
};

class FakeBridge {
  constructor(handler) {
    this.handler = handler;
    this.calls = [];
  }

  async call(name, args = {}) {
    this.calls.push({ name, args });
    return this.handler(name, args, this.calls);
  }
}

class CountingLock {
  constructor() {
    this.depth = 0;
    this.calls = 0;
  }

  async withLock(work) {
    assert.equal(this.depth, 0, '不得巢狀取得 public UI lock');
    this.calls += 1;
    this.depth += 1;
    try {
      return await work();
    } finally {
      this.depth -= 1;
    }
  }
}

function deterministicRandom() {
  let value = 0;
  return (length) => Buffer.alloc(length, ++value);
}

function inventory(chats = ['A'], overrides = {}) {
  return {
    tabName: 'Tab',
    chats,
    snapshotDigest: hex('1'),
    complete: true,
    partial: false,
    reasons: [],
    ambiguousNames: [],
    ...overrides,
  };
}

function nativeState(overrides = {}) {
  return {
    version: 1,
    expectedWindow,
    headerDigest: hex('2'),
    anchorHash: hex('3'),
    offset: 0,
    pageNumber: 0,
    advance: false,
    seenIds: [],
    dateContext: null,
    ...overrides,
  };
}

function observation(id, text, overrides = {}) {
  return {
    observedId: hex(id),
    text,
    date: '2026-10-24',
    dateVerified: true,
    unit: 'message',
    provenance: { source: 'AX_ROW_VALUE', complete: true },
    identityVerified: true,
    ...overrides,
  };
}

function historyPage(tabName, chatName, overrides = {}) {
  return {
    scope: { tabName, chatName, verified: true },
    observations: [],
    observedAt: '2026-10-24T12:00:00Z',
    snapshotDigest: hex('4'),
    nextState: null,
    complete: true,
    reasons: [],
    syncState: 'complete',
    truncated: false,
    possibleDuplicates: false,
    ...overrides,
  };
}

function desktopWith(bridge, options = {}) {
  const lock = options.lock || new CountingLock();
  return {
    lock,
    desktop: new MacOSDesktopAutomation({
      bridge,
      lock,
      bootNonce: 'boot-secret-a',
      randomBytes: deterministicRandom(),
      ...options,
    }),
  };
}

function exportPage(tabName, chatName, overrides = {}) {
  return {
    envelope: historyPage(tabName, chatName, {
      observations: [observation('e', 'exported text', {
        date: null, dateVerified: false, unit: 'text_block',
        provenance: { source: 'NATIVE_TEXT_EXPORT', complete: false },
        identityVerified: false,
      })],
      complete: false,
      reasons: ['NATIVE_EXPORT_VISIBLE_ONLY', 'EXPORT_MESSAGE_BOUNDARIES_UNVERIFIED', 'UNKNOWN_DATE'],
      syncState: 'unknown', possibleDuplicates: true,
      ...overrides.envelope,
    }),
    exportState: overrides.exportState ?? null,
  };
}

function errorCode(error) {
  return error?.code;
}

test('P3 runtime validation 拒絕假日曆日期、反向範圍與危險 query，且 legacy 共用真日曆驗證', async () => {
  const bridge = new FakeBridge(() => { throw new Error('native 不應被呼叫'); });
  const { desktop } = desktopWith(bridge);
  const invalid = [
    { tool: 'line_get_chat_history_page', args: { tabName: 'Tab', chatName: 'A', startDate: '2025-02-29' } },
    { tool: 'line_get_chat_history_page', args: { tabName: 'Tab', chatName: 'A', startDate: '2026-10-25', endDate: '2026-10-24' } },
    { tool: 'line_search_tab_messages', args: { tabName: 'Tab', query: '   ' } },
    { tool: 'line_search_tab_messages', args: { tabName: 'Tab', query: 'foo\u202ebar' } },
    { tool: 'line_search_tab_messages', args: { tabName: 'Tab', query: Array.from({ length: 17 }, (_, i) => `t${i}`).join(' ') } },
  ];
  for (const item of invalid) {
    await assert.rejects(desktop.call(item.tool, item.args, context()),
      (error) => errorCode(error) === 'INVALID_ARGUMENT');
  }
  await assert.rejects(desktop.legacyHistory('A', '2026-04-31', 10, 0),
    (error) => errorCode(error) === 'INVALID_ARGUMENT');
  assert.equal(bridge.calls.length, 0);
});

test('history 單一 outer lock 內盤點後讀一個 raw page，嚴格日期排除 unknown 且保留 offset cursor', async () => {
  const state = nativeState({ offset: 2, pageNumber: 0 });
  const identityKeys = [];
  const lock = new CountingLock();
  const bridge = new FakeBridge((name, args) => {
    assert.equal(lock.depth, 1);
    if (name === 'listTabChats') return inventory();
    assert.equal(name, 'readHistoryPage');
    assert.deepEqual(Object.keys(args).sort(),
      (args.nativeState ? ['chatName', 'identityKey', 'limit', 'nativeState', 'tabName'] :
        ['chatName', 'identityKey', 'limit', 'tabName']).sort());
    assert.match(args.identityKey, /^[a-f0-9]{64}$/);
    identityKeys.push(args.identityKey);
    if (!args.nativeState) {
      return historyPage('Tab', 'A', {
        observations: [
          observation('a', '範圍內'),
          observation('b', '未知日期', { date: null, dateVerified: false }),
          observation('c', '範圍外', { date: '2026-10-23' }),
        ],
        nextState: state,
        complete: false,
      });
    }
    assert.equal(args.nativeState.offset, 2);
    return historyPage('Tab', 'A');
  });
  const { desktop } = desktopWith(bridge, { lock });

  const first = await desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: 'A', startDate: '2026-10-24', endDate: '2026-10-24', limit: 3,
  }, context());
  assert.deepEqual(first.observations.map((item) => item.text), ['範圍內']);
  assert.equal(first.excludedUnknownDateCount, 1);
  assert.equal(first.complete, false);
  assert.equal(typeof first.cursor, 'string');
  assert(first.reasons.includes('UNKNOWN_DATE_EXCLUDED'));
  assert.equal(lock.calls, 1);

  state.offset = 999; // caller/native 後續改寫不得污染 server-only cursor。
  const second = await desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: 'A', startDate: '2026-10-24', endDate: '2026-10-24', limit: 3,
    cursor: first.cursor,
  }, context());
  assert.equal(second.complete, false);
  assert.equal(second.cursor, null);
  assert.equal(second.excludedUnknownDateCount, 1);
  assert(second.reasons.includes('UNKNOWN_DATE_EXCLUDED'));
  assert.equal(identityKeys[0], identityKeys[1]);
  await assert.rejects(desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: 'A', startDate: '2026-10-24', endDate: '2026-10-24', limit: 3,
    cursor: first.cursor,
  }, context()), (error) => errorCode(error) === 'CURSOR_INVALID');
});

test('無日期 history 在 inventory gate 後優先 export；日期查詢與明確 pre-action unavailable 保留 native', async () => {
  let nativeReads = 0;
  const bridge = new FakeBridge((name) => {
    if (name === 'listTabChats') return inventory();
    nativeReads += 1;
    return historyPage('Tab', 'A', { observations: [observation('a', 'native')] });
  });
  const calls = [];
  const exportReader = {
    async readPage(args) { calls.push(args); return exportPage(args.tabName, args.chatName); },
  };
  const { desktop } = desktopWith(bridge, { exportReader });
  const exported = await desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: 'A', limit: 2,
  }, context());
  assert.equal(exported.observations[0].text, 'exported text');
  assert.equal(exported.observations[0].provenance.source, 'NATIVE_TEXT_EXPORT');
  assert.equal(exported.complete, false);
  assert.equal(exported.possibleDuplicates, true);
  assert.equal(nativeReads, 0);
  assert.equal(calls.length, 1);

  const dated = await desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: 'A', startDate: '2026-10-24', limit: 2,
  }, context());
  assert.equal(dated.observations[0].text, 'native');
  assert.equal(nativeReads, 1);
  assert.equal(calls.length, 1, '有日期條件不可使用未校準日期的 export');

  exportReader.readPage = async () => null;
  const fallback = await desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: 'A', limit: 2,
  }, context());
  assert.equal(fallback.observations[0].text, 'native');
  assert.equal(nativeReads, 2);
});

test('export continuation 固定 provider/scope 且不重 capture；provider 消失回 CURSOR_INVALID', async () => {
  let captures = 0;
  const bridge = new FakeBridge((name) => {
    if (name === 'listTabChats') return inventory();
    throw new Error('export continuation 不得切回 native');
  });
  const exportReader = {
    async readPage(args) {
      captures += args.state ? 0 : 1;
      return exportPage(args.tabName, args.chatName, {
        exportState: args.state ? null : { snapshotId: hex('e'), snapshotDigest: hex('f'), offset: 1 },
        envelope: {
          observations: [observation(args.state ? '2' : '1', args.state ? 'second' : 'first', {
            date: null, dateVerified: false, unit: 'text_block',
            provenance: { source: 'NATIVE_TEXT_EXPORT', complete: false }, identityVerified: false,
          })],
        },
      });
    },
  };
  const { desktop } = desktopWith(bridge, { exportReader });
  const first = await desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: 'A', limit: 1,
  }, context());
  const second = await desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: 'A', limit: 1, cursor: first.cursor,
  }, context());
  assert.equal(second.observations[0].text, 'second');
  assert.equal(captures, 1);

  const again = await desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: 'A', limit: 1,
  }, context());
  desktop.exportReader = null;
  await assert.rejects(desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: 'A', limit: 1, cursor: again.cursor,
  }, context()), (error) => errorCode(error) === 'CURSOR_INVALID');
});

test('malformed／post-action export 失敗不會洩漏正文或偷偷切回 native', async () => {
  let nativeReads = 0;
  const bridge = new FakeBridge((name) => {
    if (name === 'listTabChats') return inventory();
    nativeReads += 1;
    return historyPage('Tab', 'A');
  });
  const exportReader = {
    async readPage() {
      return exportPage('Other', 'A', {
        envelope: { observations: [observation('e', 'must not escape', {
          date: null, dateVerified: false, unit: 'text_block',
          provenance: { source: 'NATIVE_TEXT_EXPORT', complete: false }, identityVerified: false,
        })] },
      });
    },
  };
  const { desktop } = desktopWith(bridge, { exportReader });
  await assert.rejects(desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: 'A', limit: 1,
  }, context()), (error) => errorCode(error) === 'NATIVE_PROTOCOL_ERROR');
  assert.equal(nativeReads, 0);

  exportReader.readPage = async () => {
    throw Object.assign(new Error('post action unknown'), { code: 'NATIVE_TIMEOUT' });
  };
  await assert.rejects(desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: 'A', limit: 1,
  }, context()), (error) => errorCode(error) === 'NATIVE_TIMEOUT');
  assert.equal(nativeReads, 0);
});

test('export recovery latch 會出現在 status 並阻擋後續 UI 異動', async () => {
  const bridge = new FakeBridge((name) => {
    if (name === 'status') return { running: true, usable: true };
    throw new Error(`unexpected ${name}`);
  });
  const exportReader = { recoveryLatch: { needsRecovery: true } };
  const { desktop } = desktopWith(bridge, { exportReader });
  const status = await desktop.call('line_desktop_status', {}, context());
  assert.equal(status.needsRecovery, true);
  assert.deepEqual(status.recovery, { state: 'pending', valid: false });
  await assert.rejects(desktop.assertNoPendingJournal(),
    (error) => errorCode(error) === 'NEEDS_RECOVERY');
});

test('history cursor 累積前頁 unknown 與限制，正常 terminal page 不得抹除 incomplete 證據', async () => {
  let page = 0;
  const bridge = new FakeBridge((name) => {
    if (name === 'listTabChats') return inventory();
    page += 1;
    if (page === 1) {
      return historyPage('Tab', 'A', {
        observations: [observation('a', '未知日期', { date: null, dateVerified: false })],
        nextState: nativeState(),
        complete: false,
        reasons: ['DATE_CONTEXT_UNVERIFIED'],
        syncState: 'unknown',
        truncated: true,
      });
    }
    return historyPage('Tab', 'A', { observations: [observation('b', '正常 terminal')] });
  });
  const { desktop } = desktopWith(bridge);
  const args = {
    tabName: 'Tab', chatName: 'A', startDate: '2026-10-24', endDate: '2026-10-24', limit: 2,
  };
  const first = await desktop.call('line_get_chat_history_page', args, context());
  assert.equal(first.excludedUnknownDateCount, 1);
  const second = await desktop.call('line_get_chat_history_page', { ...args, cursor: first.cursor }, context());
  assert.equal(second.cursor, null);
  assert.equal(second.complete, false);
  assert.equal(second.excludedUnknownDateCount, 1);
  assert(second.reasons.includes('DATE_CONTEXT_UNVERIFIED'));
  assert(second.reasons.includes('UNKNOWN_DATE_EXCLUDED'));
  assert(second.reasons.includes('TRUNCATED'));
  assert(second.reasons.includes('SYNC_INCOMPLETE'));
});

test('scope mismatch 不回 body；inventory drift 在 body 前失效', async () => {
  let snapshot = hex('1');
  let bodyCalls = 0;
  const bridge = new FakeBridge((name, args) => {
    if (name === 'listTabChats') return inventory(['A'], { snapshotDigest: snapshot });
    bodyCalls += 1;
    if (bodyCalls === 1) {
      return historyPage('Other tab', 'A', { observations: [observation('a', 'secret')] });
    }
    return historyPage('Tab', 'A', { nextState: nativeState(), complete: false });
  });
  const { desktop } = desktopWith(bridge);
  await assert.rejects(desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: 'A', limit: 1,
  }, context()), (error) => errorCode(error) === 'NATIVE_PROTOCOL_ERROR');

  const page = await desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: 'A', limit: 1,
  }, context());
  snapshot = hex('9');
  await assert.rejects(desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: 'A', limit: 1, cursor: page.cursor,
  }, context()), (error) => errorCode(error) === 'CURSOR_INVALID');
  assert.equal(bodyCalls, 2, 'inventory 漂移時不可再讀第二個 body page');
});

test('search 使用 nfkc-js-lower-v1 literal AND，跨 member 累積進度且同文不同 ID 不去重', async () => {
  const readChats = [];
  const bridge = new FakeBridge((name, args) => {
    if (name === 'listTabChats') return inventory(['A', 'B']);
    readChats.push(args.chatName);
    assert.equal('query' in args, false, 'query 不得傳給 native');
    if (args.chatName === 'A') {
      return historyPage('Tab', 'A', {
        observations: [observation('a', 'foo bar'), observation('b', 'FOO BAR')],
      });
    }
    return historyPage('Tab', 'B', { observations: [observation('c', '沒有命中')] });
  });
  const { desktop } = desktopWith(bridge);
  const first = await desktop.call('line_search_tab_messages', {
    tabName: 'Tab', query: 'ＦＯＯ\u3000bar', limit: 10,
  }, context());
  assert.deepEqual(first.matches.map((item) => item.observedId), [hex('a'), hex('b')]);
  assert(first.matches.every((item) => item.chatName === 'A'));
  assert.equal(first.complete, false);
  assert.equal(typeof first.cursor, 'string');
  assert.deepEqual(first.progress, {
    inventoryObserved: 2,
    totalIfKnown: 2,
    currentChat: 'A',
    scannedObservationCount: 2,
    returnedMatchCount: 2,
  });

  const second = await desktop.call('line_search_tab_messages', {
    tabName: 'Tab', query: 'ＦＯＯ\u3000bar', limit: 10, cursor: first.cursor,
  }, context());
  assert.deepEqual(second.matches, []);
  assert.equal(second.cursor, null);
  assert.equal(second.complete, true);
  assert.equal(second.progress.scannedObservationCount, 3);
  assert.equal(second.progress.returnedMatchCount, 2);
  assert.deepEqual(readChats, ['A', 'B']);
});

test('無日期 search 使用 export text_block，日期條件仍保留 native verified date', async () => {
  let exportCalls = 0;
  let nativeCalls = 0;
  const bridge = new FakeBridge((name) => {
    if (name === 'listTabChats') return inventory();
    nativeCalls += 1;
    return historyPage('Tab', 'A', { observations: [observation('a', 'needle native')] });
  });
  const exportReader = {
    async readPage(args) {
      exportCalls += 1;
      return exportPage(args.tabName, args.chatName, {
        envelope: { observations: [observation('e', 'needle export', {
          date: null, dateVerified: false, unit: 'text_block',
          provenance: { source: 'NATIVE_TEXT_EXPORT', complete: false }, identityVerified: false,
        })] },
      });
    },
  };
  const { desktop } = desktopWith(bridge, { exportReader });
  const exported = await desktop.call('line_search_tab_messages', {
    tabName: 'Tab', query: 'needle', limit: 5,
  }, context());
  assert.equal(exported.matches[0].text, 'needle export');
  assert.equal(exportCalls, 1);
  assert.equal(nativeCalls, 0);

  const dated = await desktop.call('line_search_tab_messages', {
    tabName: 'Tab', query: 'needle', startDate: '2026-10-24', limit: 5,
  }, context());
  assert.equal(dated.matches[0].text, 'needle native');
  assert.equal(exportCalls, 1);
  assert.equal(nativeCalls, 1);
});

test('search cursor 累積前頁 sync/truncated/duplicate 狀態，正常 terminal page 不得清除限制', async () => {
  let page = 0;
  const bridge = new FakeBridge((name) => {
    if (name === 'listTabChats') return inventory();
    page += 1;
    if (page === 1) {
      return historyPage('Tab', 'A', {
        observations: [observation('a', 'needle')],
        nextState: nativeState(),
        complete: false,
        reasons: ['OVERLAP_UNCERTAIN'],
        syncState: 'unknown',
        truncated: true,
        possibleDuplicates: true,
      });
    }
    return historyPage('Tab', 'A', { observations: [observation('b', 'needle')] });
  });
  const { desktop } = desktopWith(bridge);
  const args = { tabName: 'Tab', query: 'needle', limit: 2 };
  const first = await desktop.call('line_search_tab_messages', args, context());
  const second = await desktop.call('line_search_tab_messages', { ...args, cursor: first.cursor }, context());
  assert.equal(second.cursor, null);
  assert.equal(second.complete, false);
  assert.equal(second.syncState, 'unknown');
  assert.equal(second.truncated, true);
  assert.equal(second.possibleDuplicates, true);
  assert(second.reasons.includes('OVERLAP_UNCERTAIN'));
  assert(second.reasons.includes('SYNC_INCOMPLETE'));
  assert(second.reasons.includes('TRUNCATED'));
  assert(second.reasons.includes('POSSIBLE_DUPLICATES'));
});

test('query 的 regex 字元只作 literal，且 JS lower 不把 ß 當 SS', async () => {
  const bridge = new FakeBridge((name) => name === 'listTabChats' ? inventory() : historyPage('Tab', 'A', {
    observations: [
      observation('a', '符號 .* [ok]'),
      observation('b', 'STRASSE'),
      observation('c', 'straße'),
    ],
  }));
  const { desktop } = desktopWith(bridge);
  const literal = await desktop.call('line_search_tab_messages', {
    tabName: 'Tab', query: '.* [ok]',
  }, context());
  assert.deepEqual(literal.matches.map((item) => item.observedId), [hex('a')]);
  const sharpS = await desktop.call('line_search_tab_messages', {
    tabName: 'Tab', query: 'STRASSE',
  }, context());
  assert.deepEqual(sharpS.matches.map((item) => item.observedId), [hex('b')]);
});

test('日期邊界接受閏日，body 內日期不會替代未證 UI 日期', async () => {
  const bridge = new FakeBridge((name) => name === 'listTabChats' ? inventory() : historyPage('Tab', 'A', {
    observations: [
      observation('a', 'body 說 2024-02-29', { date: null, dateVerified: false }),
      observation('b', 'UI date verified', { date: '2024-02-29' }),
    ],
    complete: false,
    reasons: ['DATE_CONTEXT_UNVERIFIED'],
  }));
  const { desktop } = desktopWith(bridge);
  const result = await desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: 'A', startDate: '2024-02-29', endDate: '2024-02-29',
  }, context());
  assert.deepEqual(result.observations.map((item) => item.observedId), [hex('b')]);
  assert.equal(result.excludedUnknownDateCount, 1);
  assert.equal(result.complete, false);
});

test('search 三種空結果代數：可續頁、可信完整零命中、terminal limitation', async (t) => {
  await t.test('可證空 inventory 是完整零命中且零 body', async () => {
    let bodyCalls = 0;
    const bridge = new FakeBridge((name) => {
      if (name === 'listTabChats') return inventory([]);
      bodyCalls += 1;
      throw new Error('空 inventory 不應讀 body');
    });
    const { desktop } = desktopWith(bridge);
    const result = await desktop.call('line_search_tab_messages', { tabName: 'Tab', query: 'needle' }, context());
    assert.deepEqual(result.matches, []);
    assert.equal(result.cursor, null);
    assert.equal(result.complete, true);
    assert.deepEqual(result.reasons, []);
    assert.equal(result.syncState, 'complete');
    assert.equal(result.truncated, false);
    assert.equal(result.possibleDuplicates, false);
    assert.equal(bodyCalls, 0);
  });

  await t.test('partial 空 inventory 不冒充完成且 syncState unknown', async () => {
    let bodyCalls = 0;
    const bridge = new FakeBridge((name) => {
      if (name === 'listTabChats') return inventory([], {
        complete: false, partial: true, reasons: ['END_BOUNDARY_UNVERIFIED'],
      });
      bodyCalls += 1;
      throw new Error('partial 空 inventory 不應讀 body');
    });
    const { desktop } = desktopWith(bridge);
    const result = await desktop.call('line_search_tab_messages', { tabName: 'Tab', query: 'needle' }, context());
    assert.equal(result.complete, false);
    assert.equal(result.syncState, 'unknown');
    assert.equal(result.cursor, null);
    assert(result.reasons.includes('INVENTORY_PARTIAL'));
    assert.equal(bodyCalls, 0);
  });

  await t.test('空 filtered page 可續頁', async () => {
    const bridge = new FakeBridge((name) => name === 'listTabChats' ? inventory() : historyPage('Tab', 'A', {
      observations: [observation('a', '其他內容')], nextState: nativeState(), complete: false,
    }));
    const { desktop } = desktopWith(bridge);
    const result = await desktop.call('line_search_tab_messages', { tabName: 'Tab', query: 'needle' }, context());
    assert.deepEqual(result.matches, []);
    assert.equal(typeof result.cursor, 'string');
    assert.equal(result.complete, false);
  });

  await t.test('完整掃描可證零命中', async () => {
    const bridge = new FakeBridge((name) => name === 'listTabChats' ? inventory() : historyPage('Tab', 'A', {
      observations: [observation('a', '其他內容')],
    }));
    const { desktop } = desktopWith(bridge);
    const result = await desktop.call('line_search_tab_messages', { tabName: 'Tab', query: 'needle' }, context());
    assert.deepEqual(result.matches, []);
    assert.equal(result.cursor, null);
    assert.equal(result.complete, true);
  });

  await t.test('terminal limitation 不得冒充完整空結果', async () => {
    const bridge = new FakeBridge((name) => name === 'listTabChats' ? inventory() : historyPage('Tab', 'A', {
      complete: false, reasons: ['LATEST_BOUNDARY_UNVERIFIED'], syncState: 'unknown',
    }));
    const { desktop } = desktopWith(bridge);
    const result = await desktop.call('line_search_tab_messages', { tabName: 'Tab', query: 'needle' }, context());
    assert.deepEqual(result.matches, []);
    assert.equal(result.cursor, null);
    assert.equal(result.complete, false);
    assert(result.reasons.includes('LATEST_BOUNDARY_UNVERIFIED'));
  });
});

test('partial inventory 只讀已唯一證實 member；重名 scope 零 body', async () => {
  const bodyChats = [];
  const partial = inventory(['Dup', 'Dup', 'Unique'], {
    complete: false,
    partial: true,
    reasons: ['END_BOUNDARY_UNVERIFIED'],
    ambiguousNames: ['Dup'],
  });
  const bridge = new FakeBridge((name, args) => {
    if (name === 'listTabChats') return partial;
    bodyChats.push(args.chatName);
    return historyPage('Tab', args.chatName);
  });
  const { desktop } = desktopWith(bridge);
  await assert.rejects(desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: 'Dup',
  }, context()), (error) => errorCode(error) === 'SCOPE_AMBIGUOUS');
  const result = await desktop.call('line_search_tab_messages', { tabName: 'Tab', query: 'x' }, context());
  assert.deepEqual(bodyChats, ['Unique']);
  assert.equal(result.complete, false);
  assert.equal(result.syncState, 'complete');
  assert(result.reasons.includes('INVENTORY_PARTIAL'));
  assert(result.reasons.includes('INVENTORY_AMBIGUOUS'));
});

test('P3 cursor 綁 kind/session/query/date/limit/boot/TTL，錯配皆在 history body 前拒絕', async () => {
  let now = 1_000;
  let bodyCalls = 0;
  const bridge = new FakeBridge((name) => {
    if (name === 'listTabChats') return inventory();
    bodyCalls += 1;
    return historyPage('Tab', 'A', { nextState: nativeState(), complete: false });
  });
  const { desktop } = desktopWith(bridge, { now: () => now });
  const create = () => desktop.call('line_search_tab_messages', {
    tabName: 'Tab', query: 'foo', startDate: '2026-10-24', limit: 5,
  }, context());
  const first = await create();
  const before = bodyCalls;
  for (const [callContext, args] of [
    [context('other'), { tabName: 'Tab', query: 'foo', startDate: '2026-10-24', limit: 5 }],
    [context(), { tabName: 'Tab', query: 'bar', startDate: '2026-10-24', limit: 5 }],
    [context(), { tabName: 'Tab', query: 'foo', startDate: '2026-10-23', limit: 5 }],
    [context(), { tabName: 'Tab', query: 'foo', startDate: '2026-10-24', limit: 6 }],
  ]) {
    await assert.rejects(desktop.call('line_search_tab_messages', { ...args, cursor: first.cursor }, callContext),
      (error) => errorCode(error) === 'CURSOR_INVALID');
  }
  await assert.rejects(desktop.call('line_get_chat_history_page', {
    tabName: 'Tab', chatName: 'A', startDate: '2026-10-24', limit: 5, cursor: first.cursor,
  }, context()), (error) => errorCode(error) === 'CURSOR_INVALID');
  await assert.rejects(desktop.call('line_list_tab_chats', {
    tabName: 'Tab', limit: 5, cursor: first.cursor,
  }, context()), (error) => errorCode(error) === 'CURSOR_INVALID');
  assert.equal(bodyCalls, before);

  const bootCursor = (await create()).cursor;
  desktop.bootNonce = 'different-boot';
  await assert.rejects(desktop.call('line_search_tab_messages', {
    tabName: 'Tab', query: 'foo', startDate: '2026-10-24', limit: 5, cursor: bootCursor,
  }, context()), (error) => errorCode(error) === 'CURSOR_INVALID');
  desktop.bootNonce = 'boot-secret-a';
  const ttlCursor = (await create()).cursor;
  now += 120_001;
  await assert.rejects(desktop.call('line_search_tab_messages', {
    tabName: 'Tab', query: 'foo', startDate: '2026-10-24', limit: 5, cursor: ttlCursor,
  }, context()), (error) => errorCode(error) === 'CURSOR_INVALID');
});

test('惡意 native envelope/state 未通過 strict schema 時不建立 cursor', async (t) => {
  const cases = [
    historyPage('Tab', 'A', { extra: true }),
    historyPage('Tab', 'A', { observations: [{ ...observation('a', 'x'), observedId: 'short' }] }),
    historyPage('Tab', 'A', { nextState: { ...nativeState(), body: 'leak' }, complete: false }),
    historyPage('Tab', 'A', { nextState: nativeState({ offset: 2_001 }), complete: false }),
    historyPage('Tab', 'A', {
      nextState: nativeState({
        seenIds: Array.from({ length: 1_100 }, (_, index) => index.toString(16).padStart(64, '0')),
      }),
      complete: false,
    }),
    historyPage('Tab', 'A', {
      observations: [observation('a', 'x', { date: '2026-02-30' })],
    }),
    historyPage('Tab', 'A', {
      observations: [observation('a', 'x', { date: null, dateVerified: true })],
    }),
    historyPage('Tab', 'A', {
      nextState: nativeState({ dateContext: { date: null, anchorHash: hex('3') } }),
      complete: false,
    }),
    historyPage('Tab', 'A', {
      observations: [observation('a', 'x', { identityVerified: false })],
    }),
  ];
  for (const [index, malicious] of cases.entries()) {
    await t.test(`case-${index}`, async () => {
      const bridge = new FakeBridge((name) => name === 'listTabChats' ? inventory() : malicious);
      const { desktop } = desktopWith(bridge);
      await assert.rejects(desktop.call('line_get_chat_history_page', {
        tabName: 'Tab', chatName: 'A', limit: 2,
      }, context()), (error) => errorCode(error) === 'NATIVE_PROTOCOL_ERROR');
      assert.equal(desktop.cursors.size, 0);
    });
  }
});

test('NativeBridge liveScope 只允許 exact fixture 的 readHistoryPage args', async (t) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'line-desktop-phase3-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const sourcePath = path.join(directory, 'helper.swift');
  const cacheDir = path.join(directory, 'cache');
  await fs.writeFile(sourcePath, 'print("fixture")');
  const calls = [];
  const fakeExecFile = (file, args, _options, callback) => {
    const call = { file, input: '' };
    calls.push(call);
    return { stdin: { on() {}, end(input) {
      call.input = input;
      if (file === '/usr/bin/swiftc') fs.writeFile(args.at(-1), 'binary').then(() => callback(null, '', ''));
      else callback(null, JSON.stringify({ ok: true, result: { accepted: true } }), '');
    } } };
  };
  const bridge = new NativeBridge({
    execFile: fakeExecFile,
    sourcePath,
    cacheDir,
    liveScope: { tabName: 'Tab', chatName: 'A' },
  });
  for (const args of [
    { chatName: 'Other', limit: 1, identityKey: hex('a') },
    { tabName: 'Other', chatName: 'A', limit: 1, identityKey: hex('a') },
    { chatName: 'A', limit: 1, identityKey: hex('a'), query: 'must-not-pass' },
  ]) {
    await assert.rejects(bridge.call('readHistoryPage', args),
      (error) => errorCode(error) === 'LIVE_SCOPE_DENIED');
  }
  assert.equal(calls.length, 0);
  assert.deepEqual(await bridge.call('readHistoryPage', {
    chatName: 'A', limit: 1, identityKey: hex('a'), nativeState: nativeState(),
  }), { accepted: true });
  const request = JSON.parse(calls.at(-1).input);
  assert.equal(request.name, 'readHistoryPage');
  assert.equal(request.args.tabName, 'Tab');
  assert.deepEqual(Object.keys(request.args).sort(),
    ['chatName', 'identityKey', 'limit', 'nativeState', 'tabName'].sort());
  assert.deepEqual(request.liveScope, { tabName: 'Tab', chatName: 'A' });
});
