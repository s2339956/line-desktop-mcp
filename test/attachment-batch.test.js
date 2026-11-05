import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { MacOSDesktopAutomation } from '../src/automation/desktop-automation.js';
import { stageAttachment } from '../src/automation/attachment-batch.js';
import { NativeBridge } from '../src/automation/native-bridge.js';

const context = { transport: 'stdio', sessionId: 'synthetic-session' };
const requestId = 'synthetic-batch-0001';
const digest = value => crypto.createHash('sha256').update(value).digest('hex');

async function fixture(t, handler) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'line-batch-fixture-'));
  const files = [];
  for (let index = 0; index < 3; index++) {
    const filePath = path.join(directory, `合成附件${index}.txt`);
    const data = `SYNTHETIC ${index}`;
    await fs.writeFile(filePath, data);
    files.push({ filePath, fileSha256: digest(data) });
  }
  const calls = [];
  const desktop = new MacOSDesktopAutomation({ journalPath: path.join(directory, 'pending.json'),
    lock: { withLock: work => work() }, bridge: { async call(name, args) {
      calls.push({ name, args });
      return handler ? handler(name, args, calls) : receipt(args);
    } } });
  t.after(async () => {
    for (const call of calls) {
      const file = call.args.filePath ?? call.args.imagePath;
      if (file && path.basename(path.dirname(file)).startsWith('line-mcp-attachment-')) {
        await fs.rm(path.dirname(file), { recursive: true, force: true });
      }
    }
    await fs.rm(directory, { recursive: true, force: true });
  });
  return { directory, files, calls, desktop };
}

function receipt(args) {
  const sha = args.fileSha256 ?? args.imageSha256;
  if (args.imagePath && args.autoSend === undefined) return { sourceSha256: sha, uiAccessed: false, width: 1, height: 1 };
  return { success: true, autoSent: true, chatVerified: true, selectedFileVerified: true,
    sourceSha256: sha, imageSha256: sha, fileSha256: sha, byteCount: 11,
    rawTree: 'PRIVATE_CANARY', receipt: { status: 'UI_SUBMITTED', deliveryConfirmed: false } };
}

test('多檔依順序直接提交，保留檔名與內容，重複requestId不重送', async t => {
  const f = await fixture(t);
  const args = { chatName: '合成對話', requestId, files: f.files };
  const result = await f.desktop.call('line_send_files', args, context);
  assert.equal(result.completedCount, 3);
  assert.equal(f.calls.length, 3);
  for (const [index, call] of f.calls.entries()) {
    assert.equal(call.name, 'sendFile');
    assert.equal(path.basename(call.args.filePath), path.basename(f.files[index].filePath));
    assert.equal(digest(await fs.readFile(call.args.filePath)), f.files[index].fileSha256);
  }
  assert(!JSON.stringify(result).includes('PRIVATE_CANARY'));
  assert.equal((await f.desktop.call('line_send_files', args, context)).replayed, true);
  assert.equal(f.calls.length, 3);
});

test('後項檔案損壞時，第一個UI提交也不會執行', async t => {
  const f = await fixture(t);
  await assert.rejects(f.desktop.call('line_send_files', { chatName: '合成對話', requestId,
    files: [f.files[0], { ...f.files[1], fileSha256: 'a'.repeat(64) }] }, context), { code: 'ATTACHMENT_HASH_MISMATCH' });
  assert.equal(f.calls.length, 0);
  await assert.rejects(fs.access(path.join(f.directory, 'pending.json')), { code: 'ENOENT' });
});

test('中途不明時保留已驗證前綴，不送後項且不重播', async t => {
  const f = await fixture(t, async (_name, args, calls) => {
    if (calls.length === 2) throw Object.assign(new Error('synthetic timeout'), { code: 'NATIVE_TIMEOUT' });
    return receipt(args);
  });
  const args = { chatName: '合成對話', requestId, files: f.files };
  await assert.rejects(f.desktop.call('line_send_files', args, context), error => error.code === 'OPERATION_UNCERTAIN' && error.details.completedCount === 1);
  const state = await f.desktop.call('line_operation_status', { requestId }, context);
  assert.equal(state.state, 'uncertain');
  assert.equal(state.result.completedCount, 1);
  await assert.rejects(f.desktop.call('line_send_files', args, context), { code: 'OPERATION_UNCERTAIN' });
  assert.equal(f.calls.length, 2);
});

test('已知下一項尚未提交時回報partial，重播仍不會再次發送前綴', async t => {
  const f = await fixture(t, async (_name, args, calls) => {
    if (calls.length === 2) throw Object.assign(new Error('synthetic precommit'), { code: 'PHYSICAL_INPUT_BUSY', details: { phase: 'pre_commit' } });
    return receipt(args);
  });
  const args = { chatName: '合成對話', requestId, files: f.files };
  const partial = await f.desktop.call('line_send_files', args, context);
  assert.equal(partial.partial, true);
  assert.equal(partial.success, false);
  assert.equal(partial.completedCount, 1);
  assert.equal((await f.desktop.call('line_send_files', args, context)).replayed, true);
  assert.equal(f.calls.length, 2);
  await assert.rejects(fs.access(path.join(f.directory, 'pending.json')), { code: 'ENOENT' });
});

test('多圖先全部解碼，再按順序autoSend true，沒有確認或caption欄位', async t => {
  const f = await fixture(t);
  const images = f.files.slice(0, 2).map(item => ({ imagePath: item.filePath, imageSha256: item.fileSha256 }));
  const args = { chatName: '合成對話', requestId, images };
  const result = await f.desktop.call('line_send_images', args, context);
  assert.equal(result.completedCount, 2);
  assert.deepEqual(f.calls.map(call => call.name), ['inspectImage', 'inspectImage', 'sendImage', 'sendImage']);
  assert(f.calls.filter(call => call.name === 'sendImage').every(call => call.args.autoSend === true));
  await assert.rejects(f.desktop.call('line_send_images', { ...args, caption: 'not supported' }, context), { code: 'INVALID_ARGUMENT' });
});

test('拒絕symlink、超限、重複與HTTP；read liveScope不能取得檔案提交能力', async t => {
  const f = await fixture(t);
  const link = path.join(f.directory, 'link.txt'); await fs.symlink(f.files[0].filePath, link);
  await assert.rejects(stageAttachment({ path: link, sha256: f.files[0].fileSha256 }, 100), { code: 'ATTACHMENT_FILE_UNSAFE' });
  await assert.rejects(stageAttachment({ path: f.files[0].filePath, sha256: f.files[0].fileSha256 }, 1), { code: 'ATTACHMENT_FILE_UNSAFE' });
  await assert.rejects(f.desktop.call('line_send_files', { chatName: '合成對話', requestId, files: [f.files[0], f.files[0]] }, context), { code: 'INVALID_ARGUMENT' });
  await assert.rejects(f.desktop.call('line_send_files', { chatName: '合成對話', requestId, files: f.files }, { ...context, transport: 'http' }), { code: 'TRANSPORT_NOT_ALLOWED' });
  const bridge = new NativeBridge({ liveScope: { kind: 'global', chatName: '合成對話' } });
  await assert.rejects(bridge.call('sendFile', { chatName: '合成對話', ...f.files[0] }), { code: 'LIVE_SCOPE_DENIED' });
});

test('提交後清除紀錄失敗仍保留回條與阻擋狀態，重播不進入native', async t => {
  const f = await fixture(t);
  f.desktop.clearJournal = async () => { throw new Error('synthetic clear fault'); };
  const args = { chatName: '合成對話', requestId, files: f.files.slice(0, 1) };
  await assert.rejects(f.desktop.call('line_send_files', args, context), { code: 'OPERATION_UNCERTAIN' });
  const state = await f.desktop.call('line_operation_status', { requestId }, context);
  assert.equal(state.state, 'succeeded');
  assert.equal(state.needsRecovery, true);
  assert.equal((await f.desktop.call('line_send_files', args, context)).replayed, true);
  assert.equal(f.calls.length, 1);
});
