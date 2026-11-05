import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import test from 'node:test';
import { AutomationError } from '../src/automation/automation-error.js';
import { MacOSDesktopAutomation } from '../src/automation/desktop-automation.js';
import {
  globalNavigationReceipt,
  memoryJournalFS,
  syntheticValidLINEWindow,
} from './fixtures/global-navigation-fixtures.mjs';
import { runRecoveryCli } from '../scripts/recover-all-navigation.mjs';

const JOURNAL = '/synthetic-line-mcp/pending-operation.json';
const LEGACY_SOURCE = 'f847245dffaacdb7429614ec6dcb87528aa55a723116f7367ffbd5da769b01a8';
const hex = character => character.repeat(64);
const context = { transport: 'stdio', sessionId: 'recovery-test' };
const stable = value => Array.isArray(value) ? value.map(stable)
  : value && typeof value === 'object'
    ? Object.fromEntries(Object.keys(value).sort().map(key => [key, stable(value[key])]))
    : value;
const digest = value => crypto.createHash('sha256').update(JSON.stringify(stable(value))).digest('hex');

function legacyRecord(overrides = {}) {
  const requestNonce = hex('a');
  const start = {
    version: 1,
    route: 'line-pid-mouse-v1',
    requestNonce,
    sourceDigest: LEGACY_SOURCE,
    pid: syntheticValidLINEWindow.pid,
    expectedWindow: syntheticValidLINEWindow,
    scopeHmac: hex('b'),
    phase: 'pre_input',
    eventCounts: { move: 0, down: 0, up: 0 },
  };
  return {
    schemaVersion: 2,
    operationId: `global-all-navigation:${requestNonce}`,
    planHash: start.scopeHmac,
    itemHashes: [digest(start)],
    itemCount: 1,
    currentIndex: 0,
    verifiedThrough: -1,
    phase: 'uncertain',
    navigation: {
      ...start,
      phase: 'post_input',
      eventCounts: { move: null, down: null, up: null },
    },
    ...overrides,
  };
}

function v4Record(overrides = {}) {
  const requestNonce = hex('d');
  const start = {
    version: 1,
    route: 'line-system-events-all-v1',
    requestNonce,
    sourceDigest: hex('9'),
    pid: syntheticValidLINEWindow.pid,
    expectedWindow: syntheticValidLINEWindow,
    scopeHmac: hex('e'),
    phase: 'pre_input',
    eventCounts: { move: 0, down: 0, up: 0 },
    systemEventsInvocations: 0,
  };
  return {
    schemaVersion: 2,
    operationId: `global-all-navigation:${requestNonce}`,
    planHash: start.scopeHmac,
    itemHashes: [digest(start)],
    itemCount: 1,
    currentIndex: 0,
    verifiedThrough: -1,
    phase: 'uncertain',
    navigation: {
      ...start,
      phase: 'post_input',
      eventCounts: { move: null, down: null, up: null },
      systemEventsInvocations: null,
    },
    ...overrides,
  };
}

async function seedJournal(fileSystem, record) {
  await fileSystem.mkdir('/synthetic-line-mcp', { recursive: true, mode: 0o700 });
  const handle = await fileSystem.open(JOURNAL, 'wx', 0o600);
  await handle.writeFile(JSON.stringify(record));
  await handle.sync();
  await handle.close();
  const directory = await fileSystem.open('/synthetic-line-mcp', 'r');
  await directory.sync();
  await directory.close();
  fileSystem.operations.length = 0;
}

function recoveryDesktop(fileSystem, handler = {}) {
  const calls = [];
  const bridge = {
    async selectedSourceDigest() {
      return { sourceDigest: hex('9'), sourceDigestVerified: true };
    },
    async call(name, args = {}) {
      calls.push({ name, args });
      if (handler[name]) return handler[name](args);
      if (name === 'activateLine') return { success: true };
      if (name === 'status') return {
        running: true, accessibilityTrusted: true, foreground: true, usable: true,
        mainWindow: syntheticValidLINEWindow,
      };
      if (name === 'selectGlobalAll' || name === 'observeGlobalAll') {
        return globalNavigationReceipt(args);
      }
      throw new Error(`unexpected command: ${name}`);
    },
  };
  const desktop = new MacOSDesktopAutomation({
    bridge,
    lock: { withLock: work => work() },
    fileSystem,
    journalPath: JOURNAL,
    recoveryEvidenceDirectory: '/synthetic-line-mcp/recovery-evidence',
    randomBytes: length => Buffer.alloc(length, 0xcc),
    bootNonce: 'synthetic-recovery-boot',
    exportReader: null,
  });
  return { desktop, calls };
}

test('preview 只驗 owner/canonical，不呼叫 native 且 operationId 不進 JSON', async () => {
  const fileSystem = memoryJournalFS();
  const record = legacyRecord();
  await seedJournal(fileSystem, record);
  const { desktop, calls } = recoveryDesktop(fileSystem);
  const preview = await desktop.previewGlobalAllNavigationRecovery({ chatName: '測試對話' }, context);
  assert.equal(preview.expectedOperationId, record.operationId);
  assert.equal(JSON.stringify(preview).includes(record.operationId), false);
  assert.deepEqual(calls, []);
});

test('legacy owner-bound recovery 先封存與checkpoint，再用HID一次結案', async () => {
  const fileSystem = memoryJournalFS();
  const record = legacyRecord();
  await seedJournal(fileSystem, record);
  const { desktop, calls } = recoveryDesktop(fileSystem, {
    selectGlobalAll: args => globalNavigationReceipt(args, {
      inputAttempted: true,
      eventCounts: { move: 1, down: 1, up: 1 },
      systemEventsInvocations: 0,
    }),
  });
  const result = await desktop.recoverGlobalAllNavigation({
    chatName: '測試對話', expectedOperationId: record.operationId,
  }, context, { run: true });
  assert.deepEqual(calls.map(({ name }) => name), ['activateLine', 'status', 'selectGlobalAll']);
  assert.equal(result.complete, true);
  assert.equal(result.recoveredCurrentView, true);
  assert.equal(result.systemEventsInvocations, 0);
  assert.equal(fileSystem.files.has(JOURNAL), false);
  assert([...fileSystem.files.keys()].some(name => name.includes('/recovery-evidence/')));
});

test('錯opid/source/window/owner/mode/symlink/size在archive與native前停止', async (t) => {
  const cases = {
    opid: [legacyRecord(), `global-all-navigation:${hex('f')}`],
    source: [legacyRecord({ navigation: {
      ...legacyRecord().navigation, sourceDigest: hex('e'),
    } }), legacyRecord().operationId],
    window: [legacyRecord({ navigation: {
      ...legacyRecord().navigation,
      expectedWindow: { ...syntheticValidLINEWindow, teamIdentifier: 'WRONGTEAM' },
    } }), legacyRecord().operationId],
    version: [legacyRecord({ navigation: {
      ...legacyRecord().navigation, version: 2,
    } }), legacyRecord().operationId],
    emptyCounts: [legacyRecord({ navigation: {
      ...legacyRecord().navigation, eventCounts: {},
    } }), legacyRecord().operationId],
    attempt: [legacyRecord({ recoveryAttempt: {
      version: 1, attempt: 2, route: 'line-system-events-all-v1',
    } }), legacyRecord().operationId],
  };
  for (const [name, [record, operationId]] of Object.entries(cases)) {
    await t.test(name, async () => {
      const fileSystem = memoryJournalFS();
      await seedJournal(fileSystem, record);
      const { desktop, calls } = recoveryDesktop(fileSystem);
      await assert.rejects(desktop.recoverGlobalAllNavigation({
        chatName: '測試對話', expectedOperationId: operationId,
      }, context, { run: true }), error => error?.code === 'RECOVERY_RECORD_INVALID');
      assert.deepEqual(calls, []);
      assert.equal([...fileSystem.files.keys()].some(path => path.includes('recovery-evidence')), false);
    });
  }

  for (const [name, mutate] of Object.entries({
    mode: stat => ({ ...stat, mode: 0o100644 }),
    owner: stat => ({ ...stat, uid: stat.uid + 1 }),
    symlink: stat => ({ ...stat, isSymbolicLink: () => true }),
    size: stat => ({ ...stat, size: 64 * 1024 + 1 }),
  })) {
    await t.test(name, async () => {
      const fileSystem = memoryJournalFS();
      await seedJournal(fileSystem, legacyRecord());
      const originalLstat = fileSystem.lstat;
      fileSystem.lstat = async target => target === JOURNAL
        ? mutate(await originalLstat(target))
        : originalLstat(target);
      const { desktop, calls } = recoveryDesktop(fileSystem);
      await assert.rejects(desktop.previewGlobalAllNavigationRecovery({ chatName: '測試對話' }, context),
        error => error?.code === 'RECOVERY_RECORD_INVALID');
      assert.deepEqual(calls, []);
    });
  }
});

test('durability失敗為零native；spent recovery只observe且negative不清除', async () => {
  const fileSystem = memoryJournalFS();
  const record = legacyRecord();
  await seedJournal(fileSystem, record);
  fileSystem.failures.add('rename');
  const first = recoveryDesktop(fileSystem);
  await assert.rejects(first.desktop.recoverGlobalAllNavigation({
    chatName: '測試對話', expectedOperationId: record.operationId,
  }, context, { run: true }));
  assert.deepEqual(first.calls, []);

  fileSystem.failures.clear();
  const spent = recoveryDesktop(fileSystem, {
    selectGlobalAll() { throw new AutomationError('NATIVE_TIMEOUT', 'synthetic timeout'); },
  });
  await assert.rejects(spent.desktop.recoverGlobalAllNavigation({
    chatName: '測試對話', expectedOperationId: record.operationId,
  }, context, { run: true }), error => error?.code === 'OPERATION_UNCERTAIN');
  assert.deepEqual(spent.calls.map(({ name }) => name), ['activateLine', 'status', 'selectGlobalAll']);

  const retry = recoveryDesktop(fileSystem, {
    observeGlobalAll: args => globalNavigationReceipt(args, {
      allSelected: false,
      identityVerified: false,
      mainWindow: null,
      phase: 'post_input',
    }),
  });
  await assert.rejects(retry.desktop.recoverGlobalAllNavigation({
    chatName: '測試對話', expectedOperationId: record.operationId,
  }, context, { run: true }), error => error?.code === 'OPERATION_UNCERTAIN');
  assert.deepEqual(retry.calls.map(({ name }) => name), ['observeGlobalAll']);
  assert(fileSystem.files.has(JOURNAL));
});

test('既有exact archive重用前仍需dirsync，失敗時零native', async () => {
  const fileSystem = memoryJournalFS();
  const record = legacyRecord();
  await seedJournal(fileSystem, record);
  const raw = Buffer.from(JSON.stringify(record));
  const rawSha = crypto.createHash('sha256').update(raw).digest('hex');
  const directory = '/synthetic-line-mcp/recovery-evidence';
  await fileSystem.mkdir(directory, { recursive: true, mode: 0o700 });
  const handle = await fileSystem.open(`${directory}/${rawSha}.json`, 'wx', 0o600);
  await handle.writeFile(raw);
  await handle.sync();
  await handle.close();
  fileSystem.failures.add('dirsync');
  const { desktop, calls } = recoveryDesktop(fileSystem);
  await assert.rejects(desktop.recoverGlobalAllNavigation({
    chatName: '測試對話', expectedOperationId: record.operationId,
  }, context, { run: true }));
  assert.deepEqual(calls, []);
});

test('HID uncertain same instance只能observe，positive才結案', async () => {
  const fileSystem = memoryJournalFS();
  const creating = recoveryDesktop(fileSystem, {
    selectGlobalAll() { throw new AutomationError('NATIVE_TIMEOUT', 'synthetic timeout'); },
  });
  await assert.rejects(creating.desktop.call('line_get_chat_history_global',
    { chatName: '測試對話', limit: 5 }, context), error => error?.code === 'OPERATION_UNCERTAIN');
  const operationId = fileSystem.readJson(JOURNAL).operationId;
  assert.equal(fileSystem.readJson(JOURNAL).navigation.route, 'line-hid-all-v1');
  assert.deepEqual(fileSystem.readJson(JOURNAL).navigation.eventCounts,
    { move: null, down: null, up: null });
  assert.equal(fileSystem.readJson(JOURNAL).navigation.systemEventsInvocations, 0);
  const invalidFs = memoryJournalFS();
  const invalidRecord = fileSystem.readJson(JOURNAL);
  invalidRecord.navigation.systemEventsInvocations = null;
  await seedJournal(invalidFs, invalidRecord);
  const invalidDesktop = recoveryDesktop(invalidFs);
  await assert.rejects(invalidDesktop.desktop.previewGlobalAllNavigationRecovery(
    { chatName: '測試對話' }, context
  ), error => error?.code === 'RECOVERY_RECORD_INVALID');

  const callsBeforeRecovery = creating.calls.length;
  const result = await creating.desktop.recoverGlobalAllNavigation({
    chatName: '測試對話', expectedOperationId: operationId,
  }, context, { run: true });
  assert.equal(result.mode, 'reconciled');
  assert.equal(result.recoveredCurrentView, true);
  assert.deepEqual(creating.calls.slice(callsBeforeRecovery).map(({ name }) => name), ['observeGlobalAll']);
  assert.equal(fileSystem.files.has(JOURNAL), false);
  assert.equal(await creating.desktop.hasPendingJournal(), false);
});

test('舊V4 uncertain保留sysinv null且只能由HID observe positive結案', async () => {
  const fileSystem = memoryJournalFS();
  const record = v4Record();
  await seedJournal(fileSystem, record);
  const { desktop, calls } = recoveryDesktop(fileSystem);
  const result = await desktop.recoverGlobalAllNavigation({
    chatName: '測試對話', expectedOperationId: record.operationId,
  }, context, { run: true });
  assert.equal(result.mode, 'reconciled');
  assert.deepEqual(calls.map(({ name }) => name), ['observeGlobalAll']);
  assert.equal(fileSystem.files.has(JOURNAL), false);

  const invalidFs = memoryJournalFS();
  const invalid = v4Record({ navigation: {
    ...record.navigation,
    systemEventsInvocations: 0,
  } });
  await seedJournal(invalidFs, invalid);
  const invalidDesktop = recoveryDesktop(invalidFs);
  await assert.rejects(invalidDesktop.desktop.previewGlobalAllNavigationRecovery(
    { chatName: '測試對話' }, context
  ), error => error?.code === 'RECOVERY_RECORD_INVALID');
  assert.deepEqual(invalidDesktop.calls, []);
});

test('舊System Events recoveryAttempt仍相容，但spent後只走HID observe', async () => {
  const fileSystem = memoryJournalFS();
  const record = legacyRecord({
    recoveryAttempt: {
      version: 1,
      attempt: 1,
      route: 'line-system-events-all-v1',
      requestNonce: hex('c'),
      sourceDigest: hex('9'),
      phase: 'uncertain',
      expectedWindow: syntheticValidLINEWindow,
    },
  });
  await seedJournal(fileSystem, record);
  const { desktop, calls } = recoveryDesktop(fileSystem);
  const result = await desktop.recoverGlobalAllNavigation({
    chatName: '測試對話', expectedOperationId: record.operationId,
  }, context, { run: true });
  assert.equal(result.recoveredCurrentView, true);
  assert.deepEqual(calls.map(({ name }) => name), ['observeGlobalAll']);
});

test('被動observe期間canonical raw漂移時不得覆寫或清除', async () => {
  const fileSystem = memoryJournalFS();
  const creating = recoveryDesktop(fileSystem, {
    selectGlobalAll() { throw new AutomationError('NATIVE_TIMEOUT', 'synthetic timeout'); },
  });
  await assert.rejects(creating.desktop.call('line_get_chat_history_global',
    { chatName: '測試對話', limit: 5 }, context));
  const operationId = fileSystem.readJson(JOURNAL).operationId;
  const fresh = recoveryDesktop(fileSystem, {
    observeGlobalAll(args) {
      const record = fileSystem.readJson(JOURNAL);
      fileSystem.files.get(JOURNAL).bytes = Buffer.from(JSON.stringify(record, null, 2));
      return globalNavigationReceipt(args);
    },
  });
  await assert.rejects(fresh.desktop.recoverGlobalAllNavigation({
    chatName: '測試對話', expectedOperationId: operationId,
  }, context, { run: true }), error => error?.code === 'OPERATION_UNCERTAIN');
  assert(fileSystem.files.has(JOURNAL));
});

test('HID verified clear dirsync失敗會重建record，fresh instance只observe後結案', async () => {
  const fileSystem = memoryJournalFS();
  const originalUnlink = fileSystem.unlink;
  fileSystem.unlink = async target => {
    await originalUnlink(target);
    fileSystem.failures.add('dirsync');
  };
  let bodyCalls = 0;
  const creating = recoveryDesktop(fileSystem, {
    readGlobalHistoryPage() { bodyCalls += 1; throw new Error('不得讀 body'); },
  });
  await assert.rejects(creating.desktop.call('line_get_chat_history_global',
    { chatName: '測試對話', limit: 5 }, context), error => error?.code === 'OPERATION_UNCERTAIN');
  assert.equal(bodyCalls, 0);
  assert(fileSystem.files.has(JOURNAL));
  const operationId = fileSystem.readJson(JOURNAL).operationId;

  fileSystem.unlink = originalUnlink;
  const fresh = recoveryDesktop(fileSystem);
  const result = await fresh.desktop.recoverGlobalAllNavigation({
    chatName: '測試對話', expectedOperationId: operationId,
  }, context, { run: true });
  assert.equal(result.mode, 'reconciled');
  assert.equal(result.recoveredCurrentView, true);
  assert.deepEqual(fresh.calls.map(({ name }) => name), ['observeGlobalAll']);
  assert.equal(fileSystem.files.has(JOURNAL), false);
});

test('legacy verified clear dirsync失敗後fresh instance可被動結案', async () => {
  const fileSystem = memoryJournalFS();
  const record = legacyRecord();
  await seedJournal(fileSystem, record);
  const originalUnlink = fileSystem.unlink;
  fileSystem.unlink = async target => {
    await originalUnlink(target);
    fileSystem.failures.add('dirsync');
  };
  const active = recoveryDesktop(fileSystem);
  await assert.rejects(active.desktop.recoverGlobalAllNavigation({
    chatName: '測試對話', expectedOperationId: record.operationId,
  }, context, { run: true }), error => error?.code === 'OPERATION_UNCERTAIN');
  assert.equal(fileSystem.readJson(JOURNAL).verifiedThrough, 0);

  fileSystem.unlink = originalUnlink;
  const fresh = recoveryDesktop(fileSystem);
  const result = await fresh.desktop.recoverGlobalAllNavigation({
    chatName: '測試對話', expectedOperationId: record.operationId,
  }, context, { run: true });
  assert.equal(result.recoveredCurrentView, true);
  assert.deepEqual(fresh.calls.map(({ name }) => name), ['observeGlobalAll']);
  assert.equal(fileSystem.files.has(JOURNAL), false);
});

test('passive positive不改寫未知attempt，clear失敗後same/fresh仍只observe結案', async (t) => {
  for (const mode of ['same', 'fresh']) {
    await t.test(mode, async () => {
      const fileSystem = memoryJournalFS();
      const record = legacyRecord();
      await seedJournal(fileSystem, record);
      const active = recoveryDesktop(fileSystem, {
        selectGlobalAll() { throw new AutomationError('NATIVE_TIMEOUT', 'synthetic timeout'); },
      });
      await assert.rejects(active.desktop.recoverGlobalAllNavigation({
        chatName: '測試對話', expectedOperationId: record.operationId,
      }, context, { run: true }));

      const originalUnlink = fileSystem.unlink;
      fileSystem.unlink = async target => {
        await originalUnlink(target);
        fileSystem.failures.add('dirsync');
      };
      const passive = recoveryDesktop(fileSystem);
      await assert.rejects(passive.desktop.recoverGlobalAllNavigation({
        chatName: '測試對話', expectedOperationId: record.operationId,
      }, context, { run: true }), error => error?.code === 'OPERATION_UNCERTAIN');
      const persisted = fileSystem.readJson(JOURNAL);
      assert.equal(persisted.recoveryAttempt.phase, 'uncertain');
      assert.equal(persisted.recoveryAttempt.systemEventsInvocations, 0);
      assert.deepEqual(persisted.recoveryAttempt.eventCounts, { move: null, down: null, up: null });
      assert.equal(persisted.reconciledCurrentView.systemEventsInvocations, 0);
      assert.equal(persisted.reconciledCurrentView.route, 'line-hid-all-v1');
      assert.deepEqual(persisted.reconciledCurrentView.eventCounts, { move: 0, down: 0, up: 0 });

      fileSystem.unlink = originalUnlink;
      const closer = mode === 'same' ? passive : recoveryDesktop(fileSystem);
      const before = closer.calls.length;
      const result = await closer.desktop.recoverGlobalAllNavigation({
        chatName: '測試對話', expectedOperationId: record.operationId,
      }, context, { run: true });
      assert.equal(result.recoveredCurrentView, true);
      assert.deepEqual(closer.calls.slice(before).map(({ name }) => name), ['observeGlobalAll']);
      assert.equal(await closer.desktop.hasPendingJournal(), false);
    });
  }
});

test('focus前失敗留下expectedWindow null時，被動proof以原owner window結案但不改attempt', async () => {
  const fileSystem = memoryJournalFS();
  const record = legacyRecord();
  await seedJournal(fileSystem, record);
  const active = recoveryDesktop(fileSystem, {
    activateLine: () => ({ success: false }),
  });
  await assert.rejects(active.desktop.recoverGlobalAllNavigation({
    chatName: '測試對話', expectedOperationId: record.operationId,
  }, context, { run: true }));
  assert.equal(fileSystem.readJson(JOURNAL).recoveryAttempt.expectedWindow, null);

  const fresh = recoveryDesktop(fileSystem);
  const result = await fresh.desktop.recoverGlobalAllNavigation({
    chatName: '測試對話', expectedOperationId: record.operationId,
  }, context, { run: true });
  assert.equal(result.recoveredCurrentView, true);
  assert.deepEqual(fresh.calls.map(({ name }) => name), ['observeGlobalAll']);
});

test('CLI預設preview且輸出不含opid/nonce/HMAC，--run才執行', async () => {
  const operationId = `global-all-navigation:${hex('a')}`;
  const calls = [];
  const writes = [];
  const desktop = {
    async previewGlobalAllNavigationRecovery() {
      calls.push('preview');
      const result = { mode: 'preview', eligible: true, inputAttempted: false };
      Object.defineProperty(result, 'expectedOperationId', { value: operationId, enumerable: false });
      return result;
    },
    async recoverGlobalAllNavigation(args, _context, options) {
      calls.push({ args, options });
      return { mode: 'recovered', complete: true, inputAttempted: true };
    },
  };
  await runRecoveryCli(['--chat', '測試對話'], {
    makeDesktop: () => desktop,
    write: value => writes.push(JSON.stringify(value)),
  });
  assert.deepEqual(calls, ['preview']);
  assert.equal(writes[0].includes(operationId), false);

  calls.length = 0;
  writes.length = 0;
  await runRecoveryCli(['--chat', '測試對話', '--run'], {
    makeDesktop: () => desktop,
    write: value => writes.push(JSON.stringify(value)),
  });
  assert.equal(calls[0], 'preview');
  assert.equal(calls[1].args.expectedOperationId, operationId);
  assert.equal(writes[0].includes(operationId), false);
});
