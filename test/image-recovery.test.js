import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { MacOSDesktopAutomation } from '../src/automation/desktop-automation.js';
const args = { operationId: 'c8b7b49c-55ef-455f-87d8-06a0416a42d3', chatName: '合成對話', imageSha256: 'a'.repeat(64) };
const window = { pid: 1, windowId: 2, title: 'LINE', bounds: { x: 10, y: 20, width: 969, height: 650 },
  bundleIdentifier: 'jp.naver.line.mac', executableURL: '/Applications/LINE.app/Contents/MacOS/LINE',
  signingIdentifier: 'jp.naver.line.mac', teamIdentifier: 'VUTU7AKEUR' };
const context = { transport: 'stdio', sessionId: 'image-recovery' };
async function fixture(t, autoSend = false, handler) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'line-image-recovery-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const journal = path.join(directory, 'pending.json');
  const action = { action: 'sendImage', autoSend, chatName: args.chatName, imageSha256: args.imageSha256 };
  const record = { operationId: args.operationId, actionHash: crypto.createHash('sha256').update(JSON.stringify(action)).digest('hex'), createdAt: new Date().toISOString() };
  const raw = JSON.stringify(record);
  await fs.writeFile(journal, raw, { mode: 0o600 });
  const calls = [];
  const desktop = new MacOSDesktopAutomation({ journalPath: journal,
    lock: { withLock: work => work() }, bridge: { async call(name) {
      calls.push(name);
      return handler ? handler(calls.length) : { running: true, accessibilityTrusted: true, usable: true, mainWindow: window };
    } } });
  return { desktop, directory, journal, calls, raw };
}
test('圖片預覽受控恢復僅被動status，先封存原紀錄再結案', async t => {
  const f = await fixture(t);
  assert.deepEqual(await f.desktop.recoverImagePreview(args, context),
    { recovered: true, archived: true, inputAttempted: false, sendAttempted: false });
  assert.deepEqual(f.calls, ['status', 'status']);
  await assert.rejects(fs.access(f.journal), { code: 'ENOENT' });
  const archived = await fs.readdir(path.join(f.directory, 'recovery-evidence'));
  assert.equal(archived.length, 1);
  assert.equal(await fs.readFile(path.join(f.directory, 'recovery-evidence', archived[0]), 'utf8'), f.raw);
});
test('真送出／錯opid／錯目標／錯hash／連結在任何native前拒絕', async t => {
  for (const [auto, change] of [[true, {}], [false, { operationId: 'a'.repeat(36) }],
    [false, { chatName: '其他合成對話' }], [false, { imageSha256: 'b'.repeat(64) }]]) {
    const f = await fixture(t, auto);
    await assert.rejects(f.desktop.recoverImagePreview({ ...args, ...change }, context));
    assert.equal(f.calls.length, 0);
    assert.equal(await fs.readFile(f.journal, 'utf8'), f.raw);
  }
  const f = await fixture(t); await fs.rename(f.journal, f.journal + '.original'); await fs.symlink(f.journal + '.original', f.journal);
  await assert.rejects(f.desktop.recoverImagePreview(args, context)); assert.equal(f.calls.length, 0);
});
test('modal／視窗漂移保留pending，不清除其他操作', async t => {
  for (const handler of [() => ({ running: true, accessibilityTrusted: true, usable: false }),
    count => ({ running: true, accessibilityTrusted: true, usable: true,
      mainWindow: { ...window, windowId: count } })]) {
    const f = await fixture(t, false, handler);
    await assert.rejects(f.desktop.recoverImagePreview(args, context), error => error.code === 'NEEDS_RECOVERY');
    assert.equal(await fs.readFile(f.journal, 'utf8'), f.raw);
  }
});
