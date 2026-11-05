import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { doctor, capabilitiesFor } from '../src/automation/doctor.js';
import { MacOSDesktopAutomation } from '../src/automation/desktop-automation.js';
import { RequestReceipts } from '../src/automation/request-records.js';

const context = { transport: 'stdio', sessionId: 'synthetic-session' };
const requestId = 'synthetic-request-0001';
const args = { chatName: '合成對話', imagePath: '/tmp/synthetic.png', imageSha256: 'a'.repeat(64), autoSend: true, requestId };
const result = { success: true, autoSent: true, chatVerified: true, selectedFileVerified: true,
  sourceSha256: args.imageSha256, imageSha256: 'b'.repeat(64), receipt: { status: 'UI_SUBMITTED', deliveryConfirmed: false } };

async function fixture(t, handler = async () => result) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'line-request-fixture-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const journalPath = path.join(directory, 'pending.json');
  const requests = new RequestReceipts(path.join(directory, 'requests'));
  let calls = 0;
  const desktop = new MacOSDesktopAutomation({ journalPath, requests,
    lock: { withLock: work => work() }, bridge: { async call(name, input) {
      if (name === 'status') return { usable: true, mainWindow: { pid: 1, windowId: 2 } };
      calls++; return handler(name, input);
    } } });
  return { directory, journalPath, requests, desktop, calls: () => calls };
}

test('健檢不將未知版本或尚未檢查權限回報為就緒', async () => {
  const compatible = { platform: 'darwin', nodeVersion: '22.0.0', systemVersion: '14.0', lineVersion: '26.4.2', lineBuild: '3955' };
  assert.equal(capabilitiesFor(compatible).features.imageSend, true);
  assert.equal(capabilitiesFor({ ...compatible, lineBuild: '9999' }).features.imageSend, false);
  assert.equal(capabilitiesFor({ ...compatible, nodeVersion: '20.0.0' }).runtimeSupported, false);
  assert.equal(capabilitiesFor({ ...compatible, systemVersion: null }).runtimeSupported, false);
  const report = await doctor({ platform: 'darwin', bridge: { call() { throw new Error('不應呼叫'); } },
    run: async (_command, argv) => ({ stdout: argv.includes('CFBundleVersion') ? '3955' : argv.includes('CFBundleShortVersionString') ? '26.4.2' : '14.0' }) });
  assert.equal(report.uiReadinessConfirmed, false);
  assert.equal(report.contentRead, false);
  assert.equal(report.compatibility.features.imageSend, true);
});

test('文字requestId綁定正文摘要；重複提交不重送且正文不落盤', async t => {
  const f = await fixture(t, async () => ({ success: true, autoSent: true, receipt: result.receipt }));
  await f.desktop.legacySend('合成對話', 'SYNTHETIC_BODY', true, requestId);
  assert.equal((await f.desktop.legacySend('合成對話', 'SYNTHETIC_BODY', true, requestId)).replayed, true);
  await assert.rejects(f.desktop.legacySend('合成對話', 'DIFFERENT_BODY', true, requestId), { code: 'REQUEST_CONFLICT' });
  assert.equal(f.calls(), 1);
  assert(!(await fs.readFile(f.requests.file(requestId), 'utf8')).includes('SYNTHETIC_BODY'));
});

test('程序在執行前後中斷留下started時，新instance也不會重送', async t => {
  const f = await fixture(t);
  await fs.mkdir(path.dirname(f.requests.file(requestId)), { mode: 0o700 });
  await fs.writeFile(f.requests.file(requestId), JSON.stringify({ schemaVersion: 1,
    operationId: '01234567-0123-4123-8123-0123456789ab', actionHash: 'a'.repeat(64),
    createdAt: new Date().toISOString(), state: 'started' }), { mode: 0o600 });
  const restarted = new RequestReceipts(path.join(f.directory, 'requests'));
  await assert.rejects(restarted.run(requestId, 'a'.repeat(64), () => { throw new Error('不可執行'); }), { code: 'OPERATION_UNCERTAIN' });
});

test('同一requestId跨instance重播只回既有回條，不進native；更換內容拒絕', async t => {
  const f = await fixture(t);
  await f.desktop.call('line_send_image', args, context);
  const second = await f.desktop.call('line_send_image', args, context);
  assert.equal(second.replayed, true);
  assert.equal(f.calls(), 1);
  await assert.rejects(f.desktop.call('line_send_image', { ...args, chatName: '其他合成對話' }, context), { code: 'REQUEST_CONFLICT' });
  const restarted = new RequestReceipts(path.join(f.directory, 'requests'));
  assert.equal((await restarted.status(requestId)).state, 'succeeded');
  const stored = await fs.readFile(restarted.file(requestId), 'utf8');
  assert(!stored.includes(args.chatName) && !stored.includes(args.imagePath) && !stored.includes(requestId));
});

test('不明操作不重送，人工放棄只封存同一紀錄且原requestId永久停止', async t => {
  const f = await fixture(t, async () => { throw Object.assign(new Error('synthetic timeout'), { code: 'NATIVE_TIMEOUT' }); });
  await assert.rejects(f.desktop.call('line_send_image', args, context), { code: 'OPERATION_UNCERTAIN' });
  const pending = await f.desktop.call('line_operation_status', { requestId }, context);
  assert.equal(pending.state, 'uncertain');
  await assert.rejects(f.desktop.call('line_send_image', args, context), { code: 'OPERATION_UNCERTAIN' });
  await assert.rejects(f.desktop.call('line_resolve_operation', { requestId, operationId: 'wrong', outcome: 'abandoned' }, context), { code: 'RECOVERY_RECORD_INVALID' });
  const resolved = await f.desktop.call('line_resolve_operation', { requestId, operationId: pending.operationId, outcome: 'abandoned' }, context);
  assert.equal(resolved.sendAttempted, false);
  await assert.rejects(fs.access(f.journalPath), { code: 'ENOENT' });
  await assert.rejects(f.desktop.call('line_send_image', args, context), { code: 'REQUEST_FINISHED' });
  assert.equal(f.calls(), 1);
  assert.equal((await fs.readdir(path.join(f.directory, 'recovery-evidence'))).length, 1);
});

test('不會清除其他操作的journal或讀取symlink請求紀錄', async t => {
  const f = await fixture(t, async () => { throw Object.assign(new Error('synthetic'), { code: 'NATIVE_TIMEOUT' }); });
  await assert.rejects(f.desktop.sendImage(args));
  const record = await f.requests.read(requestId);
  const foreign = { operationId: 'foreign', actionHash: 'c'.repeat(64) };
  await fs.writeFile(f.journalPath, JSON.stringify(foreign));
  await assert.rejects(f.desktop.call('line_resolve_operation', { requestId, operationId: record.operationId, outcome: 'submitted' }, context), { code: 'RECOVERY_RECORD_INVALID' });
  assert.deepEqual(JSON.parse(await fs.readFile(f.journalPath, 'utf8')), foreign);
  const target = path.join(f.directory, 'target.json');
  await fs.writeFile(target, '{}', { mode: 0o600 });
  const maliciousId = 'synthetic-symlink-0001';
  await fs.symlink(target, f.requests.file(maliciousId));
  await assert.rejects(f.requests.status(maliciousId));
});
