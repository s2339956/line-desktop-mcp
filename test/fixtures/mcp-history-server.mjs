import assert from 'node:assert/strict';
import { LineDesktopMCPServer } from '../../src/server.js';
import { MacOSDesktopAutomation } from '../../src/automation/desktop-automation.js';
import { syntheticValidLINEWindow, globalNavigationReceipt, memoryJournalFS } from './global-navigation-fixtures.mjs';

// 真正走 MCP 與游標流程，但只有合成資料；絕不建立實機 bridge 或桌面鎖檔。
assert.equal(process.env.LINE_MCP_DISABLE_NATIVE, '1');
assert.equal(process.env.LINE_NATIVE_DISABLE_UI, '1');
const hex = value => value.repeat(64);
const windowIdentity = {
  pid: 123, windowId: 88, title: 'LINE',
  bounds: { x: 10, y: 20, width: 900, height: 700 },
  bundleIdentifier: 'jp.naver.line.mac', executableURL: '/Applications/LINE.app/Contents/MacOS/LINE',
};
const desktop = new MacOSDesktopAutomation({
  lock: { async withLock(work) { return work(); } },
  // 全域讀取也會檢查待恢復狀態；離線 fixture 不接觸使用者真正的 journal。
  fileSystem: memoryJournalFS(),
  bridge: { async call(name, args) {
    if (name === 'status') return {
      running: true, accessibilityTrusted: true, usable: true, foreground: true,
      mainWindow: syntheticValidLINEWindow, partial: false, reasons: [],
    };
    if (name === 'selectGlobalAll') {
      assert.match(args.requestNonce, /^[a-f0-9]{64}$/);
      assert.deepEqual(args.expectedWindow, syntheticValidLINEWindow);
      if (args.chatName === 'Synthetic navfailure') {
        throw Object.assign(new Error('synthetic selection not verified'), {
          code: 'GLOBAL_ALL_NOT_SELECTED', details: { allNavigation: globalNavigationReceipt(args, {
            allSelected: false, inputAttempted: true,
            systemEventsInvocations: 0, eventCounts: { move: 1, down: 1, up: 1 }, phase: 'post_input',
          }) },
        });
      }
      assert.equal(args.chatName, 'Synthetic global');
      return globalNavigationReceipt(args);
    }
    if (name === 'listTabChats') {
      assert.equal(args.tabName, 'Synthetic tab');
      return { tabName: args.tabName, chats: ['Synthetic A', 'Synthetic B'],
        snapshotDigest: hex('a'), observedAt: '2026-10-24T04:00:00Z',
        complete: true, partial: false, selectedTabVerified: true, reasons: [], ambiguousNames: [] };
    }
    const global = name === 'readGlobalHistoryPage';
    if (global) {
      assert.equal(args.tabName, undefined);
      assert.equal(args.chatName, 'Synthetic global');
    } else {
      assert.equal(name, 'readHistoryPage');
      assert.equal(args.tabName, 'Synthetic tab');
    }
    assert.match(args.identityKey, /^[a-f0-9]{64}$/);
    assert.equal(args.query, undefined);
    if (global && args.resultIndex !== undefined) {
      assert.equal(args.resultIndex, 1);
      return {
        scope: { kind: 'search_result', chatName: args.chatName,
          resultIndex: args.resultIndex, verified: true },
        observations: [{ observedId: hex('4'), text: '合成 indexed viewport', date: null,
          dateVerified: false, unit: 'text_block',
          provenance: { source: 'VISIBLE_CHAT_VIEWPORT_OCR', complete: false },
          identityVerified: false }],
        observedAt: '2026-10-24T04:00:00Z', snapshotDigest: hex('e'),
        nextState: null, complete: false,
        reasons: ['VISIBLE_VIEWPORT_ONLY', 'DATE_CONTEXT_UNKNOWN',
          'STABLE_MESSAGE_ID_UNAVAILABLE', 'LATEST_BOUNDARY_UNVERIFIED'],
        syncState: 'unknown', truncated: false, possibleDuplicates: true,
      };
    }
    const continuation = args.nativeState !== undefined && args.nativeState !== null;
    const more = (global || args.chatName === 'Synthetic A') && !continuation;
    const text = global ? '合成全域聊天室文字'
      : args.chatName === 'Synthetic A' && continuation ? 'iPhone 18 1TB 紅' : '合成非命中內容';
    const observedId = hex(args.chatName === 'Synthetic B' ? '3' : continuation ? '2' : '1');
    return {
      scope: global ? { kind: 'chat', chatName: args.chatName, verified: true }
        : { tabName: args.tabName, chatName: args.chatName, verified: true },
      observations: [{ observedId, text, date: '2026-10-24', dateVerified: true,
        unit: 'message', provenance: { source: 'AX_ROW_VALUE', complete: true }, identityVerified: true }],
      observedAt: '2026-10-24T04:00:00Z', snapshotDigest: hex('b'),
      nextState: more ? { version: 1, expectedWindow: global ? syntheticValidLINEWindow : windowIdentity, headerDigest: hex('c'),
        anchorHash: hex('d'), offset: 1, pageNumber: 0, advance: false, seenIds: [observedId],
        dateContext: { date: '2026-10-24', anchorHash: hex('d') } } : null,
      complete: !more, reasons: [], syncState: 'complete', truncated: false, possibleDuplicates: false,
    };
  } },
});
await new LineDesktopMCPServer({ desktopCall: (name, args, context) => desktop.call(name, args, context) }).run(false);
