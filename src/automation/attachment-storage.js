import fs from 'node:fs/promises';
import { constants } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { AutomationError } from './automation-error.js';
import { OperationLock } from './operation-lock.js';
import { readPrivateJSON, writePrivateJSON, privateDirectory } from './private-json.js';
import { requestOperation, throwIfCancelled, withFinalization } from './request-control.js';
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const sha = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const uuid = value => typeof value === 'string' && /^[a-f0-9-]{36}$/i.test(value);
const unsafe = () => { throw new AutomationError('ASSET_UNSAFE', '附件快照歸屬、內容或紀錄不符，未清理'); };

// 僅管理明確登錄的副本；不掃描或依檔名前綴批次刪除系統暫存資料。
export class AttachmentStorage {
  constructor({ directory = path.join(os.homedir(), 'Library', 'Application Support', 'line-desktop-mcp', 'assets'),
    temporaryRoot = os.tmpdir(), now = () => Date.now() } = {}) {
    this.directory = directory; this.temporaryRoot = temporaryRoot; this.now = now;
    this.lock = new OperationLock({ lockPath: path.join(directory, '.lock') });
  }
  file(directory) { return path.join(this.directory, hash(directory) + '.json'); }
  async records() {
    let names;
    try { names = await fs.readdir(this.directory); } catch (error) { if (error.code === 'ENOENT') return []; throw error; }
    names = names.filter(name => /^[a-f0-9]{64}\.json$/.test(name));
    if (names.length > 2048) throw new AutomationError('ASSET_LIMIT', '快照紀錄超過檢查上限，請保留資料交由維護者處理');
    const records = [];
    for (const name of names.sort()) {
      const file = path.join(this.directory, name), loaded = await readPrivateJSON(file, 16 * 1024);
      if (!loaded) continue;
      const record = loaded.value;
      if (!record || typeof record.directory !== 'string' || typeof record.file !== 'string' ||
          !['node', 'native_image', 'native_file'].includes(record.kind) || !sha(record.sha256) || !sha(record.sourceSha256) ||
          !Number.isSafeInteger(record.byteCount) || record.byteCount < 1 || record.byteCount > 100 * 1024 * 1024 || !['prepared', 'submitted', 'uncertain'].includes(record.state) || record.schemaVersion !== 1 ||
          !Number.isSafeInteger(record.createdAt) || record.createdAt < 0 || record.createdAt > this.now() ||
          (record.operationId !== null && !uuid(record.operationId)) || this.file(record.directory) !== file) unsafe();
      records.push({ file, record });
    }
    return records;
  }
  async inspect(asset) {
    if (!asset || !['node', 'native_image', 'native_file'].includes(asset.kind) || !sha(asset.sha256) || !sha(asset.sourceSha256) ||
        typeof asset.directory !== 'string' || typeof asset.file !== 'string' ||
        asset.directory.length > 4096 || asset.file.length > 4096 || path.dirname(asset.file) !== asset.directory) unsafe();
    const root = await fs.realpath(this.temporaryRoot);
    const name = path.basename(asset.directory);
    const matches = asset.kind === 'node' ? new RegExp(`^line-mcp-attachment-${asset.sourceSha256}-[A-Za-z0-9]{6}$`).test(name)
      : asset.kind === 'native_image' ? /^line-mcp-image-[a-f0-9-]{36}$/i.test(name)
        : new RegExp(`^line-mcp-file-[a-f0-9-]{36}-${asset.sourceSha256}$`, 'i').test(name);
    if (path.dirname(asset.directory) !== root || !matches ||
        (asset.kind === 'native_image' && path.basename(asset.file) !== asset.sha256 + '.png')) unsafe();
    const directory = await fs.lstat(asset.directory);
    if (!directory.isDirectory() || directory.isSymbolicLink() || directory.uid !== process.getuid() || (directory.mode & 0o777) !== 0o700) unsafe();
    const entries = await fs.readdir(asset.directory);
    if (entries.length !== 1 || entries[0] !== path.basename(asset.file)) unsafe();
    let handle;
    try {
      handle = await fs.open(asset.file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      const before = await handle.stat();
      if (!before.isFile() || before.nlink !== 1 || before.uid !== process.getuid() ||
          (before.mode & 0o777) !== 0o600 || before.size < 1 || before.size > 100 * 1024 * 1024) unsafe();
      const digest = crypto.createHash('sha256'), buffer = Buffer.alloc(64 * 1024); let bytes = 0;
      while (true) {
        const { bytesRead } = await handle.read(buffer, 0, buffer.length, null);
        if (!bytesRead) break;
        bytes += bytesRead; if (bytes > before.size) unsafe(); digest.update(buffer.subarray(0, bytesRead));
      }
      const after = await handle.stat();
      if (bytes !== before.size || before.size !== after.size || before.mtimeMs !== after.mtimeMs ||
          before.ctimeMs !== after.ctimeMs || digest.digest('hex') !== asset.sha256) unsafe();
      return { byteCount: bytes, directoryInode: directory.ino, fileInode: before.ino };
    } finally { await handle?.close(); }
  }
  async capture(asset, state) {
    if (!['prepared', 'submitted', 'uncertain'].includes(state) || !asset ||
        typeof asset.directory !== 'string' || typeof asset.file !== 'string' || path.dirname(asset.file) !== asset.directory ||
        Object.keys(asset).sort().join(',') !== 'directory,file,kind,sha256,sourceSha256') unsafe();
    // /var與/private/var是macOS等價路徑，只正規化根目錄，不跟隨附件本身的symlink。
    const root = await fs.realpath(this.temporaryRoot);
    const canonical = { ...asset, directory: path.join(root, path.basename(asset.directory)),
      file: path.join(root, path.basename(asset.directory), path.basename(asset.file)) };
    if (path.resolve(asset.directory) !== path.join(path.resolve(this.temporaryRoot), path.basename(asset.directory)) &&
        path.dirname(asset.directory) !== root) unsafe();
    const proof = await this.inspect(canonical);
    await privateDirectory(this.directory);
    return this.lock.withLock(async () => {
      const records = await this.records();
      if (records.length >= (asset.kind === 'node' ? 2000 : 2048)) throw new AutomationError('ASSET_LIMIT', '快照紀錄已達上限，請先執行維護');
      const file = this.file(canonical.directory);
      if (await readPrivateJSON(file)) unsafe();
      await writePrivateJSON(file, { schemaVersion: 1, ...canonical, byteCount: proof.byteCount,
        operationId: requestOperation() ?? null, createdAt: this.now(), state });
      return canonical.directory;
    });
  }
  async erase(file, record) {
    try {
      const proof = await this.inspect(record);
      const dir = await fs.lstat(record.directory), target = await fs.lstat(record.file);
      if (dir.ino !== proof.directoryInode || target.ino !== proof.fileInode || target.isSymbolicLink()) unsafe();
      await fs.unlink(record.file);
      // 不使用recursive刪除，新增或未知內容一律不會被順帶移除。
      await fs.rmdir(record.directory);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      try { await fs.lstat(record.directory); unsafe(); } catch (missing) { if (missing.code !== 'ENOENT') throw missing; }
    }
    await fs.unlink(file); return true;
  }
  async remove(directory) {
    return withFinalization(() => this.removeNode(directory));
  }
  async removeNode(directory) {
    const canonical = path.join(await fs.realpath(this.temporaryRoot), path.basename(directory));
    return this.lock.withLock(async () => {
      const file = this.file(canonical), loaded = await readPrivateJSON(file, 16 * 1024);
      if (!loaded) return false;
      if (loaded.value.directory !== canonical || loaded.value.kind !== 'node') unsafe();
      return this.erase(file, loaded.value);
    });
  }
  async status() {
    const records = await this.records();
    return { trackedCount: records.length, byteCount: records.reduce((sum, { record }) => sum + (Number.isSafeInteger(record.byteCount) ? record.byteCount : 0), 0),
      submittedCount: records.filter(({ record }) => record.state === 'submitted').length,
      protectedCount: records.filter(({ record }) => record.state !== 'submitted').length, unmanagedFilesScanned: false };
  }
  async cleanup(minimumAgeDays = 7) {
    await privateDirectory(this.directory);
    return this.lock.withLock(async () => {
      const records = await this.records(); let removedCount = 0, skippedCount = 0;
      for (const { file, record } of records) {
        throwIfCancelled();
        if (record.state !== 'submitted' || !record.operationId || this.now() - record.createdAt < minimumAgeDays * 86_400_000) { skippedCount++; continue; }
        try { await this.erase(file, record); removedCount++; } catch { skippedCount++; }
      }
      return { removedCount, skippedCount, unmanagedFilesScanned: false };
    });
  }
}
