import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  NativeTextExportReader,
  textExportProofDigest,
} from '../src/automation/native-text-export.js';
import { NativeBridge } from '../src/automation/native-bridge.js';

const hex = (character) => character.repeat(64);
const scope = { tabName: 'Tab', chatName: 'Room' };
const windowIdentity = {
  pid: 123, windowId: 88, title: 'LINE',
  bounds: { x: 1, y: 2, width: 900, height: 700 },
  bundleIdentifier: 'jp.naver.line.mac',
  executableURL: '/Applications/LINE.app/Contents/MacOS/LINE',
  signingIdentifier: 'jp.naver.line.mac',
  teamIdentifier: 'VUTU7AKEUR',
};

function proof(identityKey, requestNonce, overrides = {}) {
  const value = {
    scope: { ...scope, verified: true },
    window: windowIdentity,
    headerDigest: hex('a'),
    memberMatchCount: 1,
    selectedMatchCount: 1,
    headerMatchCount: 1,
    selectedTabVerified: true,
    requestNonce,
    ...overrides,
  };
  return { ...value, proofDigest: textExportProofDigest(identityKey, value) };
}

function captureWith(text, overrides = {}) {
  return async (request) => {
    const output = path.join(request.outputDirectory, request.outputFileName);
    await fs.writeFile(output, overrides.bytes || Buffer.from(text, 'utf8'), { mode: 0o600 });
    const pre = proof(request.identityKey, request.requestNonce, overrides.pre || {});
    const post = proof(request.identityKey, request.requestNonce, overrides.post || {});
    return {
      scope: { ...scope, verified: true },
      observedAt: '2026-10-27T00:00:00.000Z',
      source: 'NATIVE_TEXT_EXPORT',
      uiRestored: true,
      completionVerified: true,
      preActionProof: pre,
      postActionProof: post,
      ...overrides.receipt,
    };
  };
}

function readerWith(capture, overrides = {}) {
  let token = 0;
  return new NativeTextExportReader({
    capture,
    tempRoot: overrides.tempRoot || os.tmpdir(),
    quietIntervalMs: 0,
    wait: async () => {},
    randomBytes: (length) => Buffer.alloc(length, ++token),
    ...overrides,
  });
}

test('原生文字 export 以不可變 snapshot 分頁，重複文字仍有不同 ID 且 terminal 清理', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'line-export-test-'));
  const text = `${'😀'.repeat(2300)}\n${'same'.repeat(1100)}\n${'same'.repeat(1100)}`;
  const reader = readerWith(captureWith(text), { tempRoot: root });
  const request = { ...scope, identityKey: hex('1'), limit: 1 };
  const first = await reader.readPage(request);
  assert.equal(first.envelope.observations.length, 1);
  assert.equal(Array.from(first.envelope.observations[0].text).at(-1), '😀');
  assert.equal(first.envelope.observations[0].date, null);
  assert.equal(first.envelope.observations[0].identityVerified, false);
  assert.deepEqual(first.envelope.observations[0].provenance,
    { source: 'NATIVE_TEXT_EXPORT', complete: false });
  assert.equal(first.envelope.complete, false);
  assert.equal(first.envelope.possibleDuplicates, true);
  assert(first.exportState);

  const ids = [first.envelope.observations[0].observedId];
  let state = first.exportState;
  while (state) {
    const page = await reader.readPage({ ...request, state });
    ids.push(...page.envelope.observations.map((item) => item.observedId));
    assert.equal(page.envelope.snapshotDigest, first.envelope.snapshotDigest);
    state = page.exportState;
  }
  assert.equal(new Set(ids).size, ids.length);
  assert.equal(reader.snapshots.size, 0);
  assert.deepEqual(await fs.readdir(root), []);
  await fs.rmdir(root);
});

test('UTF BOM 無損解析；無 BOM NUL、錯 scope proof 與 pre/post 漂移拒絕', async (t) => {
  await t.test('UTF-16LE BOM', async () => {
    const bytes = Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from('內容', 'utf16le')]);
    const reader = readerWith(captureWith('', { bytes }));
    const page = await reader.readPage({ ...scope, identityKey: hex('2'), limit: 5 });
    assert.equal(page.envelope.observations[0].text, '內容');
  });
  await t.test('NUL', async () => {
    const reader = readerWith(captureWith('', { bytes: Buffer.from([0x61, 0, 0x62]) }));
    await assert.rejects(reader.readPage({ ...scope, identityKey: hex('3'), limit: 5 }),
      (error) => error.code === 'EXPORT_ENCODING_UNSUPPORTED');
  });
  await t.test('UTF-16BE BOM', async () => {
    const little = Buffer.from('內容', 'utf16le');
    const body = Buffer.from(little);
    body.swap16();
    const reader = readerWith(captureWith('', {
      bytes: Buffer.concat([Buffer.from([0xfe, 0xff]), body]),
    }));
    const page = await reader.readPage({ ...scope, identityKey: hex('3'), limit: 5 });
    assert.equal(page.envelope.observations[0].text, '內容');
  });
  await t.test('invalid UTF-8', async () => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'line-invalid-export-'));
    const reader = readerWith(captureWith('', { bytes: Buffer.from([0xc3, 0x28]) }), {
      tempRoot: root,
    });
    await assert.rejects(reader.readPage({ ...scope, identityKey: hex('3'), limit: 5 }),
      (error) => error.code === 'EXPORT_ENCODING_UNSUPPORTED');
    assert.equal(reader.recoveryLatch, null);
    assert.deepEqual(await fs.readdir(root), [], '已確認的壞編碼檔必須安全清除');
    await fs.rmdir(root);
  });
  await t.test('wrong scope', async () => {
    const reader = readerWith(captureWith('secret', {
      receipt: { scope: { tabName: 'Other', chatName: 'Room', verified: true } },
    }));
    await assert.rejects(reader.readPage({ ...scope, identityKey: hex('4'), limit: 5 }),
      (error) => error.code === 'NATIVE_PROTOCOL_ERROR');
  });
  await t.test('post proof drift', async () => {
    const reader = readerWith(captureWith('secret', { post: { headerDigest: hex('b') } }));
    await assert.rejects(reader.readPage({ ...scope, identityKey: hex('5'), limit: 5 }),
      (error) => error.code === 'NATIVE_PROTOCOL_ERROR');
  });
});

test('pre-action calibration unavailable 才回 null；post-action 錯誤建立 recovery latch', async () => {
  const unavailable = readerWith(async () => {
    const error = new Error('calibration');
    error.code = 'AX_EXPORT_CALIBRATION_REQUIRED';
    error.details = { sideEffectsAttempted: false };
    throw error;
  });
  assert.equal(await unavailable.readPage({ ...scope, identityKey: hex('6'), limit: 5 }), null);
  assert.equal(unavailable.recoveryLatch, null);

  const uncertain = readerWith(async () => {
    const error = new Error('unknown');
    error.code = 'NATIVE_TIMEOUT';
    error.details = { phase: 'unknown' };
    throw error;
  });
  await assert.rejects(uncertain.readPage({ ...scope, identityKey: hex('7'), limit: 5 }),
    (error) => error.code === 'NATIVE_TIMEOUT');
  await assert.rejects(uncertain.readPage({ ...scope, identityKey: hex('7'), limit: 5 }),
    (error) => error.code === 'NEEDS_RECOVERY');
});

test('宣稱 pre-action unavailable 卻留下檔案時不得 fallback', async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'line-preaction-lie-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  let evidencePath;
  const reader = readerWith(async (request) => {
    evidencePath = path.join(request.outputDirectory, request.outputFileName);
    await fs.writeFile(evidencePath, 'unexpected', { mode: 0o600 });
    const error = new Error('calibration');
    error.code = 'AX_EXPORT_CALIBRATION_REQUIRED';
    error.details = { sideEffectsAttempted: false };
    throw error;
  }, { tempRoot: root });
  await assert.rejects(reader.readPage({ ...scope, identityKey: hex('7'), limit: 5 }),
    (error) => error.code === 'OPERATION_UNCERTAIN' && error.details.needsRecovery === true);
  assert.equal(reader.recoveryLatch.needsRecovery, true);
  assert.equal(await fs.readFile(evidencePath, 'utf8'), 'unexpected',
    '矛盾的 pre-action evidence 不得被自動刪除');
});

test('symlink、hardlink、超量與 path／寫入中替換都不會被讀取', async (t) => {
  await t.test('symlink', async () => {
    const reader = readerWith(async (request) => {
      const target = path.join(request.outputDirectory, 'target');
      await fs.writeFile(target, 'secret');
      await fs.symlink(target, path.join(request.outputDirectory, request.outputFileName));
      const pre = proof(request.identityKey, request.requestNonce);
      return {
        scope: { ...scope, verified: true }, observedAt: new Date().toISOString(),
        source: 'NATIVE_TEXT_EXPORT', uiRestored: true, completionVerified: true,
        preActionProof: pre, postActionProof: pre,
      };
    });
    await assert.rejects(reader.readPage({ ...scope, identityKey: hex('8'), limit: 5 }));
  });
  await t.test('hardlink', async () => {
    const reader = readerWith(async (request) => {
      const output = path.join(request.outputDirectory, request.outputFileName);
      await fs.writeFile(output, 'secret', { mode: 0o600 });
      await fs.link(output, path.join(request.outputDirectory, 'second'));
      const pre = proof(request.identityKey, request.requestNonce);
      return {
        scope: { ...scope, verified: true }, observedAt: new Date().toISOString(),
        source: 'NATIVE_TEXT_EXPORT', uiRestored: true, completionVerified: true,
        preActionProof: pre, postActionProof: pre,
      };
    });
    await assert.rejects(reader.readPage({ ...scope, identityKey: hex('9'), limit: 5 }),
      (error) => error.code === 'EXPORT_FILE_UNSAFE');
  });
  await t.test('oversized', async () => {
    const reader = readerWith(async (request) => {
      const output = path.join(request.outputDirectory, request.outputFileName);
      await fs.writeFile(output, Buffer.alloc(8 * 1024 * 1024 + 1), { mode: 0o600 });
      const pre = proof(request.identityKey, request.requestNonce);
      return {
        scope: { ...scope, verified: true }, observedAt: new Date().toISOString(),
        source: 'NATIVE_TEXT_EXPORT', uiRestored: true, completionVerified: true,
        preActionProof: pre, postActionProof: pre,
      };
    });
    await assert.rejects(reader.readPage({ ...scope, identityKey: hex('a'), limit: 5 }),
      (error) => error.code === 'EXPORT_FILE_UNSAFE');
  });
  await t.test('path replaced during quiet interval', async () => {
    let output;
    const capture = async (request) => {
      output = path.join(request.outputDirectory, request.outputFileName);
      await fs.writeFile(output, 'before', { mode: 0o600 });
      const pre = proof(request.identityKey, request.requestNonce);
      return {
        scope: { ...scope, verified: true }, observedAt: new Date().toISOString(),
        source: 'NATIVE_TEXT_EXPORT', uiRestored: true, completionVerified: true,
        preActionProof: pre, postActionProof: pre,
      };
    };
    let changed = false;
    const reader = readerWith(capture, {
      wait: async () => {
        if (!changed) {
          changed = true;
          await fs.rename(output, `${output}.old`);
          await fs.writeFile(output, 'after', { mode: 0o600 });
        }
      },
    });
    await assert.rejects(reader.readPage({ ...scope, identityKey: hex('a'), limit: 5 }),
      (error) => ['EXPORT_FILE_UNSTABLE', 'EXPORT_FILE_REPLACED'].includes(error.code));
  });
  await t.test('file changed during quiet interval', async () => {
    let output;
    const capture = async (request) => {
      output = path.join(request.outputDirectory, request.outputFileName);
      await fs.writeFile(output, 'before', { mode: 0o600 });
      const pre = proof(request.identityKey, request.requestNonce);
      return {
        scope: { ...scope, verified: true }, observedAt: new Date().toISOString(),
        source: 'NATIVE_TEXT_EXPORT', uiRestored: true, completionVerified: true,
        preActionProof: pre, postActionProof: pre,
      };
    };
    const reader = readerWith(capture, {
      wait: async () => fs.appendFile(output, ' changed'),
    });
    await assert.rejects(reader.readPage({ ...scope, identityKey: hex('a'), limit: 5 }),
      (error) => error.code === 'EXPORT_FILE_UNSTABLE');
  });
  await t.test('same-size content changed during quiet interval', async () => {
    let output;
    const capture = async (request) => {
      output = path.join(request.outputDirectory, request.outputFileName);
      await fs.writeFile(output, 'before', { mode: 0o600 });
      const pre = proof(request.identityKey, request.requestNonce);
      return {
        scope: { ...scope, verified: true }, observedAt: new Date().toISOString(),
        source: 'NATIVE_TEXT_EXPORT', uiRestored: true, completionVerified: true,
        preActionProof: pre, postActionProof: pre,
      };
    };
    const reader = readerWith(capture, {
      wait: async () => fs.writeFile(output, 'AFTER!', { mode: 0o600 }),
    });
    await assert.rejects(reader.readPage({ ...scope, identityKey: hex('a'), limit: 5 }),
      (error) => error.code === 'EXPORT_FILE_UNSTABLE');
  });
  await t.test('directory replaced before open', async () => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'line-dir-replace-'));
    t.after(() => fs.rm(root, { recursive: true, force: true }));
    const reader = readerWith(async (request) => {
      const output = path.join(request.outputDirectory, request.outputFileName);
      await fs.writeFile(output, 'secret', { mode: 0o600 });
      await fs.rename(request.outputDirectory, `${request.outputDirectory}.old`);
      await fs.mkdir(request.outputDirectory, { mode: 0o700 });
      const pre = proof(request.identityKey, request.requestNonce);
      return {
        scope: { ...scope, verified: true }, observedAt: new Date().toISOString(),
        source: 'NATIVE_TEXT_EXPORT', uiRestored: true, completionVerified: true,
        preActionProof: pre, postActionProof: pre,
      };
    }, { tempRoot: root });
    await assert.rejects(reader.readPage({ ...scope, identityKey: hex('a'), limit: 5 }),
      (error) => error.code === 'EXPORT_DIRECTORY_REPLACED');
  });
});

test('reader 只用有界 FD read；quiet 後 append 最多讀 size+1 並拒絕', async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'line-bounded-read-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  let output;
  let readFileCalled = false;
  let appended = false;
  const proxyFs = {
    ...fs,
    async open(file, flags) {
      const handle = await fs.open(file, flags);
      return new Proxy(handle, {
        get(target, property) {
          if (property === 'readFile') return async () => { readFileCalled = true; throw new Error('unbounded'); };
          if (property === 'read') return async (...args) => {
            if (!appended) { appended = true; await fs.appendFile(output, '!'); }
            return target.read(...args);
          };
          const value = target[property];
          return typeof value === 'function' ? value.bind(target) : value;
        },
      });
    },
  };
  const reader = readerWith(async (request) => {
    output = path.join(request.outputDirectory, request.outputFileName);
    await fs.writeFile(output, 'stable', { mode: 0o600 });
    const pre = proof(request.identityKey, request.requestNonce);
    return {
      scope: { ...scope, verified: true }, observedAt: new Date().toISOString(),
      source: 'NATIVE_TEXT_EXPORT', uiRestored: true, completionVerified: true,
      preActionProof: pre, postActionProof: pre,
    };
  }, { tempRoot: root, fileSystem: proxyFs });
  await assert.rejects(reader.readPage({ ...scope, identityKey: hex('a'), limit: 5 }),
    (error) => error.code === 'EXPORT_FILE_UNSTABLE');
  assert.equal(readFileCalled, false, '不得使用無界 readFile');
});

test('成功讀檔後 cleanup 不乾淨時不留下 orphan snapshot', async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'line-cleanup-uncertain-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const reader = readerWith(async (request) => {
    await fs.writeFile(path.join(request.outputDirectory, request.outputFileName), 'body', { mode: 0o600 });
    await fs.writeFile(path.join(request.outputDirectory, 'foreign'), 'keep', { mode: 0o600 });
    const pre = proof(request.identityKey, request.requestNonce);
    return {
      scope: { ...scope, verified: true }, observedAt: new Date().toISOString(),
      source: 'NATIVE_TEXT_EXPORT', uiRestored: true, completionVerified: true,
      preActionProof: pre, postActionProof: pre,
    };
  }, { tempRoot: root });
  await assert.rejects(reader.readPage({ ...scope, identityKey: hex('a'), limit: 5 }),
    (error) => error.code === 'EXPORT_CLEANUP_UNCERTAIN');
  assert.equal(reader.snapshots.size, 0);
  assert.equal(reader.cacheBytes, 0);
  assert.equal(reader.recoveryLatch.needsRecovery, true);
});

test('exportState 綁 scope、digest、offset 與 cache；失效 state 不會重新 capture', async () => {
  let captures = 0;
  const reader = readerWith(async (request) => {
    captures += 1;
    return captureWith('x'.repeat(5000))(request);
  });
  const first = await reader.readPage({ ...scope, identityKey: hex('b'), limit: 1 });
  await assert.rejects(reader.readPage({
    ...scope, chatName: 'Other', identityKey: hex('b'), limit: 1, state: first.exportState,
  }), (error) => error.code === 'CURSOR_INVALID');
  assert.equal(captures, 1);
});

test('cache 容量在 capture 前拒絕，過期 continuation 不會重匯出', async () => {
  let captures = 0;
  let now = 1_000;
  const reader = readerWith(async (request) => {
    captures += 1;
    return captureWith('x'.repeat(5000))(request);
  }, { now: () => now });
  reader.cacheBytes = 4 * 1024 * 1024 + 1;
  await assert.rejects(reader.readPage({ ...scope, identityKey: hex('b'), limit: 1 }),
    (error) => error.code === 'EXPORT_CACHE_FULL');
  assert.equal(captures, 0);

  reader.cacheBytes = 0;
  const first = await reader.readPage({ ...scope, identityKey: hex('b'), limit: 1 });
  assert(first.exportState);
  now += 5 * 60_000 + 1;
  await assert.rejects(reader.readPage({
    ...scope, identityKey: hex('b'), limit: 1, state: first.exportState,
  }), (error) => error.code === 'CURSOR_INVALID');
  assert.equal(captures, 1);
});

test('proof digest 重綁定或少欄位時 fail closed', () => {
  const identityKey = hex('c');
  const nonce = 'd'.repeat(32);
  const value = proof(identityKey, nonce);
  const modified = { ...value, selectedMatchCount: 0 };
  assert.notEqual(textExportProofDigest(identityKey, modified), value.proofDigest);
  assert.equal(crypto.timingSafeEqual(
    Buffer.from(textExportProofDigest(identityKey, value), 'hex'),
    Buffer.from(value.proofDigest, 'hex')
  ), true);
});

test('proof HMAC canonical codec 有固定跨語言向量', () => {
  const value = {
    scope: { tabName: 'Tab/分類', chatName: 'Room/對話', verified: true },
    window: windowIdentity,
    headerDigest: hex('a'), memberMatchCount: 1, selectedMatchCount: 1,
    headerMatchCount: 1, selectedTabVerified: true, requestNonce: 'b'.repeat(32),
  };
  assert.equal(textExportProofDigest('c'.repeat(64), value),
    'e06db1d023959e75d922f6d2b895a7723555311ddab36a881420136638756df8');
});

test('NativeBridge 先驗 scope proof 才呼叫 export，且 live scope／路徑由內部固定', async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'line-export-bridge-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const sourcePath = path.join(root, 'helper.swift');
  const cacheDir = path.join(root, 'cache');
  await fs.writeFile(sourcePath, 'print("fixture")');
  const calls = [];
  const identityKey = hex('d');
  const requestNonce = 'e'.repeat(32);
  const fakeExecFile = (file, args, _options, callback) => {
    const call = { file, input: '' };
    calls.push(call);
    return { stdin: { on() {}, end(input) {
      call.input = input;
      if (file === '/usr/bin/swiftc') {
        fs.writeFile(args.at(-1), 'binary').then(() => callback(null, '', ''));
        return;
      }
      const request = JSON.parse(input);
      if (request.name === 'prepareTextExportScope') {
        const prepared = proof(identityKey, requestNonce);
        callback(null, JSON.stringify({ ok: true, result: prepared }), '');
        return;
      }
      assert.equal(request.name, 'exportChatText');
      const prepared = proof(identityKey, requestNonce);
      callback(null, JSON.stringify({ ok: true, result: {
        scope: { ...scope, verified: true }, observedAt: new Date().toISOString(),
        source: 'NATIVE_TEXT_EXPORT', uiRestored: true, completionVerified: true,
        preActionProof: prepared, postActionProof: prepared,
      } }), '');
    } } };
  };
  const bridge = new NativeBridge({
    execFile: fakeExecFile, sourcePath, cacheDir, liveScope: scope,
  });
  await bridge.exportChatText({
    ...scope, identityKey, requestNonce,
    outputDirectory: root, outputFileName: `${'f'.repeat(32)}.txt`,
  });
  const requests = calls.filter((call) => call.file !== '/usr/bin/swiftc')
    .map((call) => JSON.parse(call.input));
  assert.deepEqual(requests.map((item) => item.name), ['prepareTextExportScope', 'exportChatText']);
  assert.deepEqual(requests[0].liveScope, scope);
  assert.equal(requests[1].args.expectedProofDigest, requests[0].args.identityKey
    ? proof(identityKey, requestNonce).proofDigest : null);

  const denied = new NativeBridge({ execFile: fakeExecFile, sourcePath, cacheDir, liveScope: scope });
  await assert.rejects(denied.exportChatText({
    ...scope, chatName: 'Other', identityKey, requestNonce,
    outputDirectory: root, outputFileName: `${'a'.repeat(32)}.txt`,
  }), (error) => error.code === 'LIVE_SCOPE_DENIED');
});
