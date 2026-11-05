import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { AutomationError } from '../src/automation/automation-error.js';
import {
  MacOSDesktopAutomation,
  UnsupportedDesktopAutomation,
} from '../src/automation/desktop-automation.js';
import { LineAutomation } from '../src/automation/line-automation.js';
import { MacOSLineAutomation } from '../src/automation/macos-line-automation.js';
import { NativeBridge } from '../src/automation/native-bridge.js';
import { OperationLock } from '../src/automation/operation-lock.js';

const context = (sessionId = 'session-a') => ({ transport: 'stdio', sessionId });
const windowIdentity = {
  pid: 123,
  windowId: 88,
  title: 'LINE',
  bounds: { x: 10, y: 20, width: 900, height: 700 },
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

class ImmediateLock {
  async withLock(work) {
    return work();
  }
}

function deterministicRandom() {
  let value = 0;
  return (length) => Buffer.alloc(length, ++value);
}

async function temporaryDirectory(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'line-desktop-phase1-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  return directory;
}

function errorCode(error) {
  return error?.code;
}

test('LineAutomation 保留舊 history 字串，另提供無共享狀態的 metadata 結果', async () => {
  const calls = [];
  const automation = {
    async getChatHistoryResult(...args) {
      calls.push(args);
      return { history: '同一句\n同一句', metadata: { complete: false, reasons: ['DATE_FILTER_UNAVAILABLE'] } };
    },
  };
  const desktop = { async call(name, args, callContext) { return { name, args, callContext }; } };
  const facade = new LineAutomation({ platform: 'darwin', automation, desktop });

  assert.equal(await facade.getChatHistory('Test chat', '2026-10-24', 2, 3), '同一句\n同一句');
  assert.deepEqual(
    await facade.getChatHistoryResult('Test chat', '2026-10-24', 2, 3),
    { history: '同一句\n同一句', metadata: { complete: false, reasons: ['DATE_FILTER_UNAVAILABLE'] } }
  );
  assert.deepEqual(calls[0], ['Test chat', '2026-10-24', 2, 3]);
  assert.deepEqual(await facade.desktopCall('line_desktop_status', {}, context()), {
    name: 'line_desktop_status', args: {}, callContext: context(),
  });
});

test('macOS osa 保留 AppleScript boolean，不再把 true 轉成空字串', async () => {
  const adapter = new MacOSLineAutomation({ desktop: {}, appleScript: async () => true });
  assert.equal(await adapter.osa('return true'), true);
});

test('Windows 新桌面工具在任何 UI 呼叫前回 UNSUPPORTED_PLATFORM', async () => {
  const desktop = new UnsupportedDesktopAutomation();
  await assert.rejects(
    desktop.call('line_list_tabs', {}, context()),
    (error) => errorCode(error) === 'UNSUPPORTED_PLATFORM'
  );
});

test('所有新工具重驗 stdio/session 並拒絕未知欄位、非法整數與 bidi 名稱', async () => {
  const bridge = new FakeBridge(() => ({ tabs: ['Test tab'] }));
  const desktop = new MacOSDesktopAutomation({ bridge, lock: new ImmediateLock() });

  await assert.rejects(desktop.call('line_list_tabs', {}, { transport: 'http', sessionId: 's' }),
    (error) => errorCode(error) === 'TRANSPORT_NOT_ALLOWED');
  await assert.rejects(desktop.call('line_list_tabs', { maxPages: 1, extra: true }, context()),
    (error) => errorCode(error) === 'INVALID_ARGUMENT');
  await assert.rejects(desktop.call('line_list_tabs', { maxPages: 1.5 }, context()),
    (error) => errorCode(error) === 'INVALID_ARGUMENT');
  await assert.rejects(desktop.call('line_list_tab_chats', { tabName: '安全\u202e假名' }, context()),
    (error) => errorCode(error) === 'INVALID_ARGUMENT');
  assert.equal(bridge.calls.length, 0);
});

test('列舉 cursor 綁 session/tab/snapshot、單次使用，內容漂移明確失效', async () => {
  let snapshot = 'digest-1';
  const bridge = new FakeBridge((name, args) => {
    assert.equal(name, 'listTabChats');
    return {
      chats: args.offset ? ['B'] : ['A'],
      snapshotDigest: snapshot,
      nextOffset: args.offset ? undefined : 1,
      partial: false,
    };
  });
  const desktop = new MacOSDesktopAutomation({
    bridge, lock: new ImmediateLock(), randomBytes: deterministicRandom(),
  });

  const first = await desktop.call('line_list_tab_chats', { tabName: 'Test tab', limit: 1 }, context());
  assert.equal(typeof first.cursor, 'string');
  await assert.rejects(
    desktop.call('line_list_tab_chats', { tabName: 'Test tab', cursor: first.cursor }, context('other')),
    (error) => errorCode(error) === 'CURSOR_INVALID'
  );
  snapshot = 'digest-2';
  await assert.rejects(
    desktop.call('line_list_tab_chats', { tabName: 'Test tab', cursor: first.cursor }, context()),
    (error) => errorCode(error) === 'CURSOR_INVALID'
  );
  await assert.rejects(
    desktop.call('line_list_tab_chats', { tabName: 'Test tab', cursor: first.cursor }, context()),
    (error) => errorCode(error) === 'CURSOR_INVALID'
  );
});

test('全部已讀必須 preview，token 綁 session/boot/TTL 且 snapshot drift 零提交', async (t) => {
  const directory = await temporaryDirectory(t);
  let now = 1_000;
  let snapshot = 'snapshot-a';
  let executions = 0;
  const bridge = new FakeBridge((name) => {
    if (name === 'previewMarkTabRead') {
      return { snapshotDigest: 'snapshot-a', expectedWindow: windowIdentity, preview: { willMutate: true } };
    }
    if (name === 'snapshotMarkTabRead') return { snapshotDigest: snapshot, expectedWindow: windowIdentity };
    if (name === 'executeMarkTabRead') {
      executions += 1;
      return { success: true, readback: { allReadObserved: true } };
    }
    throw new Error(name);
  });
  const desktop = new MacOSDesktopAutomation({
    bridge, lock: new ImmediateLock(), now: () => now, randomBytes: deterministicRandom(),
    journalPath: path.join(directory, 'journal.json'), bootNonce: 'boot-a',
  });

  const preview = await desktop.call('line_mark_tab_read', { tabName: 'Test tab' }, context());
  await assert.rejects(
    desktop.call('line_execute_plan', { planToken: preview.planToken }, context('other')),
    (error) => errorCode(error) === 'PLAN_INVALID'
  );
  snapshot = 'changed';
  await assert.rejects(
    desktop.call('line_execute_plan', { planToken: preview.planToken }, context()),
    (error) => errorCode(error) === 'SNAPSHOT_CHANGED'
  );
  assert.equal(executions, 0);

  const expiring = await desktop.call('line_mark_tab_read', { tabName: 'Test tab' }, context());
  now += 120_001;
  await assert.rejects(
    desktop.call('line_execute_plan', { planToken: expiring.planToken }, context()),
    (error) => errorCode(error) === 'PLAN_INVALID'
  );
});

test('提交前失敗清 journal；提交後不明保留 latch，重啟仍阻擋異動且 token 不可重播', async (t) => {
  const directory = await temporaryDirectory(t);
  const journalPath = path.join(directory, 'journal.json');
  let mode = 'pre';
  const bridge = new FakeBridge((name) => {
    if (name === 'previewMarkTabRead') {
      return { snapshotDigest: 'stable', expectedWindow: windowIdentity, preview: { willMutate: true } };
    }
    if (name === 'snapshotMarkTabRead') return { snapshotDigest: 'stable' };
    if (name === 'executeMarkTabRead') {
      throw new AutomationError('NATIVE_TEST', '測試失敗', { phase: mode === 'pre' ? 'pre_commit' : 'post_commit' });
    }
    if (name === 'status') return { running: true };
    throw new Error(name);
  });
  const options = {
    bridge, lock: new ImmediateLock(), journalPath, randomBytes: deterministicRandom(), bootNonce: 'boot-a',
  };
  const desktop = new MacOSDesktopAutomation(options);

  const first = await desktop.call('line_mark_tab_read', { tabName: 'Test tab' }, context());
  await assert.rejects(desktop.call('line_execute_plan', { planToken: first.planToken }, context()),
    (error) => errorCode(error) === 'NATIVE_TEST');
  await assert.rejects(fs.access(journalPath));
  await assert.rejects(desktop.call('line_execute_plan', { planToken: first.planToken }, context()),
    (error) => errorCode(error) === 'PLAN_INVALID');

  mode = 'post';
  const second = await desktop.call('line_mark_tab_read', { tabName: 'Test tab' }, context());
  await assert.rejects(desktop.call('line_execute_plan', { planToken: second.planToken }, context()),
    (error) => errorCode(error) === 'OPERATION_UNCERTAIN' && error.details.needsRecovery === true);
  await fs.access(journalPath);

  const restarted = new MacOSDesktopAutomation(options);
  const status = await restarted.call('line_desktop_status', {}, context());
  assert.equal(status.needsRecovery, true);
  const callsBefore = bridge.calls.length;
  await assert.rejects(restarted.call('line_mark_tab_read', { tabName: 'Test tab' }, context()),
    (error) => errorCode(error) === 'NEEDS_RECOVERY');
  assert.equal(bridge.calls.length, callsBefore);
});

test('native 回 success 但缺少全部已讀回讀時仍視為 OPERATION_UNCERTAIN', async (t) => {
  const directory = await temporaryDirectory(t);
  const bridge = new FakeBridge((name) => {
    if (name === 'previewMarkTabRead') {
      return { snapshotDigest: 'stable', expectedWindow: windowIdentity, preview: { willMutate: true } };
    }
    if (name === 'snapshotMarkTabRead') return { snapshotDigest: 'stable' };
    if (name === 'executeMarkTabRead') return { success: true };
    throw new Error(name);
  });
  const desktop = new MacOSDesktopAutomation({
    bridge,
    lock: new ImmediateLock(),
    journalPath: path.join(directory, 'journal.json'),
    randomBytes: deterministicRandom(),
  });
  const preview = await desktop.call('line_mark_tab_read', { tabName: 'Test tab' }, context());
  await assert.rejects(
    desktop.call('line_execute_plan', { planToken: preview.planToken }, context()),
    (error) => errorCode(error) === 'OPERATION_UNCERTAIN' && error.details.causeCode === 'READBACK_UNVERIFIED'
  );
  await fs.access(path.join(directory, 'journal.json'));
});

test('legacy draft/send 共用 journal，既有 uncertain latch 會阻止後續傳訊', async (t) => {
  const directory = await temporaryDirectory(t);
  const journalPath = path.join(directory, 'journal.json');
  let mode = 'manual-success';
  const bridge = new FakeBridge(async (name, args) => {
    assert.equal(name, 'sendMessage');
    const journal = await fs.readFile(journalPath, 'utf8');
    assert.equal(journal.includes(args.message), false);
    if (mode === 'manual-success') return { success: true, autoSent: false };
    if (mode === 'pre') throw new AutomationError('DRAFT_NOT_EMPTY', '已有草稿', { phase: 'pre_commit' });
    throw new AutomationError('SEND_UNCERTAIN', '狀態不明', { phase: 'post_commit' });
  });
  const options = { bridge, lock: new ImmediateLock(), journalPath };
  const desktop = new MacOSDesktopAutomation(options);

  assert.deepEqual(await desktop.legacySend('Test chat', 'Synthetic message', false), {
    success: true, autoSent: false,
  });
  await assert.rejects(fs.access(journalPath));

  mode = 'pre';
  await assert.rejects(desktop.legacySend('Test chat', 'Synthetic pre-commit message', true),
    (error) => errorCode(error) === 'DRAFT_NOT_EMPTY');
  await assert.rejects(fs.access(journalPath));

  mode = 'post';
  await assert.rejects(desktop.legacySend('Test chat', 'Synthetic uncertain message', true),
    (error) => errorCode(error) === 'OPERATION_UNCERTAIN' && error.details.needsRecovery === true);
  await fs.access(journalPath);
  const callsBefore = bridge.calls.length;
  const restarted = new MacOSDesktopAutomation(options);
  await assert.rejects(restarted.legacySend('Test chat', 'Synthetic follow-up', false),
    (error) => errorCode(error) === 'NEEDS_RECOVERY');
  assert.equal(bridge.calls.length, callsBefore);
});

test('legacy auto-send 接受原生 UI_SUBMITTED，保留未證送達語意並結束本次 journal', async (t) => {
  const directory = await temporaryDirectory(t);
  const journalPath = path.join(directory, 'journal.json');
  const nativeResult = { success: true, autoSent: true,
    receipt: { status: 'UI_SUBMITTED', deliveryConfirmed: false, observedAt: '2026-10-27T00:00:00Z' } };
  const bridge = new FakeBridge(async (name, args) => {
    assert.equal(name, 'sendMessage');
    assert.equal(args.autoSend, true);
    await fs.access(journalPath);
    return nativeResult;
  });
  const desktop = new MacOSDesktopAutomation({ bridge, lock: new ImmediateLock(), journalPath });
  const facade = new LineAutomation({ platform: 'darwin', desktop });
  assert.deepEqual(await facade.sendChatMessage('Synthetic room', 'Synthetic only', true), nativeResult);
  assert.equal(bridge.calls.length, 1);
  assert.equal(nativeResult.receipt.deliveryConfirmed, false);
  await assert.rejects(fs.access(journalPath), error => error.code === 'ENOENT');
});

test('legacy auto-send 矛盾或缺少回條時保留 journal，拒絕後續呼叫而不重送', async (t) => {
  const variants = [
    { success: false, autoSent: true, receipt: { status: 'UI_SUBMITTED', deliveryConfirmed: false } },
    { success: true, autoSent: false, receipt: { status: 'UI_SUBMITTED', deliveryConfirmed: false } },
    { success: true, receipt: { status: 'UI_SUBMITTED', deliveryConfirmed: false } },
    { success: true, autoSent: true, receipt: { status: 'UI_ACCEPTED', deliveryConfirmed: false } },
    { success: true, autoSent: true, receipt: { status: 'DRAFT_WRITTEN', deliveryConfirmed: false } },
    { success: true, autoSent: true, receipt: { status: 'UI_SUBMITTED', deliveryConfirmed: true } },
    { success: true, autoSent: true, receipt: { status: 'UI_SUBMITTED' } },
    { success: true, autoSent: true },
  ];
  for (const result of variants) {
    const directory = await temporaryDirectory(t);
    const journalPath = path.join(directory, 'journal.json');
    const bridge = new FakeBridge(async () => result);
    const options = { bridge, lock: new ImmediateLock(), journalPath };
    const desktop = new MacOSDesktopAutomation(options);
    await assert.rejects(desktop.legacySend('Synthetic room', 'Synthetic only', true),
      error => error.code === 'OPERATION_UNCERTAIN' && error.details.needsRecovery === true);
    // 不明結果即使換 instance 也必須停止，不能用修正後的 receipt 規則清掉舊 journal。
    const original = await fs.readFile(journalPath, 'utf8');
    const restarted = new MacOSDesktopAutomation(options);
    await assert.rejects(restarted.legacySend('Synthetic room', 'No retry', true),
      error => error.code === 'NEEDS_RECOVERY');
    assert.equal(await fs.readFile(journalPath, 'utf8'), original);
    assert.equal(bridge.calls.length, 1);
  }
});

test('OperationLock 同 instance 並行排隊、finally 釋放，巢狀拒絕', async (t) => {
  const directory = await temporaryDirectory(t);
  const lock = new OperationLock({ lockPath: path.join(directory, 'ui.lock'), timeoutMs: 2_000, pollMs: 5 });
  const order = [];
  let releaseFirst;
  let signalFirstStarted;
  const firstGate = new Promise((resolve) => { releaseFirst = resolve; });
  const firstStarted = new Promise((resolve) => { signalFirstStarted = resolve; });
  const first = lock.withLock(async () => {
    order.push('first-start');
    signalFirstStarted();
    await firstGate;
    order.push('first-end');
  });
  let second;
  try {
    // 編譯並行時檔案鎖可能較慢；等待真正取得鎖，不把 20ms 當成已開始的證據。
    await Promise.race([firstStarted, first]);
    second = lock.withLock(async () => { order.push('second'); });
    assert.deepEqual(order, ['first-start']);
  } finally {
    releaseFirst();
    await Promise.all(second ? [first, second] : [first]);
  }
  assert.deepEqual(order, ['first-start', 'first-end', 'second']);
  await assert.rejects(lock.withLock(() => lock.withLock(async () => {})),
    (error) => errorCode(error) === 'LOCK_REENTRANT');
  await assert.rejects(fs.access(path.join(directory, 'ui.lock')));
});

test('OperationLock 不刪除 owner 未完成或無法證明 stale 的跨程序鎖', async (t) => {
  const directory = await temporaryDirectory(t);
  const lockPath = path.join(directory, 'ui.lock');
  await fs.mkdir(lockPath);
  const lock = new OperationLock({ lockPath, timeoutMs: 20, pollMs: 5 });
  await assert.rejects(lock.withLock(async () => {}), (error) => errorCode(error) === 'LOCK_TIMEOUT');
  await fs.access(lockPath);
});

test('OperationLock 排隊等待也受同一 timeout 限制，逾時工作之後不會偷跑', async (t) => {
  const directory = await temporaryDirectory(t);
  const lock = new OperationLock({ lockPath: path.join(directory, 'ui.lock'), timeoutMs: 25, pollMs: 5 });
  let releaseFirst;
  const gate = new Promise((resolve) => { releaseFirst = resolve; });
  let timedOutWorkRan = false;
  const first = lock.withLock(() => gate);
  await new Promise((resolve) => setTimeout(resolve, 5));
  await assert.rejects(
    lock.withLock(async () => { timedOutWorkRan = true; }),
    (error) => errorCode(error) === 'LOCK_TIMEOUT' && error.details.phase === 'queue'
  );
  releaseFirst();
  await first;
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(timedOutWorkRan, false);
  let thirdRan = false;
  await lock.withLock(async () => { thirdRan = true; });
  assert.equal(thirdRan, true);
});

test('NativeBridge lazy 編譯、固定 execFile、stdin JSON、timeout/maxBuffer 與 typed native error', async (t) => {
  const directory = await temporaryDirectory(t);
  const sourcePath = path.join(directory, 'helper.swift');
  const cacheDir = path.join(directory, 'cache');
  const originalSource = 'print("fixture")';
  await fs.writeFile(sourcePath, originalSource);
  const calls = [];
  let pinnedBeforeDrift;
  let pinnedAfterDrift;
  let pinnedMode;
  const fakeExecFile = (file, args, options, callback) => {
    const call = { file, args, options, input: '' };
    calls.push(call);
    const child = {
      stdin: {
        on() {},
        end(input) {
          call.input = input;
          if (file === '/usr/bin/swiftc') {
            (async () => {
              pinnedBeforeDrift = await fs.readFile(args[0], 'utf8');
              pinnedMode = (await fs.stat(args[0])).mode & 0o777;
              await fs.writeFile(sourcePath, 'print("drifted")');
              pinnedAfterDrift = await fs.readFile(args[0], 'utf8');
              await fs.writeFile(args.at(-1), 'binary');
              callback(null, '', '');
            })().catch(callback);
          } else {
            callback(null, JSON.stringify({
              ok: false, error: { code: 'MAIN_WINDOW_AMBIGUOUS', message: '兩個主窗', details: { count: 2 } },
            }), '');
          }
        },
      },
    };
    return child;
  };
  const bridge = new NativeBridge({ fake: true, execFile: fakeExecFile, sourcePath, cacheDir });
  assert.equal(calls.length, 0);
  await assert.rejects(bridge.call('status'),
    (error) => errorCode(error) === 'MAIN_WINDOW_AMBIGUOUS' && error.details.count === 2);
  assert.equal(calls[0].file, '/usr/bin/swiftc');
  assert.notEqual(calls[0].args[0], sourcePath);
  assert.equal(path.extname(calls[0].args[0]), '.swift');
  assert.equal(pinnedBeforeDrift, originalSource);
  assert.equal(pinnedAfterDrift, originalSource);
  assert.equal(pinnedMode, 0o600);
  await assert.rejects(fs.access(calls[0].args[0]));
  await assert.rejects(fs.access(calls[0].args.at(-1)));
  assert.equal(calls[1].args.length, 0);
  assert.deepEqual(JSON.parse(calls[1].input), { name: 'status', args: {} });
  assert.equal(calls[1].options.timeout, 30_000);
  assert.equal(calls[1].options.maxBuffer, 2 * 1024 * 1024);
});

test('NativeBridge 編譯失敗會清除 pinned source 與不完整 binary', async (t) => {
  const directory = await temporaryDirectory(t);
  const sourcePath = path.join(directory, 'helper.swift');
  const cacheDir = path.join(directory, 'cache');
  await fs.writeFile(sourcePath, 'print("fixture")');
  let pinnedSourcePath;
  let temporaryBinaryPath;
  const fakeExecFile = (_file, args, _options, callback) => ({
    stdin: {
      on() {},
      end() {
        pinnedSourcePath = args[0];
        temporaryBinaryPath = args.at(-1);
        fs.writeFile(temporaryBinaryPath, 'partial')
          .then(() => callback(new Error('synthetic compiler failure'), '', ''));
      },
    },
  });
  const bridge = new NativeBridge({ execFile: fakeExecFile, sourcePath, cacheDir });
  await assert.rejects(bridge.call('status'), (error) => errorCode(error) === 'NATIVE_BUILD_FAILED');
  await assert.rejects(fs.access(pinnedSourcePath));
  await assert.rejects(fs.access(temporaryBinaryPath));
});

test('LINE_MCP_DISABLE_NATIVE 阻止真 execFile，但不阻止注入的離線 fake', async (t) => {
  const previous = process.env.LINE_MCP_DISABLE_NATIVE;
  process.env.LINE_MCP_DISABLE_NATIVE = '1';
  t.after(() => {
    if (previous === undefined) delete process.env.LINE_MCP_DISABLE_NATIVE;
    else process.env.LINE_MCP_DISABLE_NATIVE = previous;
  });
  const disabled = new NativeBridge({ sourcePath: path.join(os.tmpdir(), 'must-not-be-read.swift') });
  await assert.rejects(disabled.call('status'), (error) => errorCode(error) === 'NATIVE_DISABLED');

  const directory = await temporaryDirectory(t);
  const sourcePath = path.join(directory, 'helper.swift');
  const cacheDir = path.join(directory, 'cache');
  await fs.writeFile(sourcePath, 'print("fixture")');
  let calls = 0;
  const fakeExecFile = (file, args, _options, callback) => ({
    stdin: {
      on() {},
      end() {
        calls += 1;
        if (file === '/usr/bin/swiftc') {
          fs.writeFile(args.at(-1), 'binary').then(() => callback(null, '', ''));
        } else {
          callback(null, JSON.stringify({ ok: true, result: { accepted: true } }), '');
        }
      },
    },
  });
  const injected = new NativeBridge({ execFile: fakeExecFile, sourcePath, cacheDir });
  assert.deepEqual(await injected.call('status'), { accepted: true });
  assert.equal(calls, 2);
});

test('NativeBridge liveScope 在編譯與 execFile 前限制唯讀 allowlist 與 exact fixture', async (t) => {
  const directory = await temporaryDirectory(t);
  const sourcePath = path.join(directory, 'helper.swift');
  const cacheDir = path.join(directory, 'cache');
  await fs.writeFile(sourcePath, 'print("fixture")');
  const calls = [];
  const fakeExecFile = (file, args, _options, callback) => {
    const call = { file, args, input: '' };
    calls.push(call);
    return {
      stdin: {
        on() {},
        end(input) {
          call.input = input;
          if (file === '/usr/bin/swiftc') {
            fs.writeFile(args.at(-1), 'binary').then(() => callback(null, '', ''));
          } else {
            callback(null, JSON.stringify({ ok: true, result: { accepted: true } }), '');
          }
        },
      },
    };
  };
  const scope = { tabName: 'Test tab', chatName: 'Test chat' };
  const bridge = new NativeBridge({ execFile: fakeExecFile, sourcePath, cacheDir, liveScope: scope });
  scope.tabName = 'Attacker changed tab';
  assert.deepEqual(bridge.liveScope, { tabName: 'Test tab', chatName: 'Test chat' });

  for (const [name, args] of [
    ['executeMarkTabRead', {}],
    ['previewMarkTabRead', { tabName: 'Test tab' }],
    ['sendMessage', { chatName: 'Test chat' }],
    ['status', { hiddenAction: true }],
    ['listTabChats', { tabName: 'Test tab' }],
    ['listTabChats', { tabName: 'Wrong tab', limit: 100, offset: 0 }],
    ['listTabChats', { tabName: 'Test tab', limit: 100, offset: 0, expectedWindow: {} }],
    ['selectChat', { chatName: 'Wrong chat' }],
    ['selectChat', { chatName: 'Test chat', tabName: 'Wrong tab' }],
    ['getHistory', { chatName: 'Test chat', tabName: 'Wrong tab' }],
  ]) {
    await assert.rejects(bridge.call(name, args), (error) => errorCode(error) === 'LIVE_SCOPE_DENIED');
  }
  assert.equal(calls.length, 0);

  for (const [name, args] of [
    ['status', {}],
    ['processStatus', {}],
    ['accessibilityStatus', {}],
    ['activateLine', {}],
    ['listTabs', { maxPages: 2 }],
    ['listTabChats', { tabName: 'Test tab', limit: 100, offset: 0 }],
    ['selectChat', { chatName: 'Test chat' }],
    ['getHistory', { chatName: 'Test chat' }],
    ['getHistory', { chatName: 'Test chat', tabName: 'Test tab' }],
  ]) {
    assert.deepEqual(await bridge.call(name, args), { accepted: true });
  }
  assert.equal(calls[0].file, '/usr/bin/swiftc');
  const requests = calls.slice(1).map((call) => JSON.parse(call.input));
  assert.deepEqual(requests.map((request) => request.name), [
    'status', 'processStatus', 'accessibilityStatus', 'activateLine', 'listTabs',
    'listTabChats', 'selectChat', 'getHistory', 'getHistory',
  ]);
  assert(requests.every((request) =>
    request.liveScope.tabName === 'Test tab' && request.liveScope.chatName === 'Test chat'));
  for (const request of requests.filter(({ name }) => name === 'selectChat' || name === 'getHistory')) {
    assert.equal(request.args.tabName, 'Test tab');
  }
});

test('NativeBridge 拒絕不完整或含控制字元的 liveScope', () => {
  assert.throws(() => new NativeBridge({ liveScope: { tabName: 'Test tab' } }),
    (error) => errorCode(error) === 'INVALID_LIVE_SCOPE');
  assert.throws(() => new NativeBridge({ liveScope: { tabName: 'Test\n tab', chatName: 'Test chat' } }),
    (error) => errorCode(error) === 'INVALID_LIVE_SCOPE');
});

test('ghost/floating/modal/同名/前景切換/同步中等 native typed failure 不會變成空清單或 success', async () => {
  const scenarios = [
    'MAIN_WINDOW_NOT_FOUND', 'MAIN_WINDOW_AMBIGUOUS', 'AMBIGUOUS_MATCH', 'FOREGROUND_REQUIRED',
    'WINDOW_CHANGED', 'SYNC_IN_PROGRESS', 'SEMANTIC_UNRELIABLE', 'NATIVE_TIMEOUT',
  ];
  for (const code of scenarios) {
    const bridge = new FakeBridge(() => { throw new AutomationError(code, 'fixture'); });
    const desktop = new MacOSDesktopAutomation({ bridge, lock: new ImmediateLock() });
    await assert.rejects(desktop.call('line_list_tabs', {}, context()),
      (error) => errorCode(error) === code);
  }
});
