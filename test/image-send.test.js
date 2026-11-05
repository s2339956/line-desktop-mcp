import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { MacOSDesktopAutomation } from '../src/automation/desktop-automation.js';
import { LineDesktopMCPServer } from '../src/server.js';
import { desktopTools } from '../src/desktop-tools.js';
import { NativeBridge } from '../src/automation/native-bridge.js';

const sha = 'a'.repeat(64);
const args = { chatName: '合成對話', imagePath: '/tmp/synthetic.png', imageSha256: sha };
const context = { transport: 'stdio', sessionId: 'synthetic-session' };
const receipt = autoSent => ({ success: true, autoSent, chatVerified: true,
  selectedFileVerified: true, sourceSha256: sha, imageSha256: 'b'.repeat(64),
  receipt: { status: autoSent ? 'UI_SUBMITTED' : 'IMAGE_SELECTED_NOT_SENT', deliveryConfirmed: false } });
async function fixture(t, handler) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'line-image-test-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  const calls = [];
  const desktop = new MacOSDesktopAutomation({
    bridge: { async call(name, input) { calls.push({ name, input }); return handler(name, input); } },
    lock: { async withLock(work) { return work(); } }, journalPath: path.join(dir, 'pending.json'),
  });
  return { desktop, calls, journal: path.join(dir, 'pending.json') };
}

test('圖片預設只選檔；明確 autoSend true 才提交，回條不冒稱送達', async t => {
  for (const autoSend of [undefined, false, true]) {
    const f = await fixture(t, (_name, input) => receipt(input.autoSend));
    const result = await f.desktop.call('line_send_image', { ...args,
      ...(autoSend === undefined ? {} : { autoSend }) }, context);
    assert.equal(result.autoSent, autoSend ?? false);
    assert.equal(result.receipt.deliveryConfirmed, false);
    assert.deepEqual(f.calls, [{ name: 'sendImage', input: { ...args, autoSend: autoSend ?? false } }]);
    await assert.rejects(fs.access(f.journal), { code: 'ENOENT' });
  }
});

test('圖片路徑／hash／boolean／unknown欄位與HTTP都在native前拒絕', async t => {
  const f = await fixture(t, () => { throw new Error('不應到native'); });
  for (const bad of [ { imagePath: 'relative.png' }, { imagePath: '/tmp/a\nb.png' },
    { imageSha256: 'A'.repeat(64) }, { imageSha256: '' }, { autoSend: 'true' },
    { autoSend: 1 }, { unknown: true } ]) {
    await assert.rejects(f.desktop.call('line_send_image', { ...args, ...bad }, context),
      error => error.code === 'INVALID_ARGUMENT');
  }
  await assert.rejects(f.desktop.call('line_send_image', args, { ...context, transport: 'http' }),
    error => error.code === 'TRANSPORT_NOT_ALLOWED');
  assert.equal(f.calls.length, 0);
});

test('錯圖、缺少驗證或矛盾回條保留journal，下一次零native且journal沒有明文', async t => {
  for (const change of [ { sourceSha256: 'c'.repeat(64) }, { imageSha256: '' },
    { chatVerified: false }, { selectedFileVerified: false }, { autoSent: false },
    { receipt: { status: 'UI_SUBMITTED', deliveryConfirmed: true } },
    { receipt: { status: 'UI_ACCEPTED', deliveryConfirmed: false } } ]) {
    const f = await fixture(t, () => ({ ...receipt(true), ...change }));
    await assert.rejects(f.desktop.call('line_send_image', { ...args, autoSend: true }, context),
      error => error.code === 'OPERATION_UNCERTAIN');
    await assert.rejects(f.desktop.call('line_send_image', { ...args, autoSend: true }, context),
      error => error.code === 'NEEDS_RECOVERY');
    assert.equal(f.calls.length, 1);
    const journal = await fs.readFile(f.journal, 'utf8');
    assert(!journal.includes(args.chatName) && !journal.includes(args.imagePath) && !journal.includes(sha));
  }
});

test('確定零UI失敗才清journal；timeout／postcommit保留並禁止重試', async t => {
  for (const phase of ['pre_commit', 'post_commit', undefined]) {
    const f = await fixture(t, () => { throw Object.assign(new Error('合成失敗'),
      { code: 'SYNTHETIC_FAILURE', details: { phase } }); });
    await assert.rejects(f.desktop.call('line_send_image', args, context),
      error => error.code === (phase === 'pre_commit' ? 'SYNTHETIC_FAILURE' : 'OPERATION_UNCERTAIN'));
    if (phase === 'pre_commit') await assert.rejects(fs.access(f.journal), { code: 'ENOENT' });
    else await fs.access(f.journal);
  }
});

test('圖片工具維持stdio-only與既有read liveScope deny；不建立自動發送排程', async () => {
  const tool = desktopTools.find(tool => tool.name === 'line_send_image');
  assert.equal(tool.inputSchema.properties.autoSend.default, false);
  assert.equal(tool.inputSchema.additionalProperties, false);
  const bridge = new NativeBridge({ liveScope: { kind: 'global', chatName: args.chatName } });
  await assert.rejects(bridge.call('sendImage', args), error => error.code === 'LIVE_SCOPE_DENIED');
  const server = new LineDesktopMCPServer({ async desktopCall() { throw new Error('不應呼叫'); } },
    { transport: 'http', sessionId: 'synthetic-http' });
  const result = await server.handleDesktopTool('line_send_image', args);
  assert.equal(JSON.parse(result.content[0].text).error.code, 'TRANSPORT_NOT_ALLOWED');
});
