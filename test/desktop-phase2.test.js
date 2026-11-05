import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { AutomationError } from '../src/automation/automation-error.js';
import { MacOSDesktopAutomation } from '../src/automation/desktop-automation.js';

const context = (sessionId = 'session-a') => ({ transport: 'stdio', sessionId });
const expectedWindow = {
  pid: 123,
  windowId: 88,
  bounds: { x: 10, y: 20, width: 900, height: 700 },
  bundleIdentifier: 'jp.naver.line.mac',
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
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'line-desktop-phase2-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  return directory;
}

function previewResult(changes, overrides = {}) {
  return {
    preview: { summary: `${changes.length} synthetic changes` },
    snapshotDigest: 'snapshot-a',
    expectedWindow,
    itemFingerprints: changes.map((_change, index) => `fingerprint-${index}`),
    canExecute: true,
    blocked: false,
    ...overrides,
  };
}

function successfulBridge(extraHandler) {
  return new FakeBridge((name, args, calls) => {
    const extra = extraHandler?.(name, args, calls);
    if (extra !== undefined) return extra;
    if (name === 'previewTabChanges') return previewResult(args.changes);
    if (name === 'snapshotTabChanges') return { snapshotDigest: 'snapshot-a' };
    if (name === 'executeTabChange') return { success: true, readback: { verified: true } };
    if (name === 'status') return { running: true };
    throw new Error(`Unexpected native call: ${name}`);
  });
}

async function desktopFixture(t, bridge = successfulBridge(), options = {}) {
  const directory = await temporaryDirectory(t);
  const journalPath = path.join(directory, 'pending-operation.json');
  return {
    bridge,
    directory,
    journalPath,
    desktop: new MacOSDesktopAutomation({
      bridge,
      lock: new ImmediateLock(),
      randomBytes: deterministicRandom(),
      bootNonce: 'boot-secret-a',
      journalPath,
      ...options,
    }),
  };
}

async function planAndExecute(desktop, changes, callContext = context()) {
  const preview = await desktop.call('line_plan_tab_changes', { changes }, callContext);
  assert.equal(typeof preview.planToken, 'string');
  return desktop.call('line_execute_plan', { planToken: preview.planToken }, callContext);
}

function errorCode(error) {
  return error?.code;
}

test('四種分類 action 都經 preview、整體 snapshot 與逐項 verified readback', async (t) => {
  const cases = [
    [{ action: 'create_tab', name: '新分類' }],
    [{ action: 'rename_tab', tabName: '舊分類', newName: '新分類' }],
    [{ action: 'move_chat', sourceTab: '來源', destinationTab: '目的', chatName: '聊天室' }],
    [{ action: 'remove_chat', sourceTab: '來源', chatName: '聊天室' }],
  ];

  for (const changes of cases) {
    await t.test(changes[0].action, async (t) => {
      const { desktop, bridge, journalPath } = await desktopFixture(t);
      const result = await planAndExecute(desktop, changes);
      assert.equal(result.complete, true);
      assert.deepEqual(result.results.map(({ status }) => status), ['verified']);
      assert.deepEqual(bridge.calls.map(({ name }) => name), [
        'previewTabChanges', 'snapshotTabChanges', 'executeTabChange',
      ]);
      assert.deepEqual(bridge.calls[2].args.change, changes[0]);
      await assert.rejects(fs.access(journalPath));
    });
  }
});

test('runtime validation 拒絕空批次、超量、未知欄位、混合、重複與相依條件且零 native', async (t) => {
  const { desktop, bridge } = await desktopFixture(t);
  const move = (chatName, extra = {}) => ({
    action: 'move_chat', sourceTab: '來源', destinationTab: '目的', chatName, ...extra,
  });
  const invalid = [
    [],
    Array.from({ length: 21 }, (_, index) => move(`聊天室${index}`)),
    [{ action: 'delete_tab', name: '危險' }],
    [{ action: 'create_tab', name: 'A', extra: true }],
    [{ action: 'create_tab', name: 'A' }, { action: 'create_tab', name: 'B' }],
    [{ action: 'rename_tab', tabName: 'A', newName: 'A' }],
    [{ action: 'rename_tab', tabName: 'A', newName: 'B' }, move('C')],
    [move('A'), move('B', { sourceTab: '其他來源' })],
    [move('A'), move('A', { destinationTab: '另一目的' })],
    [move('A', { destinationTab: '來源' })],
    [{ action: 'remove_chat', sourceTab: '來源', chatName: '安全\u202e偽裝' }],
  ];

  for (const changes of invalid) {
    await assert.rejects(
      desktop.call('line_plan_tab_changes', { changes }, context()),
      (error) => errorCode(error) === 'INVALID_ARGUMENT'
    );
  }
  await assert.rejects(
    desktop.call('line_plan_tab_changes', { changes: [move('A')], extra: true }, context()),
    (error) => errorCode(error) === 'INVALID_ARGUMENT'
  );
  assert.equal(bridge.calls.length, 0);
});

test('blocked 或執行證據不完整的 preview 不發 token', async (t) => {
  const changes = [{ action: 'create_tab', name: '新分類' }];
  const scenarios = [
    { canExecute: false, blocked: true },
    { itemFingerprints: [] },
    { itemFingerprints: [''] },
    { expectedWindow: null },
    { snapshotDigest: '' },
  ];
  for (const overrides of scenarios) {
    await t.test(JSON.stringify(overrides), async (t) => {
      const bridge = new FakeBridge((_name, args) => previewResult(args.changes, overrides));
      const { desktop } = await desktopFixture(t, bridge);
      const preview = await desktop.call('line_plan_tab_changes', { changes }, context());
      assert.equal(preview.canExecute, false);
      assert.equal(preview.blocked, true);
      assert.equal('planToken' in preview, false);
      assert.equal(preview.mayAffectReadState, true);
    });
  }
});

test('native preview 協定拒未知欄位、錯誤旗標與非 JSON control identity', async (t) => {
  const changes = [{ action: 'create_tab', name: '新分類' }];
  const scenarios = [
    { extra: true },
    { canExecute: 'yes' },
    { blocked: [] },
    { expectedWindow: new Map() },
  ];
  for (const overrides of scenarios) {
    await t.test(Object.keys(overrides)[0], async (t) => {
      const bridge = new FakeBridge((_name, args) => previewResult(args.changes, overrides));
      const { desktop } = await desktopFixture(t, bridge);
      await assert.rejects(
        desktop.call('line_plan_tab_changes', { changes }, context()),
        (error) => errorCode(error) === 'NATIVE_PROTOCOL_ERROR'
      );
    });
  }
});

test('token 綁 session、boot、TTL、單次使用，且 caller alias 修改不會改寫保存計畫', async (t) => {
  let now = 1_000;
  const bridge = successfulBridge();
  const { desktop } = await desktopFixture(t, bridge, { now: () => now });
  const changes = [{ action: 'create_tab', name: '原名稱' }];
  const preview = await desktop.call('line_plan_tab_changes', { changes }, context());
  changes[0].name = '攻擊者改名';

  await assert.rejects(
    desktop.call('line_execute_plan', { planToken: preview.planToken }, context('other-session')),
    (error) => errorCode(error) === 'PLAN_INVALID'
  );
  const result = await desktop.call('line_execute_plan', { planToken: preview.planToken }, context());
  assert.equal(result.complete, true);
  assert.equal(bridge.calls.find(({ name }) => name === 'executeTabChange').args.change.name, '原名稱');
  await assert.rejects(
    desktop.call('line_execute_plan', { planToken: preview.planToken }, context()),
    (error) => errorCode(error) === 'PLAN_INVALID'
  );

  const expiring = await desktop.call('line_plan_tab_changes', {
    changes: [{ action: 'create_tab', name: '過期' }],
  }, context());
  now += 120_001;
  await assert.rejects(
    desktop.call('line_execute_plan', { planToken: expiring.planToken }, context()),
    (error) => errorCode(error) === 'PLAN_INVALID'
  );

  now = 1_000;
  const wrongBoot = await desktop.call('line_plan_tab_changes', {
    changes: [{ action: 'create_tab', name: 'boot' }],
  }, context());
  desktop.bootNonce = 'different-boot';
  await assert.rejects(
    desktop.call('line_execute_plan', { planToken: wrongBoot.planToken }, context()),
    (error) => errorCode(error) === 'PLAN_INVALID'
  );
});

test('整體 snapshot drift 會消耗 token 且零逐項 native commit', async (t) => {
  const bridge = successfulBridge((name) => {
    if (name === 'snapshotTabChanges') return { snapshotDigest: 'changed' };
  });
  const { desktop } = await desktopFixture(t, bridge);
  const preview = await desktop.call('line_plan_tab_changes', {
    changes: [{ action: 'create_tab', name: '新分類' }],
  }, context());
  await assert.rejects(
    desktop.call('line_execute_plan', { planToken: preview.planToken }, context()),
    (error) => errorCode(error) === 'SNAPSHOT_CHANGED'
  );
  assert.equal(bridge.calls.some(({ name }) => name === 'executeTabChange'), false);
  await assert.rejects(
    desktop.call('line_execute_plan', { planToken: preview.planToken }, context()),
    (error) => errorCode(error) === 'PLAN_INVALID'
  );
});

test('P2 native snapshot 拋出漂移時也失效 token，第二次不可重播且零 commit', async (t) => {
  let commits = 0;
  const bridge = successfulBridge((name) => {
    if (name === 'snapshotTabChanges') {
      throw new AutomationError('WINDOW_CHANGED', '視窗已漂移');
    }
    if (name === 'executeTabChange') commits += 1;
  });
  const { desktop } = await desktopFixture(t, bridge);
  const preview = await desktop.call('line_plan_tab_changes', {
    changes: [{ action: 'create_tab', name: '新分類' }],
  }, context());
  await assert.rejects(
    desktop.call('line_execute_plan', { planToken: preview.planToken }, context()),
    (error) => errorCode(error) === 'WINDOW_CHANGED'
  );
  await assert.rejects(
    desktop.call('line_execute_plan', { planToken: preview.planToken }, context()),
    (error) => errorCode(error) === 'PLAN_INVALID'
  );
  assert.equal(commits, 0);
});

test('P1 native snapshot 拋出漂移時同樣失效 token 且零 mark-read commit', async (t) => {
  let commits = 0;
  const bridge = new FakeBridge((name) => {
    if (name === 'previewMarkTabRead') {
      return { snapshotDigest: 'snapshot-a', expectedWindow, preview: { willMutate: true } };
    }
    if (name === 'snapshotMarkTabRead') {
      throw new AutomationError('SNAPSHOT_CHANGED', '結構已漂移');
    }
    if (name === 'executeMarkTabRead') commits += 1;
    throw new Error(`Unexpected native call: ${name}`);
  });
  const { desktop } = await desktopFixture(t, bridge);
  const preview = await desktop.call('line_mark_tab_read', { tabName: '測試分頁' }, context());
  await assert.rejects(
    desktop.call('line_execute_plan', { planToken: preview.planToken }, context()),
    (error) => errorCode(error) === 'SNAPSHOT_CHANGED'
  );
  await assert.rejects(
    desktop.call('line_execute_plan', { planToken: preview.planToken }, context()),
    (error) => errorCode(error) === 'PLAN_INVALID'
  );
  assert.equal(commits, 0);
});

test('snapshot 重驗期間超過 120 秒時仍在 consume 前拒絕且零 commit', async (t) => {
  let now = 1_000;
  const bridge = successfulBridge((name) => {
    if (name === 'snapshotTabChanges') {
      now += 120_001;
      return { snapshotDigest: 'snapshot-a' };
    }
  });
  const { desktop } = await desktopFixture(t, bridge, { now: () => now });
  const preview = await desktop.call('line_plan_tab_changes', {
    changes: [{ action: 'create_tab', name: '新分類' }],
  }, context());
  await assert.rejects(
    desktop.call('line_execute_plan', { planToken: preview.planToken }, context()),
    (error) => errorCode(error) === 'PLAN_INVALID'
  );
  assert.equal(bridge.calls.some(({ name }) => name === 'executeTabChange'), false);
});

test('三筆 batch 第二筆確定 pre-commit 失敗時保存 verified prefix 並清除 active journal', async (t) => {
  const canary = 'SENSITIVE_TAB_CHAT_CANARY';
  let journalPath;
  const bridge = successfulBridge((name, args) => {
    if (name !== 'executeTabChange') return undefined;
    return fs.readFile(journalPath, 'utf8').then((journal) => {
      assert.equal(journal.includes(canary), false);
      if (args.index === 1) {
        throw new AutomationError('CAPACITY_CHANGED', '容量漂移', { phase: 'pre_commit' });
      }
      return { success: true, readback: { verified: true } };
    });
  });
  const fixture = await desktopFixture(t, bridge);
  journalPath = fixture.journalPath;
  const changes = ['一', canary, '三'].map((chatName) => ({
    action: 'move_chat', sourceTab: '來源', destinationTab: '目的', chatName,
  }));
  const result = await planAndExecute(fixture.desktop, changes);
  assert.equal(result.complete, false);
  assert.equal(result.needsRecovery, undefined);
  assert.deepEqual(result.results.map(({ status }) => status), [
    'verified', 'failed_before_commit', 'not_attempted',
  ]);
  await assert.rejects(fs.access(journalPath));
});

for (const failedIndex of [1, 2]) {
  test(`三筆 batch 第 ${failedIndex + 1} 筆提交不明時立即 latch 且不執行後續`, async (t) => {
    let executeCalls = 0;
    const bridge = successfulBridge((name, args) => {
      if (name !== 'executeTabChange') return undefined;
      executeCalls += 1;
      if (args.index === failedIndex) {
        throw new AutomationError('WINDOW_CHANGED', '提交後視窗變更', { phase: 'post_commit' });
      }
      return { success: true, readback: { verified: true } };
    });
    const fixture = await desktopFixture(t, bridge);
    const changes = ['一', '二', '三'].map((chatName) => ({
      action: 'remove_chat', sourceTab: '來源', chatName,
    }));
    const result = await planAndExecute(fixture.desktop, changes);
    assert.equal(result.complete, false);
    assert.equal(result.needsRecovery, true);
    assert.deepEqual(result.results.map(({ status }) => status), [
      ...Array(failedIndex).fill('verified'), 'uncertain',
      ...Array(2 - failedIndex).fill('not_attempted'),
    ]);
    assert.equal(executeCalls, failedIndex + 1);
    await fs.access(fixture.journalPath);

    const restarted = new MacOSDesktopAutomation({
      bridge,
      lock: new ImmediateLock(),
      randomBytes: deterministicRandom(),
      bootNonce: 'new-boot',
      journalPath: fixture.journalPath,
    });
    const status = await restarted.call('line_desktop_status', {}, context());
    assert.equal(status.needsRecovery, true);
    assert.deepEqual(status.recovery, {
      state: 'pending',
      valid: true,
      operationId: result.operationId,
      verifiedPrefix: failedIndex,
      uncertainCurrent: failedIndex,
      notAttemptedSuffix: 2 - failedIndex,
    });
    const nativeCallsBefore = bridge.calls.length;
    await assert.rejects(
      restarted.call('line_plan_tab_changes', { changes }, context()),
      (error) => errorCode(error) === 'NEEDS_RECOVERY'
    );
    await assert.rejects(
      restarted.legacySend('聊天室', '訊息', false),
      (error) => errorCode(error) === 'NEEDS_RECOVERY'
    );
    assert.equal(bridge.calls.length, nativeCallsBefore);
  });
}

function faultingFileSystem(stage) {
  let triggered = false;
  return new Proxy(fs, {
    get(target, property) {
      if (property === 'open') {
        return async (file, flags, mode) => {
          const handle = await target.open(file, flags, mode);
          const temporary = String(file).endsWith('.tmp');
          return {
            writeFile: async (...args) => {
              if (!triggered && temporary && stage === 'write') {
                triggered = true;
                throw Object.assign(new Error('synthetic write fault'), { code: 'EIO' });
              }
              return handle.writeFile(...args);
            },
            sync: async () => {
              if (!triggered && temporary && stage === 'fsync') {
                triggered = true;
                throw Object.assign(new Error('synthetic fsync fault'), { code: 'EIO' });
              }
              return handle.sync();
            },
            close: (...args) => handle.close(...args),
          };
        };
      }
      if (property === 'rename') {
        return async (...args) => {
          if (!triggered && stage === 'rename') {
            triggered = true;
            throw Object.assign(new Error('synthetic rename fault'), { code: 'EIO' });
          }
          return target.rename(...args);
        };
      }
      return typeof target[property] === 'function' ? target[property].bind(target) : target[property];
    },
  });
}

for (const stage of ['write', 'fsync', 'rename']) {
  test(`checkpoint ${stage} 故障會在 native commit 前轉 uncertain 並保留 recovery`, async (t) => {
    const bridge = successfulBridge();
    const fixture = await desktopFixture(t, bridge, { fileSystem: faultingFileSystem(stage) });
    const result = await planAndExecute(fixture.desktop, [{ action: 'create_tab', name: '新分類' }]);
    assert.equal(result.complete, false);
    assert.equal(result.needsRecovery, true);
    assert.deepEqual(result.results.map(({ status }) => status), ['uncertain']);
    assert.equal(bridge.calls.some(({ name }) => name === 'executeTabChange'), false);
    await fs.access(fixture.journalPath);
    const status = await fixture.desktop.call('line_desktop_status', {}, context());
    assert.equal(status.needsRecovery, true);
    assert.equal(status.recovery.uncertainCurrent, 0);
  });
}

test('success:true 缺 verified readback 不可假成功，journal 不含明文且維持 0600', async (t) => {
  const canary = 'PRIVATE_CANARY_DO_NOT_PERSIST';
  const bridge = successfulBridge((name) => {
    if (name === 'executeTabChange') return { success: true };
  });
  const fixture = await desktopFixture(t, bridge);
  const result = await planAndExecute(fixture.desktop, [{
    action: 'move_chat', sourceTab: canary, destinationTab: '目的', chatName: '聊天室',
  }]);
  assert.equal(result.needsRecovery, true);
  assert.deepEqual(result.results.map(({ status }) => status), ['uncertain']);
  const journal = await fs.readFile(fixture.journalPath, 'utf8');
  assert.equal(journal.includes(canary), false);
  assert.equal(journal.includes('聊天室'), false);
  assert.deepEqual(Object.keys(JSON.parse(journal)).sort(), [
    'currentIndex', 'itemCount', 'itemHashes', 'operationId', 'phase', 'planHash',
    'schemaVersion', 'verifiedThrough',
  ]);
  assert.equal((await fs.stat(fixture.journalPath)).mode & 0o777, 0o600);
});

test('bad JSON 與未知 journal schema 都視為 pending，status 不揭露內容', async (t) => {
  const fixtures = ['{bad json', JSON.stringify({ schemaVersion: 999, secret: 'PRIVATE' })];
  for (const content of fixtures) {
    await t.test(content.slice(0, 8), async (t) => {
      const bridge = successfulBridge();
      const fixture = await desktopFixture(t, bridge);
      await fs.writeFile(fixture.journalPath, content, { mode: 0o600 });
      const status = await fixture.desktop.call('line_desktop_status', {}, context());
      assert.equal(status.needsRecovery, true);
      assert.deepEqual(status.recovery, { state: 'pending', valid: false });
      assert.equal(JSON.stringify(status).includes('PRIVATE'), false);
    });
  }
});

test('clear journal 失敗不回 complete，最後一項轉 uncertain 並 latch', async (t) => {
  let failed = false;
  const fileSystem = new Proxy(fs, {
    get(target, property) {
      if (property === 'unlink') {
        return async (...args) => {
          if (!failed) {
            failed = true;
            throw Object.assign(new Error('synthetic clear fault'), { code: 'EIO' });
          }
          return target.unlink(...args);
        };
      }
      return typeof target[property] === 'function' ? target[property].bind(target) : target[property];
    },
  });
  const fixture = await desktopFixture(t, successfulBridge(), { fileSystem });
  const result = await planAndExecute(fixture.desktop, [{ action: 'create_tab', name: '新分類' }]);
  assert.equal(result.complete, false);
  assert.equal(result.needsRecovery, true);
  assert.deepEqual(result.results.map(({ status }) => status), ['uncertain']);
  await fs.access(fixture.journalPath);
});

test('clear 已 unlink 但 parent fsync 失敗時會重建可供重啟辨識的 recovery journal', async (t) => {
  const directory = await temporaryDirectory(t);
  const journalPath = path.join(directory, 'pending-operation.json');
  let afterUnlink = false;
  let failedDirectorySync = false;
  const fileSystem = new Proxy(fs, {
    get(target, property) {
      if (property === 'unlink') {
        return async (...args) => {
          await target.unlink(...args);
          afterUnlink = true;
        };
      }
      if (property === 'open') {
        return async (file, flags, mode) => {
          const handle = await target.open(file, flags, mode);
          return {
            writeFile: (...args) => handle.writeFile(...args),
            sync: async () => {
              if (afterUnlink && !failedDirectorySync && String(file) === directory) {
                failedDirectorySync = true;
                throw Object.assign(new Error('synthetic parent fsync fault'), { code: 'EIO' });
              }
              return handle.sync();
            },
            close: (...args) => handle.close(...args),
          };
        };
      }
      return typeof target[property] === 'function' ? target[property].bind(target) : target[property];
    },
  });
  const bridge = successfulBridge();
  const desktop = new MacOSDesktopAutomation({
    bridge,
    lock: new ImmediateLock(),
    randomBytes: deterministicRandom(),
    bootNonce: 'boot-secret-a',
    journalPath,
    fileSystem,
  });
  const result = await planAndExecute(desktop, [{ action: 'create_tab', name: '新分類' }]);
  assert.equal(result.complete, false);
  assert.equal(result.needsRecovery, true);
  await fs.access(journalPath);

  const restarted = new MacOSDesktopAutomation({
    bridge,
    lock: new ImmediateLock(),
    journalPath,
    bootNonce: 'new-boot',
  });
  const status = await restarted.call('line_desktop_status', {}, context());
  assert.equal(status.needsRecovery, true);
  assert.equal(status.recovery.uncertainCurrent, 0);
  assert.equal(status.recovery.verifiedPrefix, 0);
});
