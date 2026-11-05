import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { NativeBridge } from '../src/automation/native-bridge.js';
import { syntheticValidLINEWindow } from './fixtures/global-navigation-fixtures.mjs';

const code = error => error?.code;
const hex = character => character.repeat(64);
const nativeState = (overrides = {}) => ({
  version: 1,
  expectedWindow: {
    pid: 123, windowId: 88, title: 'LINE',
    bounds: { x: 0, y: 0, width: 900, height: 700 },
    bundleIdentifier: 'jp.naver.line.mac',
    executableURL: '/Applications/LINE.app/Contents/MacOS/LINE',
  },
  headerDigest: hex('b'), anchorHash: hex('c'), offset: 0, pageNumber: 0,
  advance: false, seenIds: [], dateContext: null,
  ...overrides,
});

test('listTabChats live scope 在編譯前驗 exact metadata，正確 scope 才抵達雙 disable', async () => {
  const previousNative = process.env.LINE_MCP_DISABLE_NATIVE;
  const previousUI = process.env.LINE_NATIVE_DISABLE_UI;
  process.env.LINE_MCP_DISABLE_NATIVE = '1';
  process.env.LINE_NATIVE_DISABLE_UI = '1';
  try {
    const bridge = new NativeBridge({
      liveScope: { tabName: 'Synthetic tab', chatName: 'Synthetic chat' },
    });
    const denied = [
      {},
      { tabName: 'Other tab', limit: 100, offset: 0 },
      { tabName: 'Synthetic tab', limit: 0, offset: 0 },
      { tabName: 'Synthetic tab', limit: 100, offset: 1001 },
      { tabName: 'Synthetic tab', limit: 100, offset: 0, expectedDigest: 'A'.repeat(64) },
      { tabName: 'Synthetic tab', limit: 100, offset: 0, expectedWindow: {} },
      { tabName: 'Synthetic tab', limit: 100, offset: 0, query: 'x' },
    ];
    for (const args of denied) {
      await assert.rejects(bridge.call('listTabChats', args), error => code(error) === 'LIVE_SCOPE_DENIED');
      assert.equal(bridge.binaryPromise, null);
    }
    await assert.rejects(
      bridge.call('listTabChats', {
        tabName: 'Synthetic tab', limit: 100, offset: 0, expectedDigest: 'a'.repeat(64),
      }),
      error => code(error) === 'NATIVE_DISABLED',
    );
    assert.equal(bridge.binaryPromise, null);
  } finally {
    if (previousNative === undefined) delete process.env.LINE_MCP_DISABLE_NATIVE;
    else process.env.LINE_MCP_DISABLE_NATIVE = previousNative;
    if (previousUI === undefined) delete process.env.LINE_NATIVE_DISABLE_UI;
    else process.env.LINE_NATIVE_DISABLE_UI = previousUI;
  }
});

test('live scope 的其他 body 與 mutation command 仍在 native 前拒絕', async () => {
  const bridge = new NativeBridge({
    liveScope: { tabName: 'Synthetic tab', chatName: 'Synthetic chat' },
  });
  for (const [name, args] of [
    ['previewMarkTabRead', { tabName: 'Synthetic tab' }],
    ['executeTabChange', { change: {}, index: 0 }],
    ['sendMessage', { tabName: 'Synthetic tab', chatName: 'Synthetic chat', message: 'x' }],
    ['readHistoryPage', { tabName: 'Synthetic tab', chatName: 'Other chat', limit: 5,
      identityKey: 'a'.repeat(64) }],
    ['selectGlobalAll', {
      chatName: 'Synthetic chat', requestNonce: hex('a'), expectedWindow: syntheticValidLINEWindow,
    }],
    ['observeGlobalAll', {
      chatName: 'Synthetic chat', requestNonce: hex('a'), expectedWindow: syntheticValidLINEWindow,
    }],
  ]) {
    await assert.rejects(bridge.call(name, args), error => code(error) === 'LIVE_SCOPE_DENIED');
    assert.equal(bridge.binaryPromise, null);
  }
});

test('name-band probe 在編譯前只接受 exact fixture 與固定參數', async () => {
  const previousNative = process.env.LINE_MCP_DISABLE_NATIVE;
  process.env.LINE_MCP_DISABLE_NATIVE = '1';
  try {
    const unscoped = new NativeBridge();
    await assert.rejects(unscoped.call('probeReadChatTitles', {
      tabName: 'Synthetic tab', chatName: 'Synthetic chat',
    }), error => code(error) === 'LIVE_SCOPE_DENIED');
    assert.equal(unscoped.binaryPromise, null);
    const bridge = new NativeBridge({
      liveScope: { tabName: 'Synthetic tab', chatName: 'Synthetic chat' },
    });
    for (const args of [
      {},
      { chatName: 'Synthetic chat' },
      { tabName: 'Synthetic tab' },
      { tabName: 'Other tab', chatName: 'Synthetic chat' },
      { tabName: 'Synthetic tab', chatName: 'Other chat' },
      { tabName: 'Synthetic tab', chatName: 'Synthetic chat', x: 1 },
    ]) {
      await assert.rejects(bridge.call('probeReadChatTitles', args),
        error => code(error) === 'LIVE_SCOPE_DENIED');
      assert.equal(bridge.binaryPromise, null);
    }
    await assert.rejects(bridge.call('probeReadChatTitles', {
      tabName: 'Synthetic tab', chatName: 'Synthetic chat',
    }), error => code(error) === 'NATIVE_DISABLED');
    assert.equal(bridge.binaryPromise, null);
  } finally {
    if (previousNative === undefined) delete process.env.LINE_MCP_DISABLE_NATIVE;
    else process.env.LINE_MCP_DISABLE_NATIVE = previousNative;
  }
});

test('AX scope probe 只接受 explicit exact fixture，正確 request 才抵達 fake native', async (t) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'line-ax-probe-scope-'));
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
  const unscoped = new NativeBridge({ execFile: fakeExecFile, sourcePath, cacheDir });
  await assert.rejects(unscoped.call('probeAXReadScope', {
    tabName: 'Synthetic tab', chatName: 'Synthetic chat',
  }), (error) => code(error) === 'LIVE_SCOPE_DENIED');
  assert.equal(calls.length, 0);

  const bridge = new NativeBridge({
    execFile: fakeExecFile,
    sourcePath,
    cacheDir,
    liveScope: { tabName: 'Synthetic tab', chatName: 'Synthetic chat' },
  });
  for (const args of [
    {},
    { tabName: 'Synthetic tab' },
    { chatName: 'Synthetic chat' },
    { tabName: 'Other tab', chatName: 'Synthetic chat' },
    { tabName: 'Synthetic tab', chatName: 'Other chat' },
    { tabName: 'Synthetic tab', chatName: 'Synthetic chat', extra: true },
  ]) {
    await assert.rejects(bridge.call('probeAXReadScope', args),
      (error) => code(error) === 'LIVE_SCOPE_DENIED');
    assert.equal(bridge.binaryPromise, null);
  }
  assert.deepEqual(await bridge.call('probeAXReadScope', {
    tabName: 'Synthetic tab', chatName: 'Synthetic chat',
  }), { accepted: true });
  const request = JSON.parse(calls.at(-1).input);
  assert.equal(request.name, 'probeAXReadScope');
  assert.deepEqual(request.args, { tabName: 'Synthetic tab', chatName: 'Synthetic chat' });
  assert.deepEqual(request.liveScope, { tabName: 'Synthetic tab', chatName: 'Synthetic chat' });
});

test('global liveScope 與 legacy scope 結構不得混用', () => {
  for (const liveScope of [
    { kind: 'global', chatName: '測試對話', tabName: 'All' },
    { kind: 'chat', chatName: '測試對話' },
    { kind: 'global', chatName: '媽\n媽' },
    { kind: 'global' },
    { tabName: 'All', chatName: '測試對話', kind: 'global' },
  ]) {
    assert.throws(() => new NativeBridge({ liveScope }), error => code(error) === 'INVALID_LIVE_SCOPE');
  }
  assert.deepEqual(new NativeBridge({ liveScope: { kind: 'global', chatName: '測試對話' } }).liveScope,
    { kind: 'global', chatName: '測試對話' });
});

test('global liveScope 在編譯前拒絕舊讀取、盤點、寫入、P2/P3 與 export command', async () => {
  const bridge = new NativeBridge({ liveScope: { kind: 'global', chatName: '測試對話' } });
  for (const [name, args] of [
    ['listTabs', { maxPages: 1 }],
    ['listTabChats', { tabName: 'All', limit: 100, offset: 0 }],
    ['selectChat', { tabName: 'All', chatName: '測試對話' }],
    ['getHistory', { tabName: 'All', chatName: '測試對話', limit: 5, pageUpTimes: 0 }],
    ['readHistoryPage', { tabName: 'All', chatName: '測試對話', limit: 5, identityKey: hex('a') }],
    ['probeReadChatTitles', { tabName: 'All', chatName: '測試對話' }],
    ['probeAXReadScope', { tabName: 'All', chatName: '測試對話' }],
    ['prepareTextExportScope', { tabName: 'All', chatName: '測試對話', identityKey: hex('a'), requestNonce: hex('b') }],
    ['exportChatText', { tabName: 'All', chatName: '測試對話' }],
    ['sendMessage', { chatName: '測試對話', message: 'x' }],
    ['previewTabChanges', { changes: [] }],
    ['executeTabChange', { change: {}, index: 0 }],
  ]) {
    await assert.rejects(bridge.call(name, args), error => code(error) === 'LIVE_SCOPE_DENIED');
    assert.equal(bridge.binaryPromise, null);
  }
});

test('global selector/read args 必須 exact 且完整，合法 request 才抵達雙 disable', async () => {
  const previousNative = process.env.LINE_MCP_DISABLE_NATIVE;
  const previousUI = process.env.LINE_NATIVE_DISABLE_UI;
  process.env.LINE_MCP_DISABLE_NATIVE = '1';
  process.env.LINE_NATIVE_DISABLE_UI = '1';
  try {
    const bridge = new NativeBridge({ liveScope: { kind: 'global', chatName: '測試對話' } });
    for (const args of [
      {},
      { chatName: 'Other', requestNonce: hex('a'), expectedWindow: syntheticValidLINEWindow },
      { chatName: '測試對話', requestNonce: 'A'.repeat(64), expectedWindow: syntheticValidLINEWindow },
      { chatName: '測試對話', requestNonce: hex('a'), expectedWindow: null },
      { chatName: '測試對話', requestNonce: hex('a'), expectedWindow: {
        ...syntheticValidLINEWindow, title: 'Other',
      } },
      { chatName: '測試對話', requestNonce: hex('a'), expectedWindow: syntheticValidLINEWindow, extra: true },
    ]) {
      await assert.rejects(bridge.call('selectGlobalAll', args),
        error => code(error) === 'LIVE_SCOPE_DENIED');
      assert.equal(bridge.binaryPromise, null);
    }
    await assert.rejects(bridge.call('selectGlobalAll', {
      chatName: '測試對話', requestNonce: hex('a'), expectedWindow: syntheticValidLINEWindow,
    }), error => code(error) === 'NATIVE_DISABLED');
    assert.equal(bridge.binaryPromise, null);
    await assert.rejects(bridge.call('observeGlobalAll', {
      chatName: '測試對話', requestNonce: hex('a'), expectedWindow: syntheticValidLINEWindow,
    }), error => code(error) === 'NATIVE_DISABLED');
    assert.equal(bridge.binaryPromise, null);
    for (const args of [
      {},
      { chatName: 'Other', limit: 5, identityKey: hex('a') },
      { chatName: '測試對話', tabName: 'All', limit: 5, identityKey: hex('a') },
      { chatName: '測試對話', limit: 0, identityKey: hex('a') },
      { chatName: '測試對話', limit: 5, identityKey: 'A'.repeat(64) },
      { chatName: '測試對話', limit: 5, identityKey: hex('a'), nativeState: null },
      { chatName: '測試對話', limit: 5, identityKey: hex('a'), nativeState: { provider: 'export' } },
      { chatName: '測試對話', limit: 5, identityKey: hex('a'), nativeState: nativeState({ offset: 2_001 }) },
      { chatName: '測試對話', limit: 5, identityKey: hex('a'), nativeState: nativeState({
        dateContext: { date: '2026-02-30', anchorHash: hex('d') },
      }) },
      { chatName: '測試對話', limit: 5, identityKey: hex('a'), extra: true },
      { chatName: '測試對話', resultIndex: 1, limit: 5, identityKey: hex('a') },
    ]) {
      await assert.rejects(bridge.call('readGlobalHistoryPage', args),
        error => code(error) === 'LIVE_SCOPE_DENIED');
      assert.equal(bridge.binaryPromise, null);
    }
    await assert.rejects(bridge.call('readGlobalHistoryPage', {
      chatName: '測試對話', limit: 5, identityKey: hex('a'), nativeState: nativeState(),
    }), error => code(error) === 'NATIVE_DISABLED');
    assert.equal(bridge.binaryPromise, null);
    for (const name of ['status', 'processStatus', 'accessibilityStatus', 'activateLine']) {
      await assert.rejects(bridge.call(name, {}), error => code(error) === 'NATIVE_DISABLED');
      assert.equal(bridge.binaryPromise, null);
    }
  } finally {
    if (previousNative === undefined) delete process.env.LINE_MCP_DISABLE_NATIVE;
    else process.env.LINE_MCP_DISABLE_NATIVE = previousNative;
    if (previousUI === undefined) delete process.env.LINE_NATIVE_DISABLE_UI;
    else process.env.LINE_NATIVE_DISABLE_UI = previousUI;
  }
});

test('legacy liveScope 拒絕 global command，global exact request 不補 tabName', async (t) => {
  const legacy = new NativeBridge({ liveScope: { tabName: 'All', chatName: '測試對話' } });
  await assert.rejects(legacy.call('readGlobalHistoryPage', {
    chatName: '測試對話', limit: 5, identityKey: hex('a'),
  }), error => code(error) === 'LIVE_SCOPE_DENIED');
  await assert.rejects(legacy.call('selectGlobalAll', {
    chatName: '測試對話', requestNonce: hex('a'), expectedWindow: syntheticValidLINEWindow,
  }), error => code(error) === 'LIVE_SCOPE_DENIED');
  await assert.rejects(legacy.call('observeGlobalAll', {
    chatName: '測試對話', requestNonce: hex('a'), expectedWindow: syntheticValidLINEWindow,
  }), error => code(error) === 'LIVE_SCOPE_DENIED');
  assert.equal(legacy.binaryPromise, null);

  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'line-global-scope-'));
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
  const global = new NativeBridge({
    execFile: fakeExecFile, sourcePath, cacheDir,
    liveScope: { kind: 'global', chatName: '測試對話' },
  });
  assert.deepEqual(await global.call('selectGlobalAll', {
    chatName: '測試對話', requestNonce: hex('a'), expectedWindow: syntheticValidLINEWindow,
  }), { accepted: true });
  let request = JSON.parse(calls.at(-1).input);
  assert.equal(request.name, 'selectGlobalAll');
  assert.deepEqual(Object.keys(request.args).sort(),
    ['chatName', 'expectedWindow', 'requestNonce'].sort());
  assert.equal(request.args.tabName, undefined);
  assert.deepEqual(request.liveScope, { kind: 'global', chatName: '測試對話' });

  assert.deepEqual(await global.call('observeGlobalAll', {
    chatName: '測試對話', requestNonce: hex('b'), expectedWindow: syntheticValidLINEWindow,
  }), { accepted: true });
  request = JSON.parse(calls.at(-1).input);
  assert.equal(request.name, 'observeGlobalAll');
  assert.equal(request.args.tabName, undefined);
  assert.deepEqual(request.liveScope, { kind: 'global', chatName: '測試對話' });

  assert.deepEqual(await global.call('readGlobalHistoryPage', {
    chatName: '測試對話', limit: 5, identityKey: hex('a'), nativeState: nativeState(),
  }), { accepted: true });
  request = JSON.parse(calls.at(-1).input);
  assert.equal(request.name, 'readGlobalHistoryPage');
  assert.equal(request.args.tabName, undefined);
  assert.deepEqual(Object.keys(request.args).sort(),
    ['chatName', 'identityKey', 'limit', 'nativeState'].sort());
  assert.deepEqual(request.liveScope, { kind: 'global', chatName: '測試對話' });

  const indexed = new NativeBridge({
    execFile: fakeExecFile, sourcePath, cacheDir: path.join(directory, 'indexed-cache'),
    liveScope: { kind: 'global', chatName: '測試對話', resultIndex: 2 },
  });
  await assert.rejects(indexed.call('readGlobalHistoryPage', {
    chatName: '測試對話', resultIndex: 1, limit: 5, identityKey: hex('a'),
  }), error => code(error) === 'LIVE_SCOPE_DENIED');
  assert.deepEqual(await indexed.call('readGlobalHistoryPage', {
    chatName: '測試對話', resultIndex: 2, limit: 5, identityKey: hex('a'),
  }), { accepted: true });
  request = JSON.parse(calls.at(-1).input);
  assert.equal(request.args.resultIndex, 2);
  assert.deepEqual(request.liveScope, { kind: 'global', chatName: '測試對話', resultIndex: 2 });
});
