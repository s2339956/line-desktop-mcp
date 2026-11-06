import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { LineDesktopMCPServer } from '../src/server.js';
import { MacOSDesktopAutomation } from '../src/automation/desktop-automation.js';
import { NativeBridge } from '../src/automation/native-bridge.js';
import { OperationLock } from '../src/automation/operation-lock.js';
import { withRequestControl, requestPause } from '../src/automation/request-control.js';
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
const context = { transport: 'stdio', sessionId: 'synthetic-cancel-session' };

async function fixture(t, handler, settle = async () => {}) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'line-cancel-fixture-'));
  const files = [], calls = [], id = crypto.randomUUID();
  for (let i = 0; i < 2; i++) {
    const filePath = path.join(directory, `synthetic-${i}.txt`), data = Buffer.from(`SYNTHETIC_${id}_${i}`);
    await fs.writeFile(filePath, data);
    files.push({ filePath, fileSha256: crypto.createHash('sha256').update(data).digest('hex') });
  }
  const lock = new OperationLock({ lockPath: path.join(directory, 'ui.lock'), timeoutMs: 2000 });
  const desktop = new MacOSDesktopAutomation({ lock, journalPath: path.join(directory, 'pending.json'),
    attachmentSettle: settle, bridge: { async call(name, args) {
      calls.push({ name, args });
      if (handler) await handler(name, args, calls.length);
      if (name === 'inspectImage') return { sourceSha256: args.imageSha256, uiAccessed: false, width: 1, height: 1 };
      return { success: true, autoSent: true, chatVerified: true, selectedFileVerified: true,
        sourceSha256: args.fileSha256, fileSha256: args.fileSha256, byteCount: (await fs.stat(args.filePath)).size,
        receipt: { status: 'UI_SUBMITTED', deliveryConfirmed: false } };
    } } });
  t.after(async () => {
    // 只刪此測試隨機內容hash所建立的合成快照，絕不觸及其他操作。
    for (const name of await fs.readdir(os.tmpdir())) if (files.some(file => name.startsWith(`line-mcp-attachment-${file.fileSha256}-`))) {
      await fs.rm(path.join(os.tmpdir(), name), { recursive: true, force: true });
    }
    await fs.rm(directory, { recursive: true, force: true });
  });
  return { desktop, lock, calls, directory, args: { chatName: '合成對話', requestId: id, files } };
}

test('呼叫前已停止：不排隊、不建請求、不碰UI', async t => {
  const f = await fixture(t), controller = new AbortController(); controller.abort();
  await assert.rejects(withRequestControl({ signal: controller.signal }, () => f.desktop.call('line_send_files', f.args, context)), { code: 'REQUEST_CANCELLED' });
  assert.equal(f.calls.length, 0);
  assert.deepEqual(await f.desktop.call('line_operation_status', { requestId: f.args.requestId }, context), { found: false });
});

test('排隊中停止立即離隊，持鎖者不受影響，後續請求仍可取得鎖', async t => {
  const f = await fixture(t), held = deferred(), release = deferred(), controller = new AbortController();
  const owner = f.lock.withLock(async () => { held.resolve(); await release.promise; });
  await held.promise;
  const queued = withRequestControl({ signal: controller.signal }, () => f.desktop.call('line_send_files', f.args, context));
  controller.abort();
  await assert.rejects(queued, { code: 'REQUEST_CANCELLED' });
  assert.equal(f.calls.length, 0); release.resolve(); await owner;
  const result = await f.desktop.call('line_send_files', f.args, context);
  assert.equal(result.completedCount, 2);
});

test('圖片預驗中停止：尚未建立提交journal，保留可查的零提交停止狀態', async t => {
  const controller = new AbortController();
  const f = await fixture(t, () => controller.abort());
  const args = { chatName: f.args.chatName, requestId: f.args.requestId,
    images: f.args.files.map(file => ({ imagePath: file.filePath, imageSha256: file.fileSha256 })) };
  const result = await withRequestControl({ signal: controller.signal }, () => f.desktop.call('line_send_images', args, context));
  assert.equal(result.cancelled, true); assert.equal(result.completedCount, 0);
  assert.ok(f.calls.every(call => call.name === 'inspectImage'));
  const status = await f.desktop.call('line_operation_status', { requestId: args.requestId }, context);
  assert.equal(status.state, 'cancelled'); assert.equal(status.needsRecovery, false);
  await assert.rejects(fs.stat(path.join(f.directory, 'pending.json')), { code: 'ENOENT' });
});

test('真MCP停止第一項後不續送，另一請求可查進度，重連同ID只回停止回條', async t => {
  const between = deferred(), resume = deferred(), finished = deferred();
  const f = await fixture(t, undefined, async () => { between.resolve(); await resume.promise; });
  const server = new LineDesktopMCPServer({ async desktopCall(...args) {
    try { return await f.desktop.call(...args); } finally { if (args[0] === 'line_send_files') finished.resolve(); }
  } });
  const client = new Client({ name: 'synthetic-cancel-client', version: '1.0.0' });
  const [a, b] = InMemoryTransport.createLinkedPair(); await server.server.connect(b); await client.connect(a);
  t.after(async () => { resume.resolve(); await client.close(); await server.server.close(); });
  const controller = new AbortController();
  const pending = client.callTool({ name: 'line_send_files', arguments: f.args }, undefined, { signal: controller.signal }).catch(() => ({ aborted: true }));
  await between.promise;
  controller.abort(); assert.equal((await pending).aborted, true);
  // 協定取消通知需先送達server；讓事件迴圈完成，不碰原生UI。
  await new Promise(resolve => setImmediate(resolve)); resume.resolve(); await finished.promise;
  const status = await client.callTool({ name: 'line_operation_status', arguments: { requestId: f.args.requestId } });
  assert.equal(status.structuredContent.state, 'cancelled'); assert.equal(status.structuredContent.result.completedCount, 1);
  assert.equal(f.calls.length, 1);
  const replay = await f.desktop.call('line_send_files', f.args, context);
  assert.equal(replay.replayed, true); assert.equal(replay.cancelled, true); assert.equal(f.calls.length, 1);
});

test('原生呼叫途中停止：不強殺，可靠回條保存後停止下一項', async t => {
  const started = deferred(), complete = deferred(), controller = new AbortController();
  const f = await fixture(t, async () => { started.resolve(); await complete.promise; });
  const pending = withRequestControl({ signal: controller.signal }, () => f.desktop.call('line_send_files', f.args, context));
  await started.promise; controller.abort(); complete.resolve();
  const result = await pending;
  assert.equal(result.cancelled, true); assert.equal(result.completedCount, 1); assert.equal(f.calls.length, 1);
});

test('途中停止但原生結果不明：維持uncertain與journal，不能降級成安全取消', async t => {
  const controller = new AbortController();
  const f = await fixture(t, () => { controller.abort(); throw Object.assign(new Error('synthetic'), { code: 'NATIVE_TIMEOUT' }); });
  await assert.rejects(withRequestControl({ signal: controller.signal }, () => f.desktop.call('line_send_files', f.args, context)), { code: 'OPERATION_UNCERTAIN' });
  const status = await f.desktop.call('line_operation_status', { requestId: f.args.requestId }, context);
  assert.equal(status.state, 'uncertain'); assert.equal(status.blockingJournal, true); assert.equal(f.calls.length, 1);
});

test('最後一項可靠完成後才停止仍回完整成功；idle等待可即時停止', async t => {
  const controller = new AbortController();
  const f = await fixture(t, () => controller.abort()); f.args.files = f.args.files.slice(0, 1);
  const result = await withRequestControl({ signal: controller.signal }, () => f.desktop.call('line_send_files', f.args, context));
  assert.equal(result.success, true); assert.equal(result.completedCount, 1);
  const pauseController = new AbortController();
  const waiting = withRequestControl({ signal: pauseController.signal }, () => requestPause(10_000));
  pauseController.abort(); await assert.rejects(waiting, { code: 'REQUEST_CANCELLED' });
});


test('冷編譯等待期間停止：編譯可完成，但不再執行native命令', async () => {
  const compiling = deferred(), ready = deferred(), controller = new AbortController(); let executions = 0;
  const bridge = new NativeBridge({ execFile() { executions++; } });
  bridge.ensureBinary = async () => { compiling.resolve(); await ready.promise; return '/synthetic/helper'; };
  const pending = withRequestControl({ signal: controller.signal }, () => bridge.call('status'));
  await compiling.promise; controller.abort(); ready.resolve();
  await assert.rejects(pending, { code: 'REQUEST_CANCELLED' }); assert.equal(executions, 0);
});
