import fs from 'node:fs/promises';
import { AsyncLocalStorage } from 'node:async_hooks';
import crypto from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { AutomationError } from './automation-error.js';
import { throwIfCancelled, waitForRequest, requestPause } from './request-control.js';

export class OperationLock {
  constructor({
    lockPath = path.join(os.tmpdir(), 'line-desktop-mcp-ui.lock'),
    timeoutMs = 5_000,
    pollMs = 40,
    now = () => Date.now(),
  } = {}) {
    this.lockPath = lockPath;
    this.timeoutMs = timeoutMs;
    this.pollMs = pollMs;
    this.now = now;
    this.ownerNonce = null;
    this.queue = Promise.resolve();
    this.context = new AsyncLocalStorage();
  }

  async withLock(work) {
    throwIfCancelled();
    if (this.context.getStore() === this) {
      throw new AutomationError('LOCK_REENTRANT', '同一個 automation instance 不可巢狀取得 UI 鎖');
    }
    const previous = this.queue;
    let releaseQueue;
    const turn = new Promise((resolve) => { releaseQueue = resolve; });
    // 把本次 gate 串在前一位之後；逾時 gate 可提早開啟，但後來者仍不會越過目前持鎖者。
    this.queue = previous.then(() => turn);
    const deadline = this.now() + this.timeoutMs;
    let ready;
    try { ready = await waitForRequest(previous.then(() => true), this.timeoutMs); }
    catch (error) { releaseQueue(); throw error; }
    if (!ready) {
      releaseQueue();
      throw new AutomationError('LOCK_TIMEOUT', '等待同一 instance 的 LINE UI 操作佇列逾時', {
        timeoutMs: this.timeoutMs,
        phase: 'queue',
      });
    }
    try {
      await this.acquire(Math.max(0, deadline - this.now()));
      throwIfCancelled();
      return await this.context.run(this, work);
    } finally {
      try {
        await this.release();
      } finally {
        releaseQueue();
      }
    }
  }

  async acquire(timeoutMs = this.timeoutMs) {
    const deadline = this.now() + timeoutMs;
    while (this.now() <= deadline) {
      throwIfCancelled();
      try {
        await fs.mkdir(this.lockPath, { mode: 0o700 });
        this.ownerNonce = crypto.randomBytes(24).toString('base64url');
        try {
          await fs.writeFile(
            path.join(this.lockPath, 'owner.json'),
            JSON.stringify({
              pid: process.pid,
              nonce: this.ownerNonce,
              acquiredAt: new Date(this.now()).toISOString(),
            }),
            { mode: 0o600, flag: 'wx' }
          );
        } catch (error) {
          await fs.rm(this.lockPath, { recursive: true, force: true });
          this.ownerNonce = null;
          throw error;
        }
        return;
      } catch (error) {
        if (error?.code !== 'EEXIST') throw error;
        if (this.now() <= deadline) await requestPause(this.pollMs);
      }
    }
    throw new AutomationError('LOCK_TIMEOUT', '等待 LINE UI 操作鎖逾時', {
      timeoutMs: this.timeoutMs,
    });
  }

  async release() {
    if (!this.ownerNonce) return;
    let owner;
    try {
      owner = JSON.parse(await fs.readFile(path.join(this.lockPath, 'owner.json'), 'utf8'));
    } catch {
      this.ownerNonce = null;
      throw new AutomationError('LOCK_OWNERSHIP_LOST', 'UI 鎖 owner 無法驗證，拒絕刪除鎖目錄');
    }
    if (owner.nonce !== this.ownerNonce || owner.pid !== process.pid) {
      this.ownerNonce = null;
      throw new AutomationError('LOCK_OWNERSHIP_LOST', 'UI 鎖 owner 已變更，拒絕刪除鎖目錄');
    }
    this.ownerNonce = null;
    await fs.rm(this.lockPath, { recursive: true, force: true });
  }
}
