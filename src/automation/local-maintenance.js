import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { AutomationError, assertKnownKeys, optionalInteger } from './automation-error.js';
import { readPrivateJSON, privateDirectory, syncDirectory } from './private-json.js';
import { OperationLock } from './operation-lock.js';
import { throwIfCancelled } from './request-control.js';
import { AttachmentStorage } from './attachment-storage.js';
const execute = promisify(execFile);
const absent = async file => { try { return await fs.lstat(file); } catch (error) { if (error.code === 'ENOENT') return null; throw error; } };
const processAlive = pid => {
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'ESRCH' ? false : null; }
};
async function nativeHelperRunning() {
  const { stdout } = await execute('/bin/ps', ['-ww', '-axo', 'pid=,ppid=,comm='], { timeout: 3000, maxBuffer: 1024 * 1024 });
  for (const line of stdout.split('\n').filter(line => line.trim())) {
    const match = /^\s*\d+\s+\d+\s+(.+)$/.exec(line);
    if (!match) throw new AutomationError('PROCESS_PROBE_FAILED', '無法完整核對原生程序');
    if (/^line-desktop-native(?:-[a-f0-9]{64})?$/.test(path.basename(match[1].trim()))) return true;
  }
  return false;
}

// 與「人工判讀送出結果」分開：只恢復已證明死亡的鎖，不刪journal、不殺程序、不重送。
export class LocalMaintenance {
  constructor({ directory = path.join(os.homedir(), 'Library', 'Application Support', 'line-desktop-mcp'),
    uiLock = new OperationLock(), assets, isAlive = processAlive, helperRunning = nativeHelperRunning,
    pause = () => new Promise(resolve => setTimeout(resolve, 80)) } = {}) {
    this.directory = directory; this.uiLock = uiLock;
    this.assets = assets ?? new AttachmentStorage({ directory: path.join(directory, 'assets') });
    this.locks = { ui: uiLock.lockPath, index: path.join(directory, 'local-index', '.lock'), assets: this.assets.lock.lockPath };
    this.isAlive = isAlive; this.helperRunning = helperRunning; this.pause = pause;
  }
  async inspectLock(target) {
    const lockPath = this.locks[target], stat = await absent(lockPath);
    if (!stat) return { public: { present: false, recoverable: false } };
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid() || (stat.mode & 0o777) !== 0o700) {
      throw new AutomationError('LOCK_UNSAFE', '鎖目錄歸屬或權限不符，未變更');
    }
    const owner = await readPrivateJSON(path.join(lockPath, 'owner.json'), 4096);
    const value = owner?.value;
    if (!value || Object.keys(value).sort().join(',') !== 'acquiredAt,nonce,pid' ||
        !Number.isInteger(value.pid) || value.pid < 1 || !/^[A-Za-z0-9_-]{16,128}$/.test(value.nonce ?? '') ||
        !Number.isFinite(Date.parse(value.acquiredAt))) throw new AutomationError('LOCK_UNSAFE', '鎖owner紀錄不完整，未變更');
    const alive = await this.isAlive(value.pid);
    return { public: { present: true, ownerState: alive === true ? 'alive' : alive === false ? 'absent' : 'unknown', recoverable: alive === false },
      stat, raw: owner.raw, value };
  }
  async status() {
    const locks = {};
    for (const target of Object.keys(this.locks)) {
      try { locks[target] = (await this.inspectLock(target)).public; }
      catch { locks[target] = { present: true, ownerState: 'unverified', recoverable: false }; }
    }
    return { locks, pendingOperation: (await readPrivateJSON(path.join(this.directory, 'pending-operation.json'))) !== null,
      assets: await this.assets.status(), uiAccessed: false,
      recoveryRequiresNativeProcessCheck: true };
  }
  async recover(target) {
    const first = await this.inspectLock(target);
    if (!first.public.present) return { recovered: false, reason: 'NO_LOCK', uiAccessed: false };
    if (!first.public.recoverable || await this.helperRunning()) throw new AutomationError('LOCK_RECOVERY_BLOCKED', 'owner仍存在、狀態未知或原生helper仍在執行，未解除鎖');
    await this.pause();
    const second = await this.inspectLock(target);
    if (!second.public.recoverable || second.stat.ino !== first.stat.ino || !second.raw.equals(first.raw) ||
        await this.helperRunning()) throw new AutomationError('LOCK_RECOVERY_BLOCKED', '鎖或程序狀態改變，未解除鎖');
    throwIfCancelled();
    const evidence = path.join(this.directory, 'recovery-evidence'); await privateDirectory(evidence);
    const archive = path.join(evidence, 'lock-' + crypto.randomUUID());
    // rename保留原owner證據；PID重用、探針失敗、不完整owner皆不能走到這裡。
    await fs.rename(this.locks[target], archive);
    await syncDirectory(path.dirname(this.locks[target])); await syncDirectory(evidence);
    return { recovered: true, journalCleared: false, sendAttempted: false, uiAccessed: false };
  }
  async call(args) {
    assertKnownKeys(args, ['action', 'target', 'minimumAgeDays']);
    if (!['status', 'cleanup', 'recover_lock'].includes(args.action)) throw new AutomationError('INVALID_ARGUMENT', 'action須為status、cleanup或recover_lock');
    if (args.action === 'recover_lock') {
      if (!Object.hasOwn(this.locks, args.target) || args.minimumAgeDays !== undefined) throw new AutomationError('INVALID_ARGUMENT', '恢復只接受ui、index或assets鎖');
      return this.recover(args.target);
    }
    if (args.target !== undefined || (args.action === 'status' && args.minimumAgeDays !== undefined)) throw new AutomationError('INVALID_ARGUMENT', '此action不接受額外維護參數');
    if (args.action === 'status') return this.status();
    const age = optionalInteger(args.minimumAgeDays, 'minimumAgeDays', 7, 365, 7);
    return this.uiLock.withLock(async () => {
      if (await readPrivateJSON(path.join(this.directory, 'pending-operation.json')) || await this.helperRunning()) {
        throw new AutomationError('MAINTENANCE_BLOCKED', '有待恢復操作或原生helper在執行，未清理');
      }
      return { ...(await this.assets.cleanup(age)), minimumAgeDays: age, uiAccessed: false };
    });
  }
}
