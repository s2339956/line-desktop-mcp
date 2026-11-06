import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { AttachmentStorage } from '../src/automation/attachment-storage.js';
import { LocalMaintenance } from '../src/automation/local-maintenance.js';
import { OperationLock } from '../src/automation/operation-lock.js';
import { withOperation } from '../src/automation/request-control.js';

async function fixture(t, overrides = {}) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'line-maintenance-fixture-'));
  const temporaryRoot = await fs.realpath(os.tmpdir()); let now = Date.parse('2026-01-01T00:00:00Z');
  const assets = new AttachmentStorage({ directory: path.join(directory, 'assets'), now: () => now });
  const uiLock = new OperationLock({ lockPath: path.join(directory, 'ui.lock') });
  const maintenance = new LocalMaintenance({ directory, assets, uiLock, isAlive: () => false, helperRunning: async () => false, pause: async () => {}, ...overrides });
  const folders = [];
  t.after(async () => { for (const folder of folders) await fs.rm(folder, { recursive: true, force: true }); await fs.rm(directory, { recursive: true, force: true }); });
  return { directory, assets, maintenance, uiLock, advance(days) { now += days * 86_400_000; },
    async asset(state = 'submitted', kind = 'native_file', register = true) {
      const data = Buffer.from('SYNTHETIC_STORAGE_' + crypto.randomUUID());
      const sha256 = crypto.createHash('sha256').update(data).digest('hex');
      const folder = kind === 'node' ? await fs.mkdtemp(path.join(temporaryRoot, `line-mcp-attachment-${sha256}-`))
        : path.join(temporaryRoot, kind === 'native_file' ? `line-mcp-file-${crypto.randomUUID()}-${sha256}` : 'line-mcp-image-' + crypto.randomUUID());
      if (kind !== 'node') await fs.mkdir(folder, { mode: 0o700 }); folders.push(folder);
      const file = path.join(folder, kind === 'native_image' ? sha256 + '.png' : 'synthetic.bin');
      await fs.writeFile(file, data, { mode: 0o600 });
      const asset = { kind, directory: folder, file, sha256, sourceSha256: sha256 };
      if (register) await withOperation(crypto.randomUUID(), () => assets.capture(asset, state));
      return asset;
    },
    async owner(value = { pid: 99999999, nonce: 'synthetic-owner-nonce-1234', acquiredAt: '2025-01-01T00:00:00Z' }) {
      await fs.mkdir(uiLock.lockPath, { mode: 0o700 });
      await fs.writeFile(path.join(uiLock.lockPath, 'owner.json'), JSON.stringify(value), { mode: 0o600 }); return value;
    },
  };
}

test('狀態只回計數；清理僅移除登錄、已提交、滿7天且內容未變的副本', async t => {
  const f = await fixture(t);
  const submitted = await f.asset(), held = await f.asset('prepared'), uncertain = await f.asset('uncertain'), unregistered = await f.asset('submitted', 'native_file', false);
  const status = await f.maintenance.call({ action: 'status' });
  assert.equal(status.assets.trackedCount, 3); assert.equal(status.assets.protectedCount, 2);
  assert.doesNotMatch(JSON.stringify(status), /synthetic.bin|SYNTHETIC_STORAGE_|line-mcp-file-|nonce|99999999/);
  assert.equal((await f.maintenance.call({ action: 'cleanup' })).removedCount, 0);
  f.advance(8);
  const cleaned = await f.maintenance.call({ action: 'cleanup' });
  assert.equal(cleaned.removedCount, 1); assert.equal(cleaned.skippedCount, 2);
  await assert.rejects(fs.stat(submitted.file), { code: 'ENOENT' });
  for (const item of [held, uncertain, unregistered]) await fs.access(item.file);
});

test('Node輸入快照可在可靠原生回條後單獨釋放，不刪除原始檔', async t => {
  const f = await fixture(t), node = await f.asset('prepared', 'node');
  assert.equal(await f.assets.remove(node.directory), true);
  assert.equal((await f.assets.status()).trackedCount, 0);
  await assert.rejects(fs.stat(node.directory), { code: 'ENOENT' });
});

test('存在待恢復journal或原生helper時，不清理且不改操作紀錄', async t => {
  const f = await fixture(t), asset = await f.asset(); f.advance(8);
  const journal = path.join(f.directory, 'pending-operation.json');
  await fs.writeFile(journal, '{"synthetic":true}', { mode: 0o600 });
  await assert.rejects(f.maintenance.call({ action: 'cleanup' }), { code: 'MAINTENANCE_BLOCKED' });
  assert.equal(await fs.readFile(journal, 'utf8'), '{"synthetic":true}'); await fs.access(asset.file);
  await fs.unlink(journal); f.maintenance.helperRunning = async () => true;
  await assert.rejects(f.maintenance.call({ action: 'cleanup' }), { code: 'MAINTENANCE_BLOCKED' });
});

test('symlink、硬連結、未知新增檔案及內容變更都不能藉清理刪除', async t => {
  const f = await fixture(t);
  const linked = await f.asset(), hard = await f.asset(), extra = await f.asset(), changed = await f.asset();
  const outside = path.join(f.directory, 'outside.txt'); await fs.writeFile(outside, 'SYNTHETIC_OUTSIDE', { mode: 0o600 });
  await fs.unlink(linked.file); await fs.symlink(outside, linked.file);
  await fs.link(hard.file, path.join(f.directory, 'hardlink.txt'));
  await fs.writeFile(path.join(extra.directory, 'unknown.txt'), 'SYNTHETIC_UNKNOWN');
  await fs.writeFile(changed.file, 'changed'); f.advance(8);
  const result = await f.maintenance.call({ action: 'cleanup' });
  assert.equal(result.removedCount, 0); assert.equal(result.skippedCount, 4);
  assert.equal(await fs.readFile(outside, 'utf8'), 'SYNTHETIC_OUTSIDE');
  for (const item of [linked, hard, extra, changed]) await fs.lstat(item.file);
});

test('未登錄路徑與manifest越界都拒絕，不能傳任意路徑給維護工具', async t => {
  const f = await fixture(t), native = await f.asset(); f.advance(8);
  const unknown = await f.asset('submitted', 'native_file', false);
  await assert.rejects(f.assets.capture({ ...unknown, schemaVersion: 99 }, 'submitted'), { code: 'ASSET_UNSAFE' });
  const file = f.assets.file(native.directory), record = JSON.parse(await fs.readFile(file, 'utf8'));
  record.file = path.join(f.directory, 'outside'); await fs.writeFile(file, JSON.stringify(record));
  assert.equal((await f.maintenance.call({ action: 'cleanup' })).removedCount, 0);
  await fs.access(native.file);
  await assert.rejects(f.maintenance.call({ action: 'cleanup', path: f.directory }), { code: 'INVALID_ARGUMENT' });
  await assert.rejects(f.maintenance.call({ action: 'cleanup', minimumAgeDays: 1 }), { code: 'INVALID_ARGUMENT' });
  await assert.rejects(f.maintenance.call({ action: 'recover_lock', target: '../outside' }), { code: 'INVALID_ARGUMENT' });
});

test('死亡owner與helper兩次核對後封存鎖；pending journal原樣保留', async t => {
  const f = await fixture(t); await f.owner();
  const pending = path.join(f.directory, 'pending-operation.json'); await fs.writeFile(pending, '{"synthetic":true}', { mode: 0o600 });
  const result = await f.maintenance.call({ action: 'recover_lock', target: 'ui' });
  assert.equal(result.recovered, true); assert.equal(result.journalCleared, false); assert.equal(result.sendAttempted, false);
  await assert.rejects(fs.stat(f.uiLock.lockPath), { code: 'ENOENT' });
  assert.equal(await fs.readFile(pending, 'utf8'), '{"synthetic":true}');
  const archived = await fs.readdir(path.join(f.directory, 'recovery-evidence')); assert.equal(archived.length, 1);
  assert.equal(JSON.parse(await fs.readFile(path.join(f.directory, 'recovery-evidence', archived[0], 'owner.json'))).pid, 99999999);
  await f.uiLock.withLock(async () => {});
});

test('活owner、PID重用、未知程序、原生helper或探針失敗均不解除鎖', async t => {
  for (const isAlive of [() => true, () => null]) {
    const f = await fixture(t, { isAlive }); await f.owner();
    await assert.rejects(f.maintenance.call({ action: 'recover_lock', target: 'ui' }), { code: 'LOCK_RECOVERY_BLOCKED' }); await fs.access(f.uiLock.lockPath);
  }
  for (const helperRunning of [async () => true, async () => { throw new Error('synthetic probe failure'); }]) {
    const f = await fixture(t, { helperRunning }); await f.owner();
    await assert.rejects(f.maintenance.call({ action: 'recover_lock', target: 'ui' })); await fs.access(f.uiLock.lockPath);
  }
});

test('兩次檢查間owner變動、不完整owner及symlink鎖皆保留', async t => {
  const f = await fixture(t); await f.owner();
  f.maintenance.pause = async () => fs.writeFile(path.join(f.uiLock.lockPath, 'owner.json'), '{"synthetic":true}');
  await assert.rejects(f.maintenance.call({ action: 'recover_lock', target: 'ui' }), { code: 'LOCK_UNSAFE' }); await fs.access(f.uiLock.lockPath);
  const other = await fixture(t); await fs.symlink(f.uiLock.lockPath, other.uiLock.lockPath);
  await assert.rejects(other.maintenance.call({ action: 'recover_lock', target: 'ui' }), { code: 'LOCK_UNSAFE' }); await fs.lstat(other.uiLock.lockPath);
});
