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
import { AttachmentStorage } from '../src/automation/attachment-storage.js';
import { LocalMaintenance } from '../src/automation/local-maintenance.js';
import { AgentServices } from '../src/automation/agent-workflows.js';
import { OperationLock } from '../src/automation/operation-lock.js';
import { withOperation, withRequestControl, progressReporter } from '../src/automation/request-control.js';
const context = { transport: 'stdio', sessionId: 'synthetic-progress-session' };
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };

async function fixture(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'line-progress-fixture-')), folders = [];
  t.after(async () => { for (const folder of folders) await fs.rm(folder, { recursive: true, force: true }); await fs.rm(directory, { recursive: true, force: true }); });
  const assets = new AttachmentStorage({ directory: path.join(directory, 'assets') });
  const files = [];
  for (let i = 0; i < 2; i++) {
    const filePath = path.join(directory, `synthetic-${i}.txt`), data = Buffer.from('SYNTHETIC_' + crypto.randomUUID());
    await fs.writeFile(filePath, data); files.push({ filePath, fileSha256: crypto.createHash('sha256').update(data).digest('hex') });
  }
  const receipt = async args => ({ success: true, autoSent: true, chatVerified: true, selectedFileVerified: true,
    sourceSha256: args.fileSha256, fileSha256: args.fileSha256, byteCount: (await fs.stat(args.filePath)).size,
    receipt: { status: 'UI_SUBMITTED', deliveryConfirmed: false } });
  const desktop = new MacOSDesktopAutomation({ journalPath: path.join(directory, 'pending-operation.json'),
    lock: new OperationLock({ lockPath: path.join(directory, 'ui.lock') }), attachmentSettle: async () => {},
    bridge: { assets, async call(name, args) { assert.equal(name, 'sendFile'); return receipt(args); } } });
  return { directory, folders, assets, files, desktop, receipt,
    args: { chatName: '合成對話', requestId: crypto.randomUUID(), files },
    async native() {
      const data = Buffer.from('SYNTHETIC_NATIVE_' + crypto.randomUUID()), sha256 = crypto.createHash('sha256').update(data).digest('hex');
      const root = await fs.realpath(os.tmpdir()), folder = path.join(root, `line-mcp-file-${crypto.randomUUID()}-${sha256}`);
      await fs.mkdir(folder, { mode: 0o700 }); folders.push(folder);
      const file = path.join(folder, 'synthetic.bin'); await fs.writeFile(file, data, { mode: 0o600 });
      const asset = { kind: 'native_file', directory: folder, file, sha256, sourceSha256: sha256 };
      return { asset, args: { chatName: '合成對話', filePath: file, fileSha256: sha256 }, result: { ...await receipt({ filePath: file, fileSha256: sha256 }), _temporaryAsset: asset } };
    },
  };
}
async function memory(t, fake, options) {
  const server = new LineDesktopMCPServer(fake, options), client = new Client({ name: 'synthetic-progress', version: '1.0.0' });
  const [a, b] = InMemoryTransport.createLinkedPair(); await server.server.connect(b); await client.connect(a);
  t.after(async () => { await client.close(); await server.server.close(); }); return client;
}
function fakeNative(assets, response) {
  const bridge = new NativeBridge({ assets, execFile(_binary, _args, _options, callback) { callback(null, JSON.stringify(response), ''); } });
  bridge.ensureBinary = async () => '/synthetic/helper'; return bridge;
}

test('真MCP進度嚴格遞增，不回名稱路徑；可靠回條後Node副本移除且原檔保留', async t => {
  const f = await fixture(t), events = [];
  const client = await memory(t, { desktopCall: (...args) => f.desktop.call(...args) });
  const result = await client.callTool({ name: 'line_send_files', arguments: f.args }, undefined, { onprogress: event => events.push(event) });
  assert.equal(result.structuredContent.completedCount, 2);
  assert.ok(events.length >= 5); assert.equal(events.at(-1).progress, events.at(-1).total);
  assert.ok(events.every((event, i) => !i || event.progress > events[i - 1].progress));
  assert.doesNotMatch(JSON.stringify(events), /synthetic-0|合成對話|filePath|sha256/);
  assert.equal((await f.assets.status()).trackedCount, 0);
  for (const file of f.files) await fs.access(file.filePath);
});

test('進度通知失敗不改變可靠提交，不重送、不把原始網路錯誤寫入回條', async t => {
  const f = await fixture(t); let attempts = 0;
  const result = await withRequestControl({ progress: progressReporter('synthetic-token', async () => { attempts++; throw new Error('PRIVATE_NETWORK_CANARY'); }) },
    () => f.desktop.call('line_send_files', f.args, context));
  assert.equal(result.success, true); assert.equal(attempts, 1); assert.doesNotMatch(JSON.stringify(result), /PRIVATE_NETWORK_CANARY/);
});

test('預驗階段的持久進度可由另一請求讀取，不取得UI鎖', async t => {
  const f = await fixture(t), inspecting = deferred(), resume = deferred(); let count = 0;
  f.desktop.bridge.call = async (name, args) => {
    assert.equal(name, 'inspectImage'); count++;
    if (count === 2) { inspecting.resolve(); await resume.promise; }
    return { sourceSha256: args.imageSha256, uiAccessed: false, width: 1, height: 1 };
  };
  const controller = new AbortController();
  const pending = withRequestControl({ signal: controller.signal }, () => f.desktop.call('line_send_images', {
    chatName: f.args.chatName, requestId: f.args.requestId, images: f.files.map(file => ({ imagePath: file.filePath, imageSha256: file.fileSha256 })),
  }, context));
  await inspecting.promise;
  const state = await f.desktop.call('line_operation_status', { requestId: f.args.requestId }, context);
  assert.equal(state.result.phase, 'preparing'); assert.equal(state.result.preparedCount, 1); assert.equal(state.result.completedCount, 0);
  controller.abort(); resume.resolve(); assert.equal((await pending).cancelled, true);
  assert.equal((await f.assets.status()).trackedCount, 0);
});

test('NativeBridge登錄原生副本並移除私有路徑；停止中的可靠回條仍完成登錄', async t => {
  const f = await fixture(t), native = await f.native(), controller = new AbortController();
  const bridge = fakeNative(f.assets, { ok: true, result: native.result });
  const original = bridge.execFile;
  bridge.execFile = (...args) => { controller.abort(); return original(...args); };
  const result = await withRequestControl({ signal: controller.signal }, () => withOperation(crypto.randomUUID(), () => bridge.call('sendFile', native.args)));
  assert.equal(result.success, true); assert.equal(result._temporaryAsset, undefined);
  assert.doesNotMatch(JSON.stringify(result), /line-mcp-file-|synthetic.bin/);
  assert.equal((await f.assets.status()).submittedCount, 1);
});

test('原生不明錯誤的副本受保護，公開錯誤不含私有路徑', async t => {
  const f = await fixture(t), native = await f.native();
  const bridge = fakeNative(f.assets, { ok: false, error: { code: 'SEND_UNCERTAIN', message: '合成不明結果', details: { phase: 'post_commit', _temporaryAsset: native.asset } } });
  await assert.rejects(withOperation(crypto.randomUUID(), () => bridge.call('sendFile', native.args)), error => {
    assert.equal(error.code, 'SEND_UNCERTAIN'); assert.equal(error.details._temporaryAsset, undefined); return true;
  });
  assert.equal((await f.assets.status()).protectedCount, 1);
});

test('私有副本登錄失敗仍保留可靠提交並回固定警示，不傳回路徑', async t => {
  const f = await fixture(t), native = await f.native();
  const bridge = fakeNative({ async capture() { throw new Error('PRIVATE_STORAGE_CANARY'); } }, { ok: true, result: native.result });
  const result = await bridge.call('sendFile', native.args);
  assert.equal(result.localStorageWarning, 'ASSET_TRACKING_FAILED'); assert.equal(result.success, true);
  assert.doesNotMatch(JSON.stringify(result), /PRIVATE_STORAGE_CANARY|line-mcp-file-|synthetic.bin/);
});

test('單一本機維護工具可經MCP呼叫且不啟動桌面；HTTP仍拒絕', async t => {
  const f = await fixture(t), maintenance = new LocalMaintenance({ directory: f.directory, assets: f.assets, uiLock: f.desktop.lock, helperRunning: async () => false });
  const services = new AgentServices({ maintenance });
  const client = await memory(t, { desktopCall() { throw new Error('UI_MUST_NOT_RUN'); } }, { agentServices: services });
  const catalog = await client.listTools();
  assert.equal(catalog.tools.find(tool => tool.name === 'line_local_maintenance').annotations.destructiveHint, true);
  const result = await client.callTool({ name: 'line_local_maintenance', arguments: { action: 'status' } });
  assert.equal(result.structuredContent.uiAccessed, false);
  const http = new LineDesktopMCPServer({}, { transport: 'http', agentServices: services });
  const denied = await http.handleDesktopTool('line_local_maintenance', { action: 'cleanup' });
  assert.equal(denied.structuredContent.error.code, 'TRANSPORT_NOT_ALLOWED');
});
